#!/usr/bin/perl -I.

#===========================================================================
# SWITCH PORTS ACTIVITY MONITOR, 3rd GENERATION
# """""""""""""""""""""""""""""""""""""""""""""
# SNMP COLLECTOR component
#
# © 2000-2017 Borek Lupomesky <Borek.Lupomesky@vodafone.com>
# © 2002      Petr Cech
#
# This script does retrieving SNMP data from switches and updating
# backend database.
#
# Run with --help to see command line options
#===========================================================================

use v5.10;
use strict;
use lib 'lib';
use Getopt::Long;
use POSIX qw(strftime);
use SPAMv2;
use SPAM_SNMP;
use Socket;
use Data::Dumper;
use Try::Tiny;


use SPAM::Cmdline;
use SPAM::Config;

$| = 1;


#=== global variables ======================================================

my $cfg;             # complete configuration holder (new)
my $cfg2;            # SPAM::Config instance
my $port2cp;         # switchport->CP mapping (from porttable)
my %swdata;          # holder for all data retrieved from hosts
my $arptable;        # arptable data (hash reference)
my @known_platforms; # list of known platform codes



#===========================================================================
# Store swdata{HOST}{dbStatus} row.
#===========================================================================

sub swdata_status_row_add
{
  my $host = shift;
  my $key = shift;
  $_[0] =~ y/10/12/;  # ifOperStatus
  $_[10] =~ y/10/12/; # ifAdminStatus
  $swdata{$host}{'dbStatus'}{$key} = [ @_ ];
}


#===========================================================================
# swdata{HOST}{dbStatus} iterator.
#===========================================================================

sub swdata_status_iter
{
  my $host = shift;
  my $cback = shift;

  for my $k (keys %{$swdata{$host}{'dbStatus'}}) {
    my $r = $cback->($k, @{$swdata{$host}{'dbStatus'}{$k}});
    last if $r;
  }
}


#===========================================================================
# Helper function to concatenate the bitstrings that represent enabled VLANs
# on a trunk (gleaned from vlaTrunkPortVlansEnabled group of columns).
# Filling in of ommited values is also performed here.
#===========================================================================

sub get_trunk_vlans_bitstring
{
  #--- arguments

  my ($host, $if) = @_;

  #--- other variables

  my $e = $swdata{$host}{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}{$if} // undef;
  my $trunk_vlans;

  #--- check for existence of the required keys

  if(!$e || !exists $e->{'vlanTrunkPortVlansEnabled'}{'bitstring'}) {
    return undef;
  }

  #--- perform concatenation with filling in zeroes

  # the values received from SNMP seem to sometimes omit the unnecessary
  # zeros, so we fill them in here

  for my $key (qw(
    vlanTrunkPortVlansEnabled
    vlanTrunkPortVlansEnabled2k
    vlanTrunkPortVlansEnabled3k
    vlanTrunkPortVlansEnabled4k
  )) {
    my $v = '';
    my $l = 0;
    if(exists $e->{$key}{'bitstring'}) {
      $v = $e->{$key}{'bitstring'};
      $l = length($v);
    }
    if($l > 1024) {
      warn('Trimming excessive number of bits from $key');
      $v = substr($v, 0, 1024);
      $l = 1024;
    }
    if($l < 1024) {
      $v .= ('0' x (1024 - $l));
    }
    $trunk_vlans .= $v;
  }

  return $trunk_vlans;
}


#===========================================================================
# swdata{HOST}{dbStatus} getter for whole row.
#===========================================================================

sub swdata_status_get
{
  my ($host, $key, $col) = @_;

  if(exists $swdata{$host}{'dbStatus'}{$key}) {
    my $row = $swdata{$host}{'dbStatus'}{$key};
    if(defined $col) {
      return $row->[$col];
    } else {
      return $row;
    }
  } else {
    return undef;
  }
}


#===========================================================================
# This routine will load content of the status table from the backend
# database into a $swdata structure (only rows relevant to specified host).
#
# Arguments: 1. host
# Returns:   1. error message or undef
#===========================================================================

sub sql_load_status
{
  my $host = shift;
  my $dbh = $cfg2->get_dbi_handle('spam');

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  my $qry = 'SELECT %s FROM status WHERE host = ?';
  my @fields = (
    'portname',
    'status',                        # 0
    'inpkts',                        # 1
    'outpkts',                       # 2
    q{date_part('epoch', lastchg)},  # 3
    q{date_part('epoch', lastchk)},  # 4
    'vlan',                          # 5
    'descr',                         # 6
    'duplex',                        # 7
    'rate',                          # 8
    'flags',                         # 9
    'adminstatus',                   # 10
    'errdis',                        # 11
    q{floor(date_part('epoch',current_timestamp) - date_part('epoch',lastchg))},
    'vlans'                          # 13
  );
  $qry = sprintf($qry, join(',', @fields));
  my $sth = $dbh->prepare($qry);
  my $r = $sth->execute($host);
  if(!$r) {
    return 'Database query failed (spam, ' . $sth->errstr() . ')';
  }

  while(my $ra = $sth->fetchrow_arrayref()) {
    swdata_status_row_add($host, @$ra);
  }

  return undef;
}


#===========================================================================
# This function loads last boot time for a host stored in db
#===========================================================================

sub sql_load_uptime
{
  my $host = shift;
  my $dbh = $cfg2->get_dbi_handle('spam');

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  my $qry = q{SELECT date_part('epoch', boot_time) FROM swstat WHERE host = ?};
  my $sth = $dbh->prepare($qry);
  my $r = $sth->execute($host);
  if(!$r) {
    return 'Database query failed (spam, ' . $sth->errstr() . ')';
  }
  my ($v) = $sth->fetchrow_array();
  return \$v;
}


#===========================================================================
# This routine encapsulates loading of all data for a single configured host
#
# Arguments: 1. host
#            2. "get mac table" flag
# Returns:   1. undef on success; any other value means failure
#===========================================================================

sub poll_host
{
  #--- arguments -----------------------------------------------------------

  my ($host, $get_mactable) = @_;

  #--- other variables -----------------------------------------------------

  my $s = $swdata{$host} = {};
  my $platform;

  #--- check if the hostname can be resolved

  if(!inet_aton($host)) {
    tty_message("[$host] Hostname cannot be resolved\n");
    return 'DNS resolution failed';
  }

  #--- load last status from backend db ------------------------------------

  tty_message("[$host] Load status (started)\n");
  my $r = sql_load_status($host);
  if(defined $r) {
    tty_message("[$host] Load status (status failed, $r)\n");
    return 'Failed to load table STATUS';
  }
  $r = sql_load_uptime($host);
  if(!ref($r)) {
    tty_message("[$host] Load status (uptime failed, $r)\n");
    return 'Failed to load uptime';
  }
  $swdata{$host}{stats}{sysuptime2} = $$r;
  tty_message("[$host] Load status (finished)\n");

  #--- load supported MIB trees --------------------------------------------

  # The first MIB must contain reading sysObjectID, sysLocation and
  # sysUpTime. If these cannot be loaded; the whole function fails.

  my $is_first_mib = 1;

  for my $mib_entry (@{$cfg->{'mibs'}}) {
    my $mib = $mib_entry->{'mib'};
    my $mib_key = $mib;
    my @vlans = ( undef );

    for my $object (@{$mib_entry->{'objects'}}) {
      my $object_flags = $object->{'flags'} // undef;
      if(!ref($object_flags)) { $object_flags = [ $object_flags ]; }

  #--- match platform string

      if(!$is_first_mib) {
        my $include_re = $object->{'include'} // undef;
        my $exclude_re = $object->{'exclude'} // undef;
        next if $include_re && $platform !~ /$include_re/;
        next if $exclude_re && $platform =~ /$exclude_re/;
      }

  #--- include additional MIBs

  # this implements the 'addmib' object key; we use this to load product
  # MIBs that translate sysObjectID into nice textual platform identifiers;
  # note that the retrieved values will be stored under the first MIB name
  # in the array @$mib

      if($object->{'addmib'}) {
        my $additional_mibs = $object->{'addmib'};
        if(!ref($additional_mibs)) {
          $additional_mibs = [ $additional_mibs ];
        }
        $mib = [ $mib ];
        push(@$mib, @$additional_mibs);
      }

  #--- process additional flags

      if($object_flags) {

        # 'vlans' flag; this causes to VLAN number to be added to the
        # community string (as community@vlan) and the tree retrieval is
        # iterated over all known VLANs; this means that vtpVlanName must be
        # already retrieved; this is required for reading MAC addresses from
        # switch via BRIDGE-MIB

        if(grep($_ eq 'vlans', @$object_flags)) {
          @vlans = snmp_get_active_vlans($s);
          if(!@vlans) { @vlans = ( undef ); }
        }

        # 'vlan1' flag; this is similar to 'vlans', but it only iterates over
        # value of 1; these two are mutually exclusive

        if(grep($_ eq 'vlan1', @$object_flags)) {
          @vlans = ( 1 );
        }

        # 'mactable' MIBs should only be read when --mactable switch is active

        if(grep($_ eq 'mactable', @$object_flags)) {
          if(!$get_mactable) {
            tty_message("[$host] Skipping $mib, mactable loading not active\n");
            next;
          }
        }

        # 'arptable' is only relevant for reading arptables from _routers_;
        # here we just skip it

        next if grep($_ eq 'arptable', @$object_flags);

      }

  #--- iterate over vlans

      for my $vlan (@vlans) {
        next if $vlan > 999;
        my $cmtvlan = snmp_community($host) . ($vlan ? "\@$vlan" : '');

  #--- retrieve the SNMP object

        my $r = snmp_get_object(
          'snmpwalk', $host, $cmtvlan, $mib,
          $object->{'table'} // $object->{'scalar'},
          $object->{'columns'} // undef,
          sub {
            my ($var, $cnt) = @_;
            return if !$var;
            my $msg = "[$host] Loading $mib_key::$var";
            if($vlan) { $msg .= " $vlan"; }
            if($cnt) { $msg .= " ($cnt)"; }
            tty_message("$msg\n");
          }
        );

  #--- handle error

        if(!ref($r)) {
          if($vlan) {
            tty_message(
              "[%s] Processing %s/%d (failed, %s)\n",
              $host, $mib, $vlan, $r
            );
          } else {
            tty_message(
              "[%s] Processing %s (failed, %s)\n",
              $host, $mib, $r
            );
          }
        }

  #--- process result

        else {
          my $object_name = $object->{'table'} // $object->{'scalar'};
          if($vlan) {
            $swdata{$host}{$mib_key}{$vlan}{$object_name} = $r;
          } else {
            $swdata{$host}{$mib_key}{$object_name} = $r;
          }
        }
      }

  #--- process "save" flag

  # this saves the MIB table into database, only supported for tables, not
  # scalars

      if(
        grep($_ eq 'save', @$object_flags)
        && $swdata{$host}{$mib_key}{$object->{'table'}}
      ) {
        tty_message("[$host] Saving %s (started)\n", $object->{'table'});
        my $r = sql_save_snmp_object($host, $object->{'table'});
        if(!ref $r) {
          tty_message("[$host] Saving %s (failed)\n", $object->{'table'});
        } else {
          tty_message(
            "[$host] Saving %s (finished, i=%d,u=%d,d=%d)\n",
            $object->{'table'},
            @{$r}{qw(insert update delete)}
          );
        }
      }

    }

  #--- first MIB entry is special as it gives us information about the host

    if($is_first_mib) {
      my $sys = $swdata{$host}{'SNMPv2-MIB'};
      $platform = $sys->{'sysObjectID'}{0}{'value'};
      $platform =~ s/^.*:://;
      if(!$platform) {
        tty_message("[$host] Getting host system info failed\n");
        return "Cannot load platform identification";
      }
      $swdata{$host}{'stats'}{'platform'} = $platform;
      my $uptime = $sys->{'sysUpTimeInstance'}{undef}{'value'};
      $uptime = time() - int($uptime / 100);
      $swdata{$host}{'stats'}{'sysuptime'} = $uptime;
      $swdata{$host}{'stats'}{'syslocation'}
      = $sys->{'sysLocation'}{0}{'value'};

      tty_message(
        "[$host] System info: platform=%s boottime=%s\n",
        $platform, strftime('%Y-%m-%d', localtime($uptime))
      );

      $is_first_mib = 0;
    }

  }

  #--- prune non-ethernet interfaces and create portName -> ifIndex hash

  my $cnt_prune = 0;
  my (%by_ifindex, %by_ifname);
  if(
    exists $swdata{$host}{'IF-MIB'}{'ifTable'} &&
    exists $swdata{$host}{'IF-MIB'}{'ifXTable'}
  ) {
    tty_message("[$host] Pruning non-ethernet interfaces (started)\n");
    for my $if (keys %{ $swdata{$host}{'IF-MIB'}{'ifTable'} }) {
      if(
        # interfaces of type other than 'ethernetCsmacd'
        $swdata{$host}{'IF-MIB'}{'ifTable'}{$if}{'ifType'}{'enum'}
          ne 'ethernetCsmacd'
        # special case; some interfaces are ethernetCsmacd and yet they are
        # not real interfaces (good job, Cisco) and cause trouble
        || $swdata{$host}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'}
          =~ /^vl/i
      ) {
        # matching interfaces are deleted
        delete $swdata{$host}{'IF-MIB'}{'ifTable'}{$if};
        delete $swdata{$host}{'IF-MIB'}{'ifXTable'}{$if};
        $cnt_prune++;
      } else {
        #non-matching interfaces are indexed
        $by_ifindex{$if}
        = $swdata{$host}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'};
      }
    }
    %by_ifname = reverse %by_ifindex;
    $swdata{$host}{'idx'}{'portToIfIndex'} = \%by_ifname;
    tty_message(
      "[$host] Pruning non-ethernet interfaces (finished, %d pruned)\n",
      $cnt_prune
    );
  } else {
    die "ifTable/ifXTable don't exist on $host";
  }

  #--- create ifindex->CISCO-STACK-MIB::portModuleIndex,portIndex

  # some CISCO MIBs use this kind of indexing instead of ifIndex

  my %by_portindex;
  if(
    exists $swdata{$host}{'CISCO-STACK-MIB'}{'portTable'}
  ) {
    my $t = $s->{'CISCO-STACK-MIB'}{'portTable'};
    for my $idx_mod (keys %$t) {
      for my $idx_port (keys %{$t->{$idx_mod}}) {
        $by_portindex{$t->{$idx_mod}{$idx_port}{'portIfIndex'}{'value'}}
        = [ $idx_mod, $idx_port ];
      }
    }
    $swdata{$host}{'idx'}{'ifIndexToPortIndex'} = \%by_portindex;
  }

  #--- create mapping from IF-MIB to BRIDGE-MIB interfaces

  my %by_dot1d;

  if(
    exists $swdata{$host}{'BRIDGE-MIB'}
    && exists $swdata{$host}{'CISCO-VTP-MIB'}{'vtpVlanTable'}{1}
  ) {
    my @vlans
    = keys %{
      $swdata{$host}{'CISCO-VTP-MIB'}{'vtpVlanTable'}{'1'}
    };
    for my $vlan (@vlans) {
      if(
        exists $swdata{$host}{'BRIDGE-MIB'}{$vlan}
        && exists $swdata{$host}{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
      ) {
        my @dot1idxs
        = keys %{
          $swdata{$host}{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
        };
        for my $dot1d (@dot1idxs) {
          $by_dot1d{
            $swdata{$host}{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}{$dot1d}{'dot1dBasePortIfIndex'}{'value'}
          } = $dot1d;
        }
      }
    }
    $swdata{$host}{'idx'}{'ifIndexToDot1d'} = \%by_dot1d;
  }

  #--- process entity information

  $swdata{$host}{'hw'} = snmp_entity_to_hwinfo($swdata{$host});

  #--- dump swstat

  if($ENV{'SPAM_DEBUG'}) {
    open(my $fh, '>', "debug.swdata.$$.log") || die;
    print $fh  Dumper(\%swdata);
    close($fh);
  }

  #--- finish

  return;
}


#===========================================================================
# This function compares old data (retrieved from backend database into
# "dbStatus" subtree of swdata) and the new data retrieved via SNMP from
# given host. It updates in-memory data and prepares plan for database
# update (in @update_plan array).
#
# Arguments: 1. host
#            2. Name to ifname->ifindex hash
# Returns:   1. update plan (array reference)
#            2. update statistics (array reference to number of
#               inserts/deletes/full updates/partial updates)
#===========================================================================

sub find_changes
{
  my ($host) = @_;
  my $h = $swdata{$host};
  my $idx = $h->{'idx'}{'portToIfIndex'};
  my @idx_keys = (keys %$idx);
  my @update_plan;
  my @stats = (0) x 4;  # i/d/U/u
  my $debug_fh;

  #--- debug init

  if($ENV{'SPAM_DEBUG'}) {
    open($debug_fh, '>', "debug.find_changes.$$.log");
    if($debug_fh) {
      printf $debug_fh "--> find_changes(%s)\n", $host
    }
  }

  #--- delete: ports that no longer exist (not found via SNMP) ---

  swdata_status_iter($host, sub {
    my $k = shift;
    if(!grep { $_ eq $k } @idx_keys) {
      push(@update_plan, [ 'd', $k ]);       # 'd' as 'delete'
      $stats[1]++;
    }
  });

  #--- now we scan entries found via SNMP ---

  foreach my $k (@idx_keys) {
    # interface's ifIndex
    my $if = $idx->{$k};
    # interface's [portModuleIndex, portIndex]
    my $pi = $h->{'idx'}{'ifIndexToPortIndex'}{$if};

    if(swdata_status_get($host, $k)) {

      my $ifTable = $h->{'IF-MIB'}{'ifTable'}{$if};
      my $ifXTable = $h->{'IF-MIB'}{'ifXTable'}{$if};
      my $portTable
         = $h->{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};
      my $vmMembershipTable
         = $h->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};

      #--- update: entry is not new, check whether it has changed ---

      my $old = swdata_status_get($host, $k);
      my $errdis = 0; # currently unavailable

      #--- collect the data to compare

      my @data = (
        [ 'ifOperStatus', 'n', $old->[0],
          $ifTable->{'ifOperStatus'}{'value'} ],
	[ 'ifInUcastPkts', 'n', $old->[1],
	  $ifTable->{'ifInUcastPkts'}{'value'} ],
	[ 'ifOutUcastPkts', 'n', $old->[2],
	  $ifTable->{'ifOutUcastPkts'}{'value'} ],
        [ 'vmVlan', 'n', $old->[5],
          $vmMembershipTable->{'vmVlan'}{'value'} ],
        [ 'vlanTrunkPortVlansEnabled', 's', $old->[13],
          get_trunk_vlans_bitstring($host, $if) ],
        [ 'ifAlias', 's', $old->[6],
          $ifXTable->{'ifAlias'}{'value'} ],
        [ 'portDuplex', 'n', $old->[7],
          $portTable->{'portDuplex'}{'value'} ],
        [ 'ifSpeed', 'n', $old->[8], (
            exists $ifXTable->{'ifHighSpeed'}{'value'}
            ?
            $ifXTable->{'ifHighSpeed'}{'value'}
            :
            int($ifTable->{'ifSpeed'}{'value'} / 1000000)
          )
        ],
        [ 'port_flags', 'n', $old->[9],
          port_flag_pack($h, $if) ],
        [ 'ifAdminStatus', 'n', $old->[10],
          $ifTable->{'ifAdminStatus'}{'value'} ],
        [ 'errdisable', 'n',
          $old->[11], $errdis ]
      );

      #--- perform comparison

      my $cmp_acc;
      printf $debug_fh
        "--> PORT %s (if=%d, pi=%d/%d)\n", $k, $if, @$pi if $debug_fh;
      for my $d (@data) {
        my $cmp;
        if($d->[1] eq 's') {
          $cmp = $d->[2] ne $d->[3];
        } else {
          $cmp = $d->[2] != $d->[3];
        }
        printf $debug_fh  "%s: old:%s new:%s -> %s\n", @$d[0,2,3],
          $cmp ? 'NO MATCH' : 'MATCH'
          if $debug_fh;
        $cmp_acc ||= $cmp;
      }

      #--- push full or partial update

      if($cmp_acc) {
	# 'U' as 'full update', ie. update all fields in STATUS table
        print $debug_fh "result: FULL UPDATE\n" if $debug_fh;
        push (@update_plan, [ 'U', $k ]);
        $swdata{$host}{updated}{$if} = 1;
        $stats[2]++;
      } else {
        # 'u' as 'partial update', ie. update only lastchk field
        print $debug_fh "result: PARTIAL UPDATE\n" if $debug_fh;
        push (@update_plan, [ 'u', $k ]);
        $stats[3]++;
        #if($h->{ifOperStatus}{$if} == 1) { $swdata{$host}{updated}{$if} = 1; }
      }

    } else {

      #--- insert: entry is new, insert it into backend database ---
      push(@update_plan, [ 'i', $k ]);       # 'i' as 'insert'
      $stats[0]++;
      #if($h->{ifOperStatus}{$if} == 1) { $swdata{$host}{updated}{$if} = 1; }
    }
  }

  #--- some debugging output

  if($debug_fh) {
    print $debug_fh "---> UPDATE PLAN FOLLOWS\n";
    for my $k (@update_plan) {
      printf $debug_fh "%s %s\n", @$k;
    }
    print $debug_fh "---> END OF UPDATE PLAN\n";
  }

  #--- finish

  close($debug_fh) if $debug_fh;
  return (\@update_plan, \@stats);
}


#===========================================================================
# This function performs updating of the STATUS table in the backend dbase;
# by creating entire SQL transaction in memory and then executing it.
#
# Arguments: 1. Host
#            2. Update plan from find_changes() function
#            3. Name to ifindex hash generated by name_to_ifindex_hash()
# Returns:   1. Error state or undef
#===========================================================================

sub sql_status_update
{
  my ($host, $update_plan) = @_;
  my $idx = $swdata{$host}{'idx'}{'portToIfIndex'};
  my $hdata = $swdata{$host};
  my ($r, $q, $fields, @update);
  my $reboot_flag = 0;
  my (@fields, @vals, @bind);

  #--- aux function to handle ifSpeed/ifHighSpeed

  # ifSpeed only works up to 40 Gbps), so we prefer ifHighSpeed whenever it
  # is available

  my $ifrate = sub {
    my $if = shift;
    my $ifHighSpeed = $hdata->{'IF-MIB'}{'ifXTable'}{$if}{'ifHighSpeed'}{'value'};
    my $ifSpeed = $hdata->{'IF-MIB'}{'ifTable'}{$if}{'ifSpeed'}{'value'};

    if($ifHighSpeed) {
      return $ifHighSpeed;
    } else {
      return int($ifSpeed / 1000000);
    }
  };

  #--- did switch reboot in-between SPAM runs?

  my $bt_now  = $swdata{$host}{stats}{sysuptime};
  my $bt_last = $swdata{$host}{stats}{sysuptime2};
  if($bt_now && $bt_last) {
    if(abs($bt_now - $bt_last) > 30) {   # 30 is fudge factor to account for imprecise clocks
      $reboot_flag = 1;
    }
  }

  #--- create entire SQL transaction into @update array ---

  for my $k (@$update_plan) {

    my $if = $idx->{$k->[1]};
    my $pi = $hdata->{'idx'}{'ifIndexToPortIndex'}{$if};
    my $current_time = strftime("%c", localtime());
    my $ifTable = $hdata->{'IF-MIB'}{'ifTable'}{$if};
    my $ifXTable = $hdata->{'IF-MIB'}{'ifXTable'}{$if};
    my $vmMembershipTable
       = $hdata->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};
    my $portTable
       = $hdata->{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};

    #--- INSERT

    if($k->[0] eq 'i') {

      @fields = qw(
        host portname status inpkts outpkts lastchg lastchk
        ifindex vlan vlans descr duplex rate flags adminstatus errdis
      );
      @vals = ('?') x 16;
      @bind = (
        $host,
        $k->[1],
        $ifTable->{'ifOperStatus'}{'enum'} eq 'up' ? 'true' : 'false',
        $ifTable->{'ifInUcastPkts'}{'value'},
        $ifTable->{'ifOutUcastPkts'}{'value'},
        $current_time,
        $current_time,
        $if,
        $vmMembershipTable->{'vmVlan'}{'value'},
        get_trunk_vlans_bitstring($host, $if),
        $ifXTable->{'ifAlias'}{'value'},
        $portTable->{'portDuplex'}{'value'},
        #($ifTable->{'ifSpeed'}{'value'} / 1000000) =~ s/\..*$//r,
        $ifrate->($if),
        port_flag_pack($hdata, $if),
        $ifTable->{'ifAdminStatus'}{'value'} == 1 ? 'true' : 'false',
        # errdisable used portAdditionalOperStatus; it is no longer supported by Cisco
        'false'
      );

      $q = sprintf(
        q{INSERT INTO status ( %s ) VALUES ( %s )},
        join(',', @fields), join(',', @vals)
      );

    }
    elsif(lc($k->[0]) eq 'u') {

      #--- UPDATE

      if($k->[0] eq 'U') {

        @fields = (
          'lastchk = ?', 'status = ?', 'inpkts = ?',
          'outpkts = ?', 'ifindex = ?', 'vlan = ?', 'vlans = ?', 'descr = ?',
          'duplex = ?', 'rate = ?', 'flags = ?', 'adminstatus = ?',
          'errdis = ?'
        );
        @bind = (
          $current_time,
          $ifTable->{'ifOperStatus'}{'enum'} eq 'up' ? 'true' : 'false',
          $ifTable->{'ifInUcastPkts'}{'value'},
          $ifTable->{'ifOutUcastPkts'}{'value'},
          $if,
          $vmMembershipTable->{'vmVlan'}{'value'},
          get_trunk_vlans_bitstring($host, $if),
          $ifXTable->{'ifAlias'}{'value'} =~ s/'/''/gr,
          $portTable->{'portDuplex'}{'value'},
          #($ifTable->{'ifSpeed'}{'value'} / 1000000) =~ s/\..*$//r,
          $ifrate->($if),
          port_flag_pack($hdata, $if),
          $ifTable->{'ifAdminStatus'}{'value'} == 1 ? 't':'f',
          # errdisable used portAdditionalOperStatus; it is no longer supported by Cisco
          'false'
        );

        if(!$reboot_flag) {
          push(@fields, 'lastchg = ?');
          push(@bind, $current_time);
        }

        $q = sprintf(
          q{UPDATE status SET %s},
          join(',', @fields)
        );

      } else {

        $q = q{UPDATE status SET lastchk = ?};
        @bind = ( $current_time );

      }

      $q .= q{ WHERE host = ? AND portname = ?};
      push(@bind, $host, $k->[1]);

    } elsif($k->[0] eq 'd') {

      #--- DELETE

      $q = q{DELETE FROM status WHERE host = ? AND portname = ?};
      @bind = ($host, $k->[1]);

    } else {

      die('FATAL ERROR');

    }
    push(@update, [ $q, @bind ]);
  }

  #--- sent data to db and finish---

  $r = sql_transaction(\@update);
  return $r;
}


#==========================================================================
# This function updates hwinfo table, that contains information about
# hardware components (chassis, linecards, power supplies)
#
# Arguments: 1. host to be updated
# Returns:   1. error message or undef
#==========================================================================

sub sql_hwinfo_update
{
  my $host = shift;
  my $dbh = $cfg2->get_dbi_handle('spam');
  my $query;
  my $ret;
  my $sth;
  my @db;
  my @update_plan;
  my @stats = ( 0, 0, 0 );   # i/d/u

  #--- check argument, ensure database connection

  if(!$host) { return 'No host specified'; }
  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }

  #--- load current data from hwinfo

  $query = qq{SELECT * FROM hwinfo WHERE host = ?};
  $sth = $dbh->prepare($query);
  $sth->execute($host) || return sprintf('Database query failed (spam, %s)', $sth->errstr());
  while(my $row = $sth->fetchrow_hashref) {
    push(@db, $row);
  }

  #--- remove all component for a host

  if((@db > 0) && (!exists $swdata{$host}{hw})) {
    # FIXME - DO WE NEED THIS?
  }

  #--- exit if host has no components

  if(!exists $swdata{$host}{hw}) { return (undef, \@stats); }

  #--- create update plan, part 1: identify removed modules

  for my $row (@db) {
    my ($m, $n) = ($row->{'m'}, $row->{'n'});
    if(!exists $swdata{$host}{hw}{$m}{$n}) {
      push(@update_plan, [
        q{DELETE FROM hwinfo WHERE host = ? AND m = ? AND n = ?},
        $host, $m, $n
      ]);
      $stats[1]++;

  #--- create update plan, part 2: identify changed modules

    } elsif(
      $swdata{$host}{'hw'}{$m}{$n}{'model'} ne $row->{'partnum'} ||
      $swdata{$host}{'hw'}{$m}{$n}{'sn'}    ne $row->{'sn'}      ||
      $swdata{$host}{'hw'}{$m}{$n}{'type'}  ne $row->{'type'}    ||
      $swdata{$host}{'hw'}{$m}{$n}{'hwrev'} ne $row->{'hwrev'}   ||
      $swdata{$host}{'hw'}{$m}{$n}{'fwrev'} ne $row->{'fwrev'}   ||
      $swdata{$host}{'hw'}{$m}{$n}{'swrev'} ne $row->{'swrev'}   ||
      substr($swdata{$host}{'hw'}{$m}{$n}{'descr'},0,64) ne $row->{'descr'}
    ) {

      $query =  q{UPDATE hwinfo SET %s };
      $query .= q{WHERE host = ? AND m = ? AND n = ?};

      my @fields = (
        'chg_when = current_timestamp',
        'partnum = ?', 'sn = ?', 'type = ?',
        'hwrev = ?', 'fwrev = ?',  'swrev = ?',
        'descr = ?'
      );

      my @bind = (
        $swdata{$host}{hw}{$m}{$n}{model},
        $swdata{$host}{hw}{$m}{$n}{sn},
        $swdata{$host}{hw}{$m}{$n}{type},
        $swdata{$host}{hw}{$m}{$n}{hwrev},
        $swdata{$host}{hw}{$m}{$n}{fwrev},
        $swdata{$host}{hw}{$m}{$n}{swrev},
        substr($swdata{$host}{hw}{$m}{$n}{descr}, 0, 64),
        $host, $m, $n
      );

      push(@update_plan, [
        sprintf($query, join(',', @fields)),
        @bind
      ]);

      $stats[2]++;
    }
  }

  #--- create update plan, part 3: identify new modules

  for my $m (keys %{$swdata{$host}{hw}}) {
    for my $n (keys %{$swdata{$host}{hw}{$m}}) {
      if(!grep { $_->{'m'} eq $m && $_->{'n'} eq $n } @db) {

        $query = q{INSERT INTO hwinfo ( %s ) VALUES ( %s )};

        my @fields = qw(host m n partnum sn type hwrev fwrev swrev descr);
        my @vals = ('?') x 10;
        my @bind = (
          $host, $m, $n, $swdata{$host}{hw}{$m}{$n}{model},
          $swdata{$host}{'hw'}{$m}{$n}{'sn'},
          $swdata{$host}{'hw'}{$m}{$n}{'type'},
          $swdata{$host}{'hw'}{$m}{$n}{'hwrev'},
          $swdata{$host}{'hw'}{$m}{$n}{'fwrev'},
          $swdata{$host}{'hw'}{$m}{$n}{'swrev'},
          substr($swdata{$host}{hw}{$m}{$n}{descr}, 0, 64)
        );

        push(@update_plan, [
          sprintf($query, join(',', @fields), join(',', @vals)),
          @bind
        ]);
        $stats[0]++;
      }
    }
  }

  #--- send the whole batch to db

  if(@update_plan > 0) {
    my $e = sql_transaction(\@update_plan);
    if($e) { return ($e, \@stats); }
  }

  #--- finish successfully

  return (undef, \@stats);
}


#==========================================================================
# This function performs database transaction
#
# Arguments: 1. reference to list of lines to be sent do db
# Returns:   1. error message or undef
#
# The list of database statements to be performed may take two forms.
# One is just string containing the statement. The other is array ref,
# that contains the statement in [0] and the rest of the array are bind
# variables. Both forms can be mixed freely.
#==========================================================================

sub sql_transaction
{
  my $update = shift;
  my $dbh = $cfg2->get_dbi_handle('spam');
  my ($r, $rv);
  my $fh;         # debugging output filehandle

  #--- write the transation to file (for debugging)

  if($ENV{'SPAM_DEBUG'}) {
    my $line = 1;
    open($fh, '>>', "debug.transaction.$$.log");
    if($fh) {
      printf $fh "---> TRANSACTION LOG START\n";
      for my $row (@$update) {
        printf $fh "%d. %s\n", $line++,
          sql_show_query(@$row);
      }
      printf $fh "---> TRANSACTION LOG END\n";
    }
  }

  try { #+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

  #--- ensure database connection

    if(!ref($dbh)) {
      die "Cannot connect to database (spam)\n";
    }

  #--- begin transaction

    $dbh->begin_work()
    || die sprintf(
      "Cannot begin database transaction (spam, %s)\n", $dbh->errstr()
    );

  #--- perform update

    my $line = 1;
    for my $row (@$update) {
      my $qry = ref($row) ? $row->[0] : $row;
      my @args;
      if(ref($row)) { @args = @$row[1 .. scalar(@$row)-1]; }
      my $sth = $dbh->prepare($qry);
      my $r = $sth->execute(@args);
      my $err1 = $sth->errstr();
      if(!$r) {
        die sprintf(
          "Database update failed (line %d, %s), transaction rolled back\n",
          $line, $err1
        );
      }
      $line++;
    }

  #--- commit transaction

    $dbh->commit()
    || die sprintf("Cannot commit database transaction (%s)\n", $dbh->errstr());
    printf $fh "---> TRANSACTION FINISHED SUCCESSFULLY\n" if $fh;

  } #+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

  #--- catch failure

  catch {
    chomp($_);
    $rv = $_;
    printf $fh "---> TRANSACTION FAILED (%s)\n", $_ if $fh;
    if(!$dbh->rollback()) {
      printf $fh "---> TRANSACTION ABORT FAILED (%s)\n", $dbh->errstr() if $fh;
      $rv .= ', ' . $dbh->errstr();
    } else {
      printf $fh "---> TRANSACTION ABORTED SUCCESSFULLY\n" if $fh
    }
  };

  #--- finish

  close($fh) if $fh;
  return $rv;
}


#===========================================================================
# This function updates mactable in backend db.
#
# Arguments: 1. host
# Returns:   1. error message or undef
#===========================================================================

sub sql_mactable_update
{
  my $host = shift;
  my $h = $swdata{$host}{'BRIDGE-MIB'};
  my $dbh = $cfg2->get_dbi_handle('spam');
  my $ret;
  my @update;              # update plan
  my %mac_current;         # contents of 'mactable'
  my $debug_fh;

  #--- insta-sub for normalizing MAC values

  my $normalize = sub {
    join(':', map { length($_) == 2 ? $_ : '0' . $_; } split(/:/, shift));
  };

  #--- ensure database connection ---

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }

  #--- open debug file

  if($ENV{'SPAM_DEBUG'}) {
    open($debug_fh, '>', "debug.mactable_update.$$.log");
    if($debug_fh) {
      printf $debug_fh "==> sql_mactable_update(%s)\n", $host;
    }
  }

  #--- query current state, mactable ---

  my $qry = 'SELECT mac, host, portname, active FROM mactable';
  if($debug_fh) {
    printf $debug_fh "--> GET CURRENT MACTABLE CONTENTS\n";
    printf $debug_fh "--> %s\n", $qry;
  }
  my $sth = $dbh->prepare($qry);
  $sth->execute() || return 'Database query failed (spam,' . $sth->errstr() . ')';
  while(my ($mac, $mhost, $mportname, $mactive) = $sth->fetchrow_array()) {
    $mac_current{$mac} = 1;
    if($debug_fh) {
      printf $debug_fh
        "%s = [ %s, %s, %s ]\n",
        $mac, $mhost, $mportname, $mactive ? 'ACTIVE' : 'NOT ACTIVE';
    }
  }

  #--- reset 'active' field to 'false'

  push(
    @update,
    [
      q{UPDATE mactable SET active = 'f' WHERE host = ? and active = 't'},
      $host
    ]
  );

  #--- get list of VLANs, exclude non-numeric keys (those do not denote VLANs
  #--- but SNMP objects)

  my @vlans = sort { $a <=> $b } grep(/^\d+$/, keys %$h);

  #--- gather update plan ---

  if($debug_fh) {
    printf $debug_fh "--> CREATE UPDATE PLAN\n";
    printf $debug_fh "--> VLANS: %s\n", join(',', @vlans);
  }
  for my $vlan (@vlans) {
    printf $debug_fh "--> MACS IN VLAN %d: %d\n",
      $vlan, scalar(keys %{$h->{$vlan}{'dot1dTpFdbTable'}})
      if $debug_fh;
    for my $mac (keys %{$h->{$vlan}{'dot1dTpFdbTable'}}) {
      my ($q, @fields, @bind);
      my $dot1dTpFdbTable = $h->{$vlan}{'dot1dTpFdbTable'};
      my $dot1dBasePortTable = $h->{$vlan}{'dot1dBasePortTable'};

      #--- get ifindex value

      my $dot1d = $dot1dTpFdbTable->{$mac}{'dot1dTpFdbPort'}{'value'};
      my $if = $dot1dBasePortTable->{$dot1d}{'dot1dBasePortIfIndex'}{'value'};

      #--- skip uninteresting MACs (note, that we're not filtering 'static'
      #--- entries: ports with port security seem to report their MACs as
      #--- static in Cisco IOS)

      next if
        $dot1dTpFdbTable->{$mac}{'dot1dTpFdbStatus'}{'enum'} eq 'invalid' ||
        $dot1dTpFdbTable->{$mac}{'dot1dTpFdbStatus'}{'enum'} eq 'self';

      #--- skip MACs on ports we are not tracking (such as port channels etc)

      next if !exists $swdata{$host}{'IF-MIB'}{'ifTable'}{$if};

      #--- skip MACs on ports that are receiving CDP

      next if exists $swdata{$host}{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if};

      #--- normalize MAC, get formatted timestamp

      my $mac_n = $normalize->($mac);
      my $aux = strftime("%c", localtime());

      if(exists $mac_current{$mac_n}) {
        # update
        @fields = (
          'host = ?', 'portname = ?', 'lastchk = ?', q{active = 't'},
        );
        @bind = (
          $host,
          $swdata{$host}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'},
          $aux, $mac
        );
        $q = sprintf(
          q{UPDATE mactable SET %s WHERE mac = ?},
          join(',', @fields)
        );
        printf $debug_fh "UPDATE %s\n", $mac_n if $debug_fh;
      } else {
        # insert
        @fields = (
          'mac', 'host', 'portname', 'lastchk', 'active'
        );
        @bind = (
          $mac, $host,
          $swdata{$host}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'},
          $aux, 't'
        );
        $q = sprintf(
          q{INSERT INTO mactable ( %s ) VALUES ( ?,?,?,?,? )},
          join(',', @fields)
        );
        printf $debug_fh "INSERT %s\n", $mac_n if $debug_fh;

        $mac_current{$mac_n} = 1;
      }
      push(@update, [ $q, @bind ]) if $q;
    }
  }

  #--- sent data to db and finish---

  $ret = sql_transaction(\@update);
  close($debug_fh) if $debug_fh;
  return $ret if defined $ret;
  return undef;
}


#===========================================================================
# This function updates arptable in backend database
#===========================================================================

sub sql_arptable_update
{
  my $dbh = $cfg->get_dbi_handle('spam');
  my %arp_current;
  my ($mac, $ret, @update, $q);

  #--- ensure database connection ---

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }

  #--- query current state ---

  my $sth = $dbh->prepare('SELECT mac FROM arptable');
  $sth->execute()
    || return 'Database query failed (spam,' . $sth->errstr() . ')';
  while(($mac) = $sth->fetchrow_array) {
    $arp_current{$mac} = 0;
  }

  #--- gather update plan ---

  foreach $mac (keys %$arptable) {
    my $aux = strftime("%c", localtime());
    if(exists $arp_current{lc($mac)}) {

      #--- update ---

      push(@update, [
        q{UPDATE arptable SET ip = ?, lastchk = ? WHERE mac = ?},
        $arptable->{$mac},
        $aux,
        $mac
      ]);

    } else {

      #--- insert ---

      {
        my $iaddr = inet_aton($arptable->{$mac});
        my $dnsname = gethostbyaddr($iaddr, AF_INET);

        my @fields = qw(mac ip lastchk);
        my @bind = (
          $mac, $arptable->{$mac},
          $aux
        );

        if($dnsname) {
          push(@fields, 'dnsname');
          push(@bind, lc($dnsname));
        }

        push(@update, [
          sprintf(
            q{INSERT INTO arptable ( %s ) VALUES ( %s )},
            join(',', @fields),
            join(',', (('?') x @fields))
          ),
          @bind
        ]);

      }
    }
  }

  #--- send update to the database ---

  $ret = sql_transaction(\@update);
  return $ret if defined $ret;
  return undef;
}


#===========================================================================
# Function that removes a host from the database. To be used on switches
# that no longer exist.
#===========================================================================

sub sql_host_remove
{
  #--- arguments

  my ($host) = @_;

  #--- other variables

  my @transaction;
  my $r;

  #--- perform removal

  for my $table (qw(status hwinfo swstat badports mactable modwire)) {
    push(@transaction, [ "DELETE FROM $table WHERE host = ?", $host ]);
  }
  return sql_transaction(\@transaction);
}


#===========================================================================
# Generate some statistics info on server and store it into %swdata.
#===========================================================================

sub switch_info
{
  my ($host) = @_;
  my $h = $swdata{$host};
  my $stat = $h->{'stats'};
  my $knownports = grep(/^$host$/, @{$cfg->{'knownports'}});
  my $idx = $swdata{$host}{'idx'}{'portToIfIndex'};

  #--- initialize ---

  $stat->{'p_total'}  = 0;
  $stat->{'p_act'}    = 0;
  $stat->{'p_patch'}  = 0;
  $stat->{'p_illact'} = 0;
  $stat->{'p_inact'}  = 0;
  $stat->{'p_errdis'} = 0;
  $stat->{'p_used'}   = 0 if $knownports;

  #--- count ---

  foreach my $if (keys %{$h->{'IF-MIB'}{'ifTable'}}) {
    my $ifTable = $h->{'IF-MIB'}{'ifTable'};
    my $ifXTable = $h->{'IF-MIB'}{'ifXTable'};
    my $portname = $ifXTable->{$if}{'ifName'}{'value'};
    $stat->{p_total}++;
    $stat->{p_patch}++ if exists $port2cp->{$host}{$portname};
    $stat->{p_act}++
      if $ifTable->{$if}{'ifOperStatus'}{'enum'} eq 'up';
    # p_errdis used to count errordisable ports, but required SNMP variable
    # is no longer available
    #--- unregistered ports
    if(
      $knownports
      && $ifTable->{$if}{'ifOperStatus'}{'enum'} eq 'up'
      && !exists $port2cp->{$host}{$portname}
      && !(
        exists $h->{'CISCO-CDP-MIB'}
        && exists $h->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
        && exists $h->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if}
      )
    ) {
      $stat->{p_illact}++;
    }
    #--- used ports
    # ports that were used within period defined by "inactivethreshold2"
    # configuration parameter
    if($knownports) {
      if(swdata_status_get($host, $portname, 12) < 2592000) {
        $stat->{p_used}++;
      }
    }
  }
  return;
}


#===========================================================================
# Creates flags bitfield from information scattered in $swdata. The
# bitfield is as follows:
#
#  0. CDP .................................... 1
#  1. portfast ............................... 2
#  2. STP root ............................... 4
#  3. trunk dot1q ............................ 8
#  4. trunk isl ............................. 16
#  5. trunk unknown ......................... 32
#  6. dot1x force-authorized (new) .......... 64
#  7. dot1x force-unauthorized (new) ....... 128
#  8. dot1x auto (new) ..................... 256
#  9. dot1x authorized ..................... 512
# 10. dot1x unauthorized .................. 1024
# 11. MAB auth success .................... 2048
# 12. PoE port ............................ 4096
# 13. PoE port enabled .................... 8192
# 14. PoE port supplying power ........... 16384
#===========================================================================

sub port_flag_pack
{
  #--- arguments

  my (
    $hdata,     # 1. (hashref) swdata{host} subtree
    $port       # 2. port ifindex
  ) = @_;

  #--- other variables

  my $result = 0;

  #--- trunking mode

  if(
    exists $hdata->{'CISCO-VTP-MIB'}
    && exists $hdata->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}
  ) {
    my $trunk_flag;
    my $s = $hdata->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}{$port};
    if($s->{'vlanTrunkPortDynamicStatus'}{'enum'} eq 'trunking') {
      $trunk_flag = $s->{'vlanTrunkPortEncapsulationOperType'}{'enum'};
    }
    if($trunk_flag eq 'dot1Q')  { $result |= 8; }
    elsif($trunk_flag eq 'isl') { $result |= 16; }
    elsif($trunk_flag)          { $result |= 32; }
  }

  # FIXME: 802.1x/Auth needs rework, as implemented now it doesn't make good
  # sense: we should be displaying cafSMS info prominently

  #--- 802.1x Auth (from dot1xAuthConfigTable)

  if(
    exists $hdata->{'IEEE8021-PAE-MIB'}
    && exists $hdata->{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}
  ) {
    my %dot1x_flag;
    my $s
    = $hdata->{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}{$port};
    $dot1x_flag{'pc'} = $s->{'dot1xAuthAuthControlledPortControl'}{'enum'};
    $dot1x_flag{'st'} = $s->{'dot1xAuthAuthControlledPortStatus'}{'enum'};
    if($dot1x_flag{'pc'} eq 'forceUnauthorized') { $result |= 128; }
    if($dot1x_flag{'pc'} eq 'auto') { $result |= 256; }
    if($dot1x_flag{'pc'} eq 'forceAuthorized') { $result |= 64; }
    if($dot1x_flag{'st'} eq 'authorized') { $result |= 512; }
    if($dot1x_flag{'st'} eq 'unauthorized') { $result |= 1024; }
  }

  #--- MAC bypass active

  if(
    exists $hdata->{'CISCO-AUTH-FRAMEWORK-MIB'}
    && exists $hdata->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}
  ) {
    my $s = $hdata->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}{$port};
    for my $sessid (keys %$s) {
      if(
        exists $s->{$sessid}{'macAuthBypass'}
        && $s->{$sessid}{'macAuthBypass'}{'cafSessionMethodState'}{'enum'} eq 'authcSuccess'
      ) {
        $result |= 2048;
      }
    }
  }

  #--- CDP

  if(
    exists $hdata->{'CISCO-CDP-MIB'}
    && exists $hdata->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
    && exists $hdata->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$port}
  ) {
    $result |= 1;
  }

  #--- power over ethernet

  if(exists $hdata->{'POWER-ETHERNET-MIB'}{'pethPsePortTable'}) {
    my $pi = $hdata->{'idx'}{'ifIndexToPortIndex'}{$port};
    if(
      exists
        $hdata->{'POWER-ETHERNET-MIB'}
                {'pethPsePortTable'}
                {$pi->[0]}{$pi->[1]}
                {'pethPsePortDetectionStatus'}
    ) {
      my $s = $hdata->{'POWER-ETHERNET-MIB'}
                      {'pethPsePortTable'}
                      {$pi->[0]}{$pi->[1]}
                      {'pethPsePortDetectionStatus'};

      $result |= 4096;
      $result |= 8192 if $s->{'enum'} ne 'disabled';
      $result |= 16384 if $s->{'enum'} eq 'deliveringPower';
    }
  }

  #--- STP root port

  if(
    exists $hdata->{'BRIDGE-MIB'}
    && exists $hdata->{'BRIDGE-MIB'}{'dot1dStpRootPort'}
  ) {
    my $dot1d_stpr = $hdata->{'BRIDGE-MIB'}{'dot1dStpRootPort'}{'0'};
    for my $vlan (keys %{$hdata->{'BRIDGE-MIB'}}) {
      # the keys under BRIDGE-MIB are both a) vlans b) object names
      # that are not defined per-vlan (such as dot1dStpRootPort);
      # that's we need to filter non-vlans out here
      next if $vlan !~ /^\d+$/;
      if(
        exists $hdata->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}{$dot1d_stpr}
      ) {
        $result |= 4;
        last;
      }
    }
  }

  #--- STP portfast

  if(
    exists $hdata->{'CISCO-STP-EXTENSIONS-MIB'}
    && exists $hdata->{'CISCO-STP-EXTENSIONS-MIB'}{'stpxFastStartPortTable'}
  ) {
    my $port_dot1d = $hdata->{'idx'}{'ifIndexToDot1d'}{$port};
    my $portmode
    = $hdata->{'CISCO-STP-EXTENSIONS-MIB'}
              {'stpxFastStartPortTable'}{$port_dot1d}{'stpxFastStartPortMode'}
              {'enum'};
    if($portmode eq 'enable' || $portmode eq 'enableForTrunk') {
      $result |= 2;
    }
  }

  #--- finish

  return $result;
}


#===========================================================================
# This function creates list with one VTP master per VTP domain. All data
# are retrieved from database, so it should be run after database update
# has been performed.
#
# Returns:   1. reference to array of [ host, vtp_domain, community ] pairs
#               or error message
#===========================================================================

sub sql_get_vtp_masters_list
{
  my $dbh = $cfg2->get_dbi_handle('spam');
  my ($r, @list, @list2);

  #--- pull data from database ---

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  my $sth = $dbh->prepare('SELECT * FROM vtpmasters');
  if(!$sth->execute()) {
    return 'Database query failed (spam,' . $sth->errstr() . ')';
  }
  while(my @a = $sth->fetchrow_array) {
    $a[2] = snmp_community($a[0]);
    push(@list, \@a);
  }

  #--- for VTP domains with preferred masters, eliminate all other masters;
  #--- preference is set in configuration file with "VLANServer" statement

  for my $k (keys %{$cfg->{vlanserver}}) {
    for(my $i = 0; $i < @list; $i++) {
      next if $list[$i]->[1] ne $k;
      if(lc($cfg->{vlanserver}{$k}[0]) ne lc($list[$i]->[0])) {
        splice(@list, $i--, 1);
      } else {
        $list[$i]->[2] = $cfg->{vlanserver}{$k}[1];   # community string
      }
    }
  }

  #--- remove duplicates from the list

  my %saw;
  @list2 = grep(!$saw{$_->[1]}++, @list);
  undef %saw; undef @list;

  return \@list2;
}


#===========================================================================
# Stores switch statistical data to backend database (plus the side-effect
# of updating vtpdomain, vtpmode in memory)
#
# Arguments: 1. host
# Returns:   1. undef or error message
#===========================================================================

sub sql_switch_info_update
{
  my $host = shift;
  my $stat = $swdata{$host}{stats};
  my $dbh = $cfg2->get_dbi_handle('spam');
  my ($sth, $qtype, $q);
  my (@fields, @args, @vals);
  my $rv;
  my $managementDomainTable
  = $swdata{$host}{'CISCO-VTP-MIB'}{'managementDomainTable'}{1};

  #--- ensure database connection

  if(!ref($dbh)) { return "Cannot connect to database (spam)"; }

  #--- try block begins here -----------------------------------------------

  try {

    #--- first decide whether we will be updating or inserting ---
    $sth = $dbh->prepare('SELECT count(*) FROM swstat WHERE host = ?');
    $sth->execute($host) || die "DBERR|" . $sth->errstr() . "\n";
    my ($count) = $sth->fetchrow_array();
    $qtype = ($count == 0 ? 'i' : 'u');

    #--- insert ---

    if($qtype eq 'i') {

      $q = q{INSERT INTO swstat ( %s ) VALUES ( %s )};
      my @fields = qw(
        host location ports_total ports_active ports_patched ports_illact
        ports_errdis ports_inact ports_used vtp_domain vtp_mode boot_time
        platform
      );
      @vals = ('?') x @fields;
      @args = (
        $host,
        $stat->{syslocation} =~ s/'/''/r,
        $stat->{p_total},
        $stat->{p_act},
        $stat->{p_patch},
        $stat->{p_illact},
        $stat->{p_errdis},
        $stat->{p_inact},
        $stat->{p_used},
        $managementDomainTable->{'managementDomainName'}{'value'},
        $managementDomainTable->{'managementDomainLocalMode'}{'value'},
        strftime('%Y-%m-%d %H:%M:%S', localtime($stat->{sysuptime})),
        $stat->{platform}
      );

      $q = sprintf($q, join(',', @fields), join(',', @vals));

    }

    #--- update ---

    else {

      $q = q{UPDATE swstat SET %s,chg_when = current_timestamp WHERE host = ?};
      @fields = map { $_ . ' = ?' } (
        'location', 'ports_total', 'ports_active', 'ports_patched', 'ports_illact',
        'ports_errdis', 'ports_inact', 'ports_used', 'boot_time', 'vtp_domain',
        'vtp_mode', 'platform'
      );
      @args = (
        $stat->{syslocation} =~ s/'/''/r,
        $stat->{p_total},
        $stat->{p_act},
        $stat->{p_patch},
        $stat->{p_illact},
        $stat->{p_errdis},
        $stat->{p_inact},
        $stat->{p_used},
        strftime('%Y-%m-%d %H:%M:%S', localtime($stat->{sysuptime})),
        $managementDomainTable->{'managementDomainName'}{'value'},
        $managementDomainTable->{'managementDomainLocalMode'}{'value'},
        $stat->{platform},
        $host
      );

      $q = sprintf($q, join(',', @fields));

    }

    $sth = $dbh->prepare($q);
    my $r = $sth->execute(@args) || die 'DBERR|' . $sth->errstr() . "\n";

  #--- try block ends here -------------------------------------------------

  } catch {
    chomp;
    my ($msg, $err) = split(/\|/);
    if($msg eq 'DBERR') {
      print $rv = "Database update error ($err) on query '$q'\n";
    }
  };

  #--- ???: why is this updated HERE? ---
  # $swdata{HOST}{stats}{vtpdomain,vtpmode} are not used anywhere

  $stat->{vtpdomain} = $managementDomainTable->{'managementDomainName'}{'value'};
  $stat->{vtpmode} = $managementDomainTable->{'managementDomainLocalMode'}{'value'};

  #--- return successfully

  return $rv;
}


#===========================================================================
# This function performs database maintenance.
#
# Returns: 1. Error message or undef
#===========================================================================

sub maintenance
{
  my $dbh = $cfg2->get_dbi_handle('spam');
  my ($t, $r);

  #--- prepare

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  $t = time();

  #--- arptable purging

  $dbh->do(
    q{DELETE FROM arptable WHERE (? - date_part('epoch', lastchk)) > ?},
    undef, $t, $cfg->{'arptableage'}
  ) or return 'Cannot delete from database (spam)';

  #--- mactable purging

  $dbh->do(
    q{DELETE FROM mactable WHERE (? - date_part('epoch', lastchk)) > ?},
    undef, $t, $cfg->{'mactableage'}
  ) or return 'Cannot delete from database (spam)';

  #--- status table purging

  $dbh->do(
    q{DELETE FROM status WHERE (? - date_part('epoch', lastchk)) > ?},
    undef, $t, 7776000 # 90 days
  ) or return 'Cannot delete from database (spam)';

  #--- swstat table purging ---

  ### FIXME: SEEMS BROKEN
  #{
  #  my (@a, @swstat_hosts, @swstat_dellst);
  #
  #  $q = 'SELECT * FROM swstat';
  #  my $sth = $dbh->prepare($q);
  #  $sth->execute() || return 'Database query failed (spam)';
  #  while(@a = $sth->fetchrow_array()) {
  #    push(@swstat_hosts, $a[0]);
  #  }
  #  for my $k (@swstat_hosts) {
  #    if(!exists $cfg->{host}{lc($k)}) {
  #      push(@swstat_dellst, $k);
  #    }
  #  }
  #  if(scalar(@swstat_dellst) != 0) {
  #    for my $k (@swstat_dellst) {
  #      $q = "DELETE FROM swstat WHERE host = '$k'";
  #      $dbh->do($q) || return 'Cannot delete from database (spam)';
  #    }
  #  }
  #}

  return undef;
}


#===========================================================================
# This function finds another task to be scheduled for run
#
# Arguments: 1. work list (arrayref)
# Returns:   1. work list entry or undef
#===========================================================================

sub schedule_task
{
  my $work_list = shift;

  if(!ref($work_list)) { die; }
  for(my $i = 0; $i < @$work_list; $i++) {
    if(!defined $work_list->[$i][2]) {
      return $work_list->[$i];
    }
  }
  return undef;
}


#===========================================================================
# This function sets "pid" field in work list to 0, marking it as finished.
#
# Argument: 1. work list (arrayref)
#           2. pid
# Returns:  1. work list entry or undef
#===========================================================================

sub clear_task_by_pid
{
  my $work_list = shift;
  my $pid = shift;

  for my $k (@$work_list) {
    if($k->[2] == $pid) {
      $k->[2] = 0;
      return $k;
    }
  }
  return undef;
}


#===========================================================================
# Auto-register ports that have port description in proper format -- six
# field divided with semicolon; value of 'x' means empty value; second field
# is either switch port (ignored by SPAM) or outlet name (processed by SPAM)
#
# Argument: 1. host to be processed (string)
#===========================================================================

sub sql_autoreg
{
  my $host = shift;
  my @insert;

  #--- check argument

  return if !$host;

  #--- get site-code from hostname

  my $site = site_conv($host);

  #--- iterate over all ports

  swdata_status_iter($host, sub {
    my $port = shift;
    my $descr = @_[6];
    my ($cp_descr, $cp_db);
    if($descr =~ /^.*?;(.+?);.*?;.*?;.*?;.*$/) {
      $cp_descr = $1;
      next if $cp_descr eq 'x';
      next if $cp_descr =~ /^(fa\d|gi\d|te\d)/i;
      $cp_descr = substr($cp_descr, 0, 10);
      $cp_db = $port2cp->{$host}{$port};
      $cp_db =~ s/^.*!//;
      if(!$cp_db) {
        push(@insert, qq{INSERT INTO porttable VALUES ( '$host', '$port', '$cp_descr', '$site', 'swcoll' )});
      }
    }
  });

  #--- insert data into database

  my $msg = sprintf("Found %d entr%s to autoregister", scalar(@insert), scalar(@insert) == 1 ? 'y' : 'ies');
  tty_message("[$host] $msg\n");
  if(@insert > 0) {
    my $e = sql_transaction(\@insert);
    if(!$e) {
      tty_message("[$host] Auto-registration successful\n");
    } else {
      tty_message("[$host] Auto-registration failed ($e)\n");
    }
  }
}


#===========================================================================
# This function saves SNMP table into database.
#===========================================================================

sub sql_save_snmp_object
{
  #--- arguments

  my (
    $host,         # 1. (strg) switch name
    $snmp_object   # 2. (strg) SNMP table to be saved
  ) = @_;

  #--- other variables

  my $dbh = $cfg2->get_dbi_handle('spam');
  my $cfg = load_config();
  my %stats = ( 'insert' => 0, 'update' => 0, 'delete' => 0 );
  my $err;                 # error message
  my $debug_fh;            # debug file handle
  my $ref_time = time();   # reference 'now' point of time

  #--- open debug file

  if($ENV{'SPAM_DEBUG'}) {
    open($debug_fh, '>>', "debug.save_snmp_object.$$.log");
    if($debug_fh) {
      printf $debug_fh
        "==> sql_save_snmp_object(%s,%s)\n", $host, $snmp_object;
      printf $debug_fh
        "--> REFERENCE TIME: %s\n", scalar(localtime($ref_time));
    }
  }

  #=========================================================================
  #=== try block start =====================================================
  #=========================================================================

  try {

  #--- ensure database connection

    if(!ref($dbh)) {
      die 'Cannot connect to database (spam)';
    }

  #--- find the configuration object

    my $object_config;
    FINDCFG: for my $mib_cfg (@{$cfg->{'mibs'}}) {
      for my $obj_cfg (@{$mib_cfg->{'objects'}}) {
        if(
          exists $obj_cfg->{'table'}
          && $obj_cfg->{'table'} eq $snmp_object
        ) {
          $object_config = $obj_cfg;
          last FINDCFG;
        }
      }
    }
    my @object_index;
    if(ref($object_config->{'index'})) {
      @object_index = @{$object_config->{'index'}};
    } else {
      @object_index = ( $object_config->{'index'} );
    }
    printf $debug_fh "--> OBJECT INDEX: %s\n", join(', ', @object_index)
      if $debug_fh;

  #--- find the object in $swdata

  # for sake of brevity, the caller only specifies object name, so we have
  # to search for the actual object in the tree; there's one problem though:
  # we have mingled the MIB keys with other non-MIB keys; so at this point
  # we are relying on MIBs always ending in "-MIB", if MIBs that don't
  # comply with this naming convention appear, we will need to use subtree
  # for MIBs

    my $object;
    FINDOBJ: for my $mib (keys %{$swdata{$host}}) {
      next if $mib !~ /-MIB$/;
      for my $obj (keys %{$swdata{$host}{$mib}}) {
        if($obj eq $snmp_object) {
          $object = $swdata{$host}{$mib}{$obj};
          last FINDOBJ;
        }
      }
    }
    if(!$object) {
      die "Object $snmp_object does not exist";
    }

  #--- load the current state to %old

    my %old;
    my $old_row_count = 0;
    my $table = "snmp_$snmp_object";

    my @fields = (
      '*',
      "$ref_time - extract(epoch from date_trunc('second', chg_when)) AS chg_age"
    );

    my $query = sprintf(
      'SELECT %s FROM %s WHERE host = ?',
      join(', ', @fields),
      $table
    );

    my $sth = $dbh->prepare($query);
    my $r = $sth->execute($host);
    if(!$r) {
      die "Database query failed\n" .  $sth->errstr() . "\n";
    }
    while(my $h = $sth->fetchrow_hashref()) {
      hash_create_index(
        \%old, $h,
        map { $h->{lc($_)}; } @object_index
      );
      $old_row_count++;
    }
    if($debug_fh && $old_row_count) {
      printf $debug_fh "--> LOADED %d CURRENT ROWS, DUMP FOLLOWS\n",
        $old_row_count;
      print $debug_fh Dumper(\%old), "\n";
      print $debug_fh "--> CURRENT ROWS DUMP END\n";
    }

  #--- collect update plan; there are three conceptual steps:
  #--- 1. entries that do not exist in %old (= loaded from database) will be
  #---    inserted as new
  #--- 2. entries that do exist in %old will be updated in place
  #--- 3. entries that do exist in %old but not in $object (= retrieved via
  #---    SNMP) will be deleted

    my @update_plan = (
      [
        sprintf(
          'UPDATE snmp_%s SET fresh = false WHERE host = ?',
          $object_config->{'table'}
        ),
        $host
      ]
    );

  #--- iterate over the SNMP-loaded data

    hash_iterator(
      $object,
      scalar(@object_index),
      sub {
        my $leaf = shift;
        my @idx = @_;
        my $val_old = hash_index_access(\%old, @idx);
        my (@fields, @values, $query, @cond);

  #--- UPDATE - note, that we are not actually checking, if the data
  #--- changed; just existence of the same (host, @index) will cause all
  #--- columns to be overwritten with new values and 'chg_when' field
  #--- updated

        if($val_old) {
          $stats{'update'}++;
          push(@update_plan,
            [
              sprintf(
                'UPDATE snmp_%s SET %s WHERE %s',
                $object_config->{'table'},
                join(',', (
                  'chg_when = current_timestamp',
                  'fresh = true',
                  map { "$_ = ?" } @{$object_config->{'columns'}}
                )),
                join(' AND ', map { "$_ = ?" } ('host', @{$object_config->{'index'}}))
              ),
              ( map {
                exists $leaf->{$_} ? $leaf->{$_}{'value'} : undef
              } @{$object_config->{'columns'}} ),
              $host, @idx,
            ]
          );

  #--- set the age of the entry to zero, so it's not selected for deletion

          $val_old->{'chg_age'} = 0;
        }

  #--- INSERT

        else {
          $stats{'insert'}++;
          push(@update_plan,
            [
              sprintf(
                'INSERT INTO snmp_%s ( %s ) VALUES ( %s )',
                $object_config->{'table'},
                join(',',
                  ('host', 'fresh', @object_index, @{$object_config->{'columns'}})
                ),
                join(',',
                  ('?') x (2 + @object_index + @{$object_config->{'columns'}})
                ),
              ),
              $host, 't', @idx,
              map {
                exists $leaf->{$_} ? $leaf->{$_}{'value'} : undef
              } @{$object_config->{'columns'}}
            ]
          );
        }
      }
    );

  #--- DELETE

    my $dbmaxage = $object_config->{'dbmaxage'} // undef;
    if(defined $dbmaxage) {
      hash_iterator(
        \%old,
        scalar(@object_index),
        sub {
          my $leaf = shift;
          my @idx = splice @_, 0;

          if($leaf->{'chg_age'} > $dbmaxage) {
            $stats{'delete'}++;
            push(@update_plan,
              [
                sprintf(
                  'DELETE FROM snmp_%s WHERE %s',
                  $object_config->{'table'},
                  join(' AND ', map { "$_ = ?" } ('host', @{$object_config->{'index'}}))
                ),
                $host, @idx
              ]
            );
          }
        }
      );
    }

  #--- debug output

    if($debug_fh) {
      printf $debug_fh
        "--> UPDATE PLAN START (%d rows, %d inserts, %d updates, %d deletes)\n",
        scalar(@update_plan), @stats{'insert','update', 'delete'};
      for my $row (@update_plan) {
        print $debug_fh sql_show_query(@$row), "\n";
      }
      print $debug_fh "--> UPDATE PLAN END\n";
    }

  #--- perform database transaction

    if(@update_plan) {
      my $e = sql_transaction(\@update_plan);
      die $e if $e;
    }

  }

  #=========================================================================
  #=== catch block =========================================================
  #=========================================================================

  catch {
    $err = $_;
    printf $debug_fh "--> ERROR: %s", $err if $debug_fh;
  };

  #--- finish

  close($debug_fh) if $debug_fh;
  return $err // \%stats;
}


#================  #  ======================================================
#===                         ===============================================
#===  ## #   ###  ##  ####   ===============================================
#===  # # #     #  #  #   #  ===============================================
#===  # # #  ####  #  #   #  ===============================================
#===  # # # #   #  #  #   #  ===============================================
#===  # # #  #### ### #   #  ===============================================
#===                         ===============================================
#===========================================================================


#--- title ----------------------------------------------------------------

tty_message(<<EOHD);

Switch Ports Activity Monitor
by Borek.Lupomesky\@vodafone.com
---------------------------------
EOHD

#--- parse command line ----------------------------------------------------

my $cmd = SPAM::Cmdline->instance();

#--- ensure single instance via lockfile -----------------------------------

if(!$cmd->no_lock()) {
  if(-f "/tmp/spam.lock") {
    print "Another instance running, exiting\n";
    exit 1;
  }
  open(F, "> /tmp/spam.lock") || die "Cannot open lock file";
  print F $$;
  close(F);
}

try {

	#--- load master configuration file --------------------------------

	tty_message("[main] Loading master config (started)\n");
	$cfg2 = SPAM::Config->instance();
	if(!ref($cfg = load_config())) {
	  die "$cfg\n";
	}
	tty_message("[main] Loading master config (finished)\n");

	#--- initialize SPAM_SNMP library

	$SPAM_SNMP::snmpget = $cfg->{snmpget};
	$SPAM_SNMP::snmpwalk = $cfg->{snmpwalk};

	#--- bind to native database ---------------------------------------

	if(!exists $cfg2->config()->{dbconn}{spam}) {
	  die "Database binding 'spam' not defined\n";
        }

	#--- run maintenance when user told us to do so --------------------

	if($cmd->maintenance()) {
	  tty_message("[main] Maintaining database (started)\n");
	  my $e = maintenance();
	  if($e) { die "$e\n"; }
          tty_message("[main] Maintaining database (finished)\n");
	  die "OK\n";
	}

	#--- host removal --------------------------------------------------

	# Currently only single host removal, the hastname must match
	# precisely

	if(my $cmd_remove_host = $cmd->remove_host()) {
	  tty_message("[main] Removing host $cmd_remove_host (started)\n");
	  my $e = sql_host_remove($cmd_remove_host);
	  if($e) {
	    die $e;
	  }
	  tty_message("[main] Removing host $cmd_remove_host (finished)\n");
	  die "OK\n";
	}

	#--- bind to ondb database -----------------------------------------

	if(!exists $cfg2->config()->{dbconn}{ondb}) {
	  die "Database binding 'ondb' not defined\n";
        }

	#--- retrieve list of switches -------------------------------------

	{
          if($cmd->list_hosts()) {
            my $n = 0;
            print "\nDumping configured switches:\n\n";
            for my $k (sort keys %{$cfg2->hosts()}) {
              print $k, "\n";
              $n++;
            }
            print "\n$n switches configured\n\n";
            die "OK\n";
          }
	}

	#--- retrieve list of arp servers ----------------------------------

	if($cmd->arptable() || $cmd->list_arpservers()) {
          tty_message("[main] Loading list of arp servers (started)\n");
          if($cmd->list_arpservers()) {
            my $n = 0;
            print "\nDumping configured ARP servers:\n\n";
            for my $k (sort { $a->[0] cmp $b->[0] } @{$cfg2->arpservers()}) {
              print $k->[0], "\n";
              $n++;
            }
            print "\n$n ARP servers configured\n\n";
            die "OK\n";
          }
	}

	#--- close connection to ondb database -----------------------------

	tty_message("[main] Closing connection to ondb database\n");
	$cfg2->close_dbi_handle('ondb');

	#--- load port and outlet tables -----------------------------------

	tty_message("[main] Loading port table (started)\n");
        my $ret;
	($ret, $port2cp) = load_port_table();
	if($ret) { die "$ret\n"; }
	undef $ret;
	tty_message("[main] Loading port table (finished)\n");

	#--- disconnect parent database handle before forking --------------

	$cfg2->close_dbi_handle('spam');

	#--- create work list of hosts that are to be processed ------------

	my @work_list;
	my $wl_idx = 0;
	my $poll_hosts_re = $cmd->hostre();
	foreach my $host (sort keys %{$cfg2->hosts()}) {
          if(
            (
              @{$cmd->hosts()} &&
              grep { lc($host) eq lc($_); } @{$cmd->hosts}
            ) || (
              $poll_hosts_re &&
              $host =~ /$poll_hosts_re/i
            ) || (
              !@{$cmd->hosts()} && !defined($poll_hosts_re)
            )
          ) {
            push(@work_list, [ 'host', $host, undef ]);
          }
	}
	tty_message("[main] %d hosts scheduled to be processed\n", scalar(@work_list));

	#--- add arptable task to the work list

	if($cmd->arptable()) {
	  push(@work_list, [ 'arp', undef, undef ]);
	}

        #--- --worklist option selected, only print the worklist and finish

        if($cmd->list_worklist()) {
          printf("\nFollowing host would be scheduled for polling\n");
          printf(  "=============================================\n");
          for my $we (@work_list) {
            printf("%s %s\n",@{$we}[0..1]);
          }
          print "\n";
          die "OK\n";
        }

	#--- loop through all tasks ----------------------------------------

	my $tasks_cur = 0;

	while(defined(my $task = schedule_task(\@work_list))) {
          my $host = $task->[1];
    	  my $pid = fork();
	  if($pid == -1) {
	    die "Cannot fork() new process";
	  } elsif($pid > 0) {

        #--- parent --------------------------------------------------------

            $tasks_cur++;
            $task->[2] = $pid;
            tty_message("[main] Child $host (pid $pid) started\n");
            if($tasks_cur >= $cmd->tasks()) {
              my $cpid;
              if(($cpid = wait()) != -1) {
                $tasks_cur--;
                my $ctask = clear_task_by_pid(\@work_list, $cpid);
                tty_message(
                  "[main] Child %s reaped\n",
                  $ctask->[0] eq 'host' ? $ctask->[1] : 'arptable'
                );
              } else {
                die "Assertion failed! No children running.";
              }
            }
          } else {

        #--- child ---------------------------------------------------------

        #--- host processing

            if($task->[0] eq 'host') {
              tty_message("[$host] Processing started\n");
              if(!poll_host($host, $cmd->mactable())) {

	      #--- find changes and update status table ---

                tty_message("[$host] Updating status table (started)\n");
                my ($update_plan, $update_stats) = find_changes($host);
                tty_message(
                  sprintf(
                    "[%s] Updating status table (%d/%d/%d/%d)\n",
                    $host, @$update_stats
                  )
                );
                my $e = sql_status_update($host, $update_plan);
                if($e) { tty_message("[$host] Updating status table (failed, $e)\n"); }
                tty_message("[$host] Updating status table (finished)\n");

                #--- update swstat table ---

                tty_message("[$host] Updating swstat table (started)\n");
                switch_info($host);
                $e = sql_switch_info_update($host);
                if($e) { tty_message("[$host] Updating swstat table ($e)\n"); }
                tty_message("[$host] Updating swstat table (finished)\n");

	    #--- update hwinfo table ---

                {
                  my $update_stats;
                  tty_message("[$host] Updating hwinfo table (started)\n");
                  ($e, $update_stats) = sql_hwinfo_update($host);
                  if($e) { tty_message("[$host] Updating hwinfo table ($e)\n"); }
                  tty_message(sprintf("[%s] Updating hwinfo table (i:%d/d:%d/u:%d)\n", $host, @$update_stats));
                  tty_message("[$host] Updating hwinfo table (finished)\n");
                }

            #--- update mactable ---

                if($cmd->mactable()) {
                  tty_message("[$host] Updating mactable (started)\n");
                  $e = sql_mactable_update($host);
                  if(defined $e) { print $e, "\n"; }
                  tty_message("[$host] Updating mactable (finished)\n");
                }

            #--- run autoregistration
	    # this goes over all port descriptions and those, that contain outlet
	    # designation AND have no associated outlet in porttable are inserted
            # there

                if($cmd->autoreg()) {
                  tty_message("[$host] Running auto-registration (started)\n");
                  sql_autoreg($host);
                  tty_message("[$host] Running auto-registration (finished)\n");
                }

	      }

            } # host processing block ends here

            #--- getting arptable

            elsif($task->[0] eq 'arp') {
              tty_message("[arptable] Updating arp table (started)\n");
              my $r = snmp_get_arptable(
                $cfg2->arpservers(), snmp_community(),
                sub {
                  tty_message("[arptable] Retrieved arp table from $_[0]\n");
                }
              );
              if(!ref($r)) {
                tty_message("[arptable] Updating arp table (failed, $r)\n");
              } else {
                $arptable = $r;
                tty_message("[arptable] Updating arp table (processing)\n");
                my $e = sql_arptable_update();
                if($e) { tty_message("[arptable] Updating arp table (failed, $e)\n"); }
                else { tty_message("[arptable] Updating arp table (finished)\n"); }
              }
            }

	    #--- child finish

            exit(0);
	  }

	} # the concurrent section ends here

        #--- clean-up ------------------------------------------------------

        my $cpid;
        while(($cpid = wait()) != -1) {
          $tasks_cur--;
          my $ctask = clear_task_by_pid(\@work_list, $cpid);
          tty_message(
            "[main] Child %s reaped\n",
            $ctask->[0] eq 'host' ? $ctask->[1] : 'arptable'
          );
          tty_message("[main] $tasks_cur children remaining\n");
        }
        if($tasks_cur) {
          die "Assertion failed! \$tasks_cur non-zero.";
        }
        tty_message("[main] Concurrent section finished\n");

} catch {
  if($_ && $_ ne "OK\n") {
    if (! -t STDOUT) { print "spam: "; }
    print $_;
  }
};

#--- release lock file ---

if(!$cmd->no_lock()) {
  unlink("/tmp/spam.lock");
}
