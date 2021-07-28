#!/usr/bin/perl -I.

#===========================================================================
# SWITCH PORTS ACTIVITY MONITOR, 3rd GENERATION
# """""""""""""""""""""""""""""""""""""""""""""
# SNMP COLLECTOR component
#
# © 2000-2021 Borek Lupomesky <Borek.Lupomesky@vodafone.com>
# © 2002      Petr Cech
#
# This script does retrieving SNMP data from switches and updating
# backend database.
#
# Run with --help to see command line options
#===========================================================================

use strict;
use lib 'lib';
use POSIX qw(strftime);
use SPAMv2;
use SPAM_SNMP;
use Socket;
use Data::Dumper;
use Try::Tiny;

use SPAM::Cmdline;
use SPAM::Config;
use SPAM::Host;

$| = 1;


#=== global variables ======================================================

my $cfg;             # SPAM::Config instance
my $port2cp;         # switchport->CP mapping (from porttable)
my %swdata2;         # holder for host instances, replaces %swdata
my $arptable;        # arptable data (hash reference)


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

  my $e = $host->snmp->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}{$if} // undef;
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
# This routine will load content of the status table from the backend
# database into a $swdata structure (only rows relevant to specified host).
#
# Arguments: 1. host
# Returns:   1. error message or undef
#===========================================================================

sub sql_load_status
{
  my $host = shift;
  my $dbh = $cfg->get_dbi_handle('spam');

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
  my $r = $sth->execute($host->name);
  if(!$r) {
    return 'Database query failed (spam, ' . $sth->errstr() . ')';
  }

  while(my $ra = $sth->fetchrow_arrayref()) {
    $host->add_port(@$ra);
  }

  return undef;
}


#===========================================================================
# This function loads last boot time for a host stored in db
#===========================================================================

sub sql_load_uptime
{
  my $host = shift;
  my $dbh = $cfg->get_dbi_handle('spam');

  die 'Cannot connect to database (spam)' unless ref $dbh;
  my $qry = q{SELECT date_part('epoch', boot_time) FROM swstat WHERE host = ?};
  my $sth = $dbh->prepare($qry);
  my $r = $sth->execute($host->name);
  die 'Database query failed (spam, ' . $sth->errstr() . ')' unless $r;
  my ($v) = $sth->fetchrow_array();
  return $v;
}


#===========================================================================
# This routine encapsulates loading of all data for a single configured
# host; throws exception when it encounters an error.
#===========================================================================

sub poll_host
{
  #--- arguments -----------------------------------------------------------

  my ($hostname, $get_mactable, $hostinfo) = @_;

  #--- other variables -----------------------------------------------------

  my $host = $swdata2{$hostname} = SPAM::Host->new(name => $hostname);
  my $platform;

  #--- check if the hostname can be resolved

  die "DNS resolution failed\n" unless inet_aton($host->name);

  #--- load last status from backend db ------------------------------------

  tty_message("[%s] Load status (started)\n", $host->name);
  my $r = sql_load_status($host);
  if(defined $r) {
    tty_message("[%s] Load status (status failed, $r)\n", $host->name);
    die "Failed to load table STATUS\n";
  }
  $host->boottime_prev(sql_load_uptime($host));
  tty_message("[%s] Load status (finished)\n", $host->name);

  #--- load supported MIB trees --------------------------------------------

  # The first MIB must contain reading sysObjectID, sysLocation and
  # sysUpTime. If these cannot be loaded; the whole function fails.

  $cfg->iter_mibs(sub {
    my ($mib, $is_first_mib) = @_;
    my $mib_key = $mib->name;
    my @mib_list = ( $mib_key );
    my @vlans = ( undef );

    $mib->iter_objects(sub {
      my $obj = shift;

  #--- match platform string

      if(!$is_first_mib) {
        my $include_re = $obj->include;
        my $exclude_re = $obj->exclude;
        next if $include_re && $platform !~ /$include_re/;
        next if $exclude_re && $platform =~ /$exclude_re/;
      }

  #--- include additional MIBs

  # this implements the 'addmib' object key; we use this to load product
  # MIBs that translate sysObjectID into nice textual platform identifiers;
  # note that the retrieved values will be stored under the first MIB name
  # in the array @$mib

      push(@mib_list, @{$obj->addmib});

  #--- process additional flags

      # 'arptable' is only relevant for reading arptables from _routers_;
      # here we just skip it

      next if $obj->has_flag('arptable');

      # 'vlans' flag; this causes to VLAN number to be added to the
      # community string (as community@vlan) and the tree retrieval is
      # iterated over all known VLANs; this means that vtpVlanName must be
      # already retrieved; this is required for reading MAC addresses from
      # switch via BRIDGE-MIB

      if($obj->has_flag('vlans')) {
        @vlans = snmp_get_active_vlans($host);
        if(!@vlans) { @vlans = ( undef ); }
      }

      # 'vlan1' flag; this is similar to 'vlans', but it only iterates over
      # value of 1; these two are mutually exclusive

      if($obj->has_flag('vlan1')) {
        @vlans = ( 1 );
      }

      # 'mactable' MIBs should only be read when --mactable switch is active

      if($obj->has_flag('mactable')) {
        if(!$get_mactable) {
          tty_message(
            "[%s] Skipping %s, mactable loading not active\n",
            $host->name, $mib->name
          );
          next;
        }
      }

  #--- iterate over vlans

      for my $vlan (@vlans) {
        next if $vlan > 999;

  #--- retrieve the SNMP object

        my $r = snmp_get_object(
          'snmpwalk', $host->name, $vlan, \@mib_list,
          $obj->name,
          $obj->columns,
          sub {
            my ($var, $cnt) = @_;
            return if !$var;
            my $msg = sprintf("[%s] Loading %s::%s", $host->name, $mib_key, $var);
            if($vlan) { $msg .= " $vlan"; }
            if($cnt) { $msg .= " ($cnt)"; }
            tty_message("$msg\n");
          }
        );

  #--- handle error

        if(!ref $r) {
          if($vlan) {
            tty_message(
              "[%s] Processing %s/%d (failed, %s)\n",
              $host->name, $mib->name, $vlan, $r
            );
          } else {
            tty_message(
              "[%s] Processing %s (failed, %s)\n",
              $host->name, $mib->name, $r
            );
          }
        }

  #--- process result

        else {
          $host->add_snmp_object($mib, $vlan, $obj, $r);
        }
      }

  #--- process "save" flag

  # this saves the MIB table into database, only supported for tables, not
  # scalars

      if(
        $obj->has_flag('save')
        && $host->snmp->{$mib_key}{$obj->name}
      ) {
        tty_message("[%s] Saving %s (started)\n", $host->name, $obj->name);
        my $r = sql_save_snmp_object($host, $obj);
        if(!ref $r) {
          tty_message("[%s] Saving %s (failed)\n", $host->name, $obj->name);
        } else {
          tty_message(
            "[%s] Saving %s (finished, i=%d,u=%d,d=%d)\n",
            $host->name, $obj->name,
            @{$r}{qw(insert update delete)}
          );
        }
      }

      # false to continue iterating
      return undef;
    });

  #--- first MIB entry is special as it gives us information about the host

    if($is_first_mib) {
      if($hostinfo) {
        tty_message(
          "[%s] Platform: %s\n", $host->name, $host->platform // '?'
        );
        tty_message(
          "[%s] Booted on: %s\n",
          $host->name, strftime('%Y-%m-%d', localtime($host->boottime))
        ) if $host->boottime;
        tty_message(
          "[%s] Location: %s\n", $host->name, $host->location // '?'
        );
        return 1;
      }
      tty_message(
        "[%s] System info: platform=%s boottime=%s\n",
        $host->name,
        $host->platform, strftime('%Y-%m-%d', localtime($host->boottime))
      );
    }

    # false to continue iterating
    return undef;
  });

  return if $hostinfo;

  #--- prune non-ethernet interfaces and create portName -> ifIndex hash

  my $cnt_prune = 0;
  my (%by_ifindex, %by_ifname);
  if(
    exists $host->snmp->{'IF-MIB'}{'ifTable'} &&
    exists $host->snmp->{'IF-MIB'}{'ifXTable'}
  ) {
    tty_message("[%s] Pruning non-ethernet interfaces (started)\n", $host->name);
    for my $if (keys %{ $host->snmp->{'IF-MIB'}{'ifTable'} }) {
      if(
        # interfaces of type other than 'ethernetCsmacd'
        $host->snmp->{'IF-MIB'}{'ifTable'}{$if}{'ifType'}{'enum'}
          ne 'ethernetCsmacd'
        # special case; some interfaces are ethernetCsmacd and yet they are
        # not real interfaces (good job, Cisco) and cause trouble
        || $host->snmp->{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'}
          =~ /^vl/i
      ) {
        # matching interfaces are deleted
        delete $host->snmp->{'IF-MIB'}{'ifTable'}{$if};
        delete $host->snmp->{'IF-MIB'}{'ifXTable'}{$if};
        $cnt_prune++;
      } else {
        #non-matching interfaces are indexed
        $by_ifindex{$if}
        = $host->snmp->{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'};
      }
    }
    %by_ifname = reverse %by_ifindex;
    $host->port_to_ifindex(\%by_ifname);
    tty_message(
      "[%s] Pruning non-ethernet interfaces (finished, %d pruned)\n",
      $host->name, $cnt_prune
    );
  } else {
    tty_message("[%s] ifTable/ifXTable not found\n", $host->name);
    die "ifTable/ifXTable don't exist on $host";
  }

  #--- create ifindex->CISCO-STACK-MIB::portModuleIndex,portIndex

  # some CISCO MIBs use this kind of indexing instead of ifIndex

  my %by_portindex;
  if(
    exists $host->snmp->{'CISCO-STACK-MIB'}{'portTable'}
  ) {
    my $t = $host->snmp->{'CISCO-STACK-MIB'}{'portTable'};
    for my $idx_mod (keys %$t) {
      for my $idx_port (keys %{$t->{$idx_mod}}) {
        $by_portindex{$t->{$idx_mod}{$idx_port}{'portIfIndex'}{'value'}}
        = [ $idx_mod, $idx_port ];
      }
    }
    $host->ifindex_to_portindex(\%by_portindex);
  }

  #--- create mapping from IF-MIB to BRIDGE-MIB interfaces

  my %by_dot1d;

  if(
    exists $host->snmp->{'BRIDGE-MIB'}
    && exists $host->snmp->{'CISCO-VTP-MIB'}{'vtpVlanTable'}{1}
  ) {
    my @vlans
    = keys %{
      $host->snmp->{'CISCO-VTP-MIB'}{'vtpVlanTable'}{'1'}
    };
    for my $vlan (@vlans) {
      if(
        exists $host->snmp->{'BRIDGE-MIB'}{$vlan}
        && exists $host->snmp->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
      ) {
        my @dot1idxs
        = keys %{
          $host->snmp->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
        };
        for my $dot1d (@dot1idxs) {
          $by_dot1d{
            $host->snmp->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}{$dot1d}{'dot1dBasePortIfIndex'}{'value'}
          } = $dot1d;
        }
      }
    }
    $host->ifindex_to_dot1d(\%by_dot1d);
  }

  #--- dump swstat and entity table

  if($ENV{'SPAM_DEBUG'}) {
    if($host->entity_tree) {
      open(my $fh, '>', "debug.entities.$$.log") || die;

      # dump the whole entity tree
      print $fh "entity index         | if     | class        | pos | model        | name\n";
      print $fh "---------------------+--------+--------------+-----+--------------+---------------------------\n";
      $host->entity_tree->traverse(sub {
        my ($node, $level) = @_;
        printf $fh "%-20s | %6s | %-12s | %3d | %12s | %s\n",
          ('  ' x $level) . $node->entPhysicalIndex,
          $node->ifIndex // '',
          $node->entPhysicalClass,
          $node->entPhysicalParentRelPos,
          $node->entPhysicalModelName,
          $node->entPhysicalName;
      });

      # display some derived knowledge
      my @chassis = $host->entity_tree->chassis;
      printf $fh "\nCHASSIS (%d found)\n", scalar(@chassis);
      for(my $i = 0; $i < @chassis; $i++) {
        printf $fh "%d. %s\n", $i+1, $chassis[$i]->disp;
      }

      my @ps = $host->entity_tree->power_supplies;
      printf $fh "\nPOWER SUPPLIES (%d found)\n", scalar(@ps);
      for(my $i = 0; $i < @ps; $i++) {
        printf $fh "%d. chassis=%d %s\n", $i+1,
          $ps[$i]->chassis_no,
          $ps[$i]->disp;
      }

      my @cards = $host->entity_tree->linecards;
      printf $fh "\nLINECARDS (%d found)\n", scalar(@cards);
      for(my $i = 0; $i < @cards; $i++) {
        printf $fh "%d. chassis=%d slot=%d %s\n", $i+1,
          $cards[$i]->chassis_no,
          $cards[$i]->linecard_no,
          $cards[$i]->disp;
      }

      my @fans = $host->entity_tree->fans;
      printf $fh "\nFANS (%d found)\n", scalar(@fans);
      for(my $i = 0; $i < @fans; $i++) {
        printf $fh "%d. chassis=%d %s\n", $i+1,
          $fans[$i]->chassis_no,
          $fans[$i]->disp;
      }

      my $hwinfo = $host->entity_tree->hwinfo;
      printf $fh "\nHWINFO (%d entries)\n", scalar(@$hwinfo) ;
      print $fh "\n", Dumper($hwinfo), "\n";

      # finish
      close($fh);
    }
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
  my $idx = $host->port_to_ifindex;
  my @idx_keys = (keys %$idx);
  my @update_plan;
  my @stats = (0) x 4;  # i/d/U/u
  my $debug_fh;

  #--- debug init

  if($ENV{'SPAM_DEBUG'}) {
    open($debug_fh, '>', "debug.find_changes.$$.log");
    if($debug_fh) {
      printf $debug_fh "--> find_changes(%s)\n", $host->name
    }
  }

  #--- delete: ports that no longer exist (not found via SNMP) ---

  $host->iterate_ports(sub {
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
    my $pi = $host->ifindex_to_portindex->{$if};

    if($host->get_port($k)) {

      my $ifTable = $host->snmp->{'IF-MIB'}{'ifTable'}{$if};
      my $ifXTable = $host->snmp->{'IF-MIB'}{'ifXTable'}{$if};
      my $portTable
         = $host->snmp->{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};
      my $vmMembershipTable
         = $host->snmp->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};

      #--- update: entry is not new, check whether it has changed ---

      my $old = $host->get_port($k);
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
          port_flag_pack($host, $if) ],
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
        #$swdata{$host}{updated}{$if} = 1;
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
  my $idx = $host->port_to_ifindex;
  my ($r, $q, $fields, @update);
  my (@fields, @vals, @bind);

  #--- aux function to handle ifSpeed/ifHighSpeed

  # ifSpeed only works up to 40 Gbps), so we prefer ifHighSpeed whenever it
  # is available

  my $ifrate = sub {
    my $if = shift;
    my $ifHighSpeed = $host->snmp->{'IF-MIB'}{'ifXTable'}{$if}{'ifHighSpeed'}{'value'};
    my $ifSpeed = $host->snmp->{'IF-MIB'}{'ifTable'}{$if}{'ifSpeed'}{'value'};

    if($ifHighSpeed) {
      return $ifHighSpeed;
    } else {
      return int($ifSpeed / 1000000);
    }
  };

  #--- create entire SQL transaction into @update array ---

  for my $k (@$update_plan) {

    my $if = $idx->{$k->[1]};
    my $pi = $host->ifindex_to_portindex->{'ifIndexToPortIndex'}{$if};
    my $current_time = strftime("%c", localtime());
    my $ifTable = $host->snmp->{'IF-MIB'}{'ifTable'}{$if};
    my $ifXTable = $host->snmp->{'IF-MIB'}{'ifXTable'}{$if};
    my $vmMembershipTable
       = $host->snmp->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};
    my $portTable
       = $host->snmp->{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};

    #--- INSERT

    if($k->[0] eq 'i') {

      @fields = qw(
        host portname status inpkts outpkts lastchg lastchk
        ifindex vlan vlans descr duplex rate flags adminstatus errdis
      );
      @vals = ('?') x 16;
      @bind = (
        $host->name,
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
        port_flag_pack($host, $if),
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
          port_flag_pack($host, $if),
          $ifTable->{'ifAdminStatus'}{'value'} == 1 ? 't':'f',
          # errdisable used portAdditionalOperStatus; it is no longer supported by Cisco
          'false'
        );

        if(!$host->is_rebooted) {
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
      push(@bind, $host->name, $k->[1]);

    } elsif($k->[0] eq 'd') {

      #--- DELETE

      $q = q{DELETE FROM status WHERE host = ? AND portname = ?};
      @bind = ($host->name, $k->[1]);

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
  my $dbh = $cfg->get_dbi_handle('spam');
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
# Arguments: 1. host instance
# Returns:   1. error message or undef
#===========================================================================

sub sql_mactable_update
{
  my $host = shift;
  my $h = $host->snmp->{'BRIDGE-MIB'};
  my $dbh = $cfg->get_dbi_handle('spam');
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
      printf $debug_fh "==> sql_mactable_update(%s)\n", $host->name;
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
      $host->name
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

      next if !exists $host->snmp->{'IF-MIB'}{'ifTable'}{$if};

      #--- skip MACs on ports that are receiving CDP

      next if exists $host->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if};

      #--- normalize MAC, get formatted timestamp

      my $mac_n = $normalize->($mac);
      my $aux = strftime("%c", localtime());

      if(exists $mac_current{$mac_n}) {
        # update
        @fields = (
          'host = ?', 'portname = ?', 'lastchk = ?', q{active = 't'},
        );
        @bind = (
          $host->name,
          $host->snmp->{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'},
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
          $mac, $host->name,
          $host->snmp->{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'},
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
  my $stat = $host->port_stats;
  my $knownports = grep { $_ eq $host->name } @{$cfg->knownports};
  my $idx = $host->port_to_ifindex;

  # if 'knowports' is active, initialize the stat field; the rest is
  # initialized automatically
  $stat->{'p_used'} = 0 if $knownports;

  # do the counts
  foreach my $if (keys %{$host->snmp->{'IF-MIB'}{'ifTable'}}) {
    my $ifTable = $host->snmp->{'IF-MIB'}{'ifTable'};
    my $ifXTable = $host->snmp->{'IF-MIB'}{'ifXTable'};
    my $portname = $ifXTable->{$if}{'ifName'}{'value'};
    $stat->{p_total}++;
    $stat->{p_patch}++ if exists $port2cp->{$host->name}{$portname};
    $stat->{p_act}++
      if $ifTable->{$if}{'ifOperStatus'}{'enum'} eq 'up';
    # p_errdis used to count errordisable ports, but required SNMP variable
    # is no longer available
    #--- unregistered ports
    if(
      $knownports
      && $ifTable->{$if}{'ifOperStatus'}{'enum'} eq 'up'
      && !exists $port2cp->{$host->name}{$portname}
      && !(
        exists $host->snmp->{'CISCO-CDP-MIB'}
        && exists $host->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
        && exists $host->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if}
      )
    ) {
      $stat->{p_illact}++;
    }
    #--- used ports
    # ports that were used within period defined by "inactivethreshold2"
    # configuration parameter
    if($knownports) {
      if($host->get_port($portname, 12) < 2592000) {
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
    $host,      # 1. host instance
    $port       # 2. port ifindex
  ) = @_;

  #--- other variables

  my $result = 0;

  #--- trunking mode

  if(
    exists $host->snmp->{'CISCO-VTP-MIB'}
    && exists $host->snmp->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}
  ) {
    my $trunk_flag;
    my $s = $host->snmp->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}{$port};
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
    exists $host->snmp->{'IEEE8021-PAE-MIB'}
    && exists $host->snmp->{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}
  ) {
    my %dot1x_flag;
    my $s
    = $host->snmp->{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}{$port};
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
    exists $host->snmp->{'CISCO-AUTH-FRAMEWORK-MIB'}
    && exists $host->snmp->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}
  ) {
    my $s = $host->snmp->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}{$port};
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
    exists $host->snmp->{'CISCO-CDP-MIB'}
    && exists $host->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
    && exists $host->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$port}
  ) {
    $result |= 1;
  }

  #--- power over ethernet

  if(exists $host->snmp->{'POWER-ETHERNET-MIB'}{'pethPsePortTable'}) {
    my $pi = $host->ifindex_to_portindex->{$port};
    if(
      exists
        $host->snmp->{'POWER-ETHERNET-MIB'}
                {'pethPsePortTable'}
                {$pi->[0]}{$pi->[1]}
                {'pethPsePortDetectionStatus'}
    ) {
      my $s = $host->snmp->{'POWER-ETHERNET-MIB'}
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
    exists $host->snmp->{'BRIDGE-MIB'}
    && exists $host->snmp->{'BRIDGE-MIB'}{'dot1dStpRootPort'}
  ) {
    my $dot1d_stpr = $host->snmp->{'BRIDGE-MIB'}{'dot1dStpRootPort'}{'0'};
    for my $vlan (keys %{$host->snmp->{'BRIDGE-MIB'}}) {
      # the keys under BRIDGE-MIB are both a) vlans b) object names
      # that are not defined per-vlan (such as dot1dStpRootPort);
      # that's we need to filter non-vlans out here
      next if $vlan !~ /^\d+$/;
      if(
        exists $host->snmp->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}{$dot1d_stpr}
      ) {
        $result |= 4;
        last;
      }
    }
  }

  #--- STP portfast

  if(
    exists $host->snmp->{'CISCO-STP-EXTENSIONS-MIB'}
    && exists $host->snmp->{'CISCO-STP-EXTENSIONS-MIB'}{'stpxFastStartPortTable'}
  ) {
    my $port_dot1d = $host->ifindex_to_dot1d->{$port};
    my $portmode
    = $host->snmp->{'CISCO-STP-EXTENSIONS-MIB'}
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
  my $dbh = $cfg->get_dbi_handle('spam');
  my ($r, @list, @list2);

  #--- pull data from database ---

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  my $sth = $dbh->prepare('SELECT * FROM vtpmasters');
  if(!$sth->execute()) {
    return 'Database query failed (spam,' . $sth->errstr() . ')';
  }
  while(my @a = $sth->fetchrow_array) {
    $a[2] = $cfg->snmp_community($a[0]);
    push(@list, \@a);
  }

  #--- for VTP domains with preferred masters, eliminate all other masters;
  #--- preference is set in configuration file with "VLANServer" statement

  for my $k (keys %{$cfg->vlanservers}) {
    for(my $i = 0; $i < @list; $i++) {
      next if $list[$i]->[1] ne $k;
      if(lc($cfg->vlanservers->{$k}[0]) ne lc($list[$i]->[0])) {
        splice(@list, $i--, 1);
      } else {
        $list[$i]->[2] = $cfg->vlanservers->{$k}[1];   # community string
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
  my $stat = $host->port_stats;
  my $dbh = $cfg->get_dbi_handle('spam');
  my ($sth, $qtype, $q);
  my (@fields, @args, @vals);
  my $rv;
  my $managementDomainTable
  = $host->snmp->{'CISCO-VTP-MIB'}{'managementDomainTable'}{1};

  # ensure database connection
  return 'Cannot connect to database (spam)' unless ref $dbh;

  #--- try block begins here -----------------------------------------------

  try {

    # first decide whether we will be updating or inserting ---
    $sth = $dbh->prepare('SELECT count(*) FROM swstat WHERE host = ?');
    $sth->execute($host->name) || die "DBERR|" . $sth->errstr() . "\n";
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
        $host->name,
        $host->location =~ s/'/''/r,
        $stat->{p_total},
        $stat->{p_act},
        $stat->{p_patch},
        $stat->{p_illact},
        $stat->{p_errdis},
        $stat->{p_inact},
        $stat->{p_used},
        $managementDomainTable->{'managementDomainName'}{'value'},
        $managementDomainTable->{'managementDomainLocalMode'}{'value'},
        strftime('%Y-%m-%d %H:%M:%S', localtime($host->boottime)),
        $host->platform
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
        $host->location =~ s/'/''/r,
        $stat->{p_total},
        $stat->{p_act},
        $stat->{p_patch},
        $stat->{p_illact},
        $stat->{p_errdis},
        $stat->{p_inact},
        $stat->{p_used},
        strftime('%Y-%m-%d %H:%M:%S', localtime($host->boottime)),
        $managementDomainTable->{'managementDomainName'}{'value'},
        $managementDomainTable->{'managementDomainLocalMode'}{'value'},
        $host->platform,
        $host->name
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

  # finish sucessfully
  return $rv;
}


#===========================================================================
# This function performs database maintenance.
#
# Returns: 1. Error message or undef
#===========================================================================

sub maintenance
{
  my $dbh = $cfg->get_dbi_handle('spam');
  my ($t, $r);

  #--- prepare

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  $t = time();

  #--- arptable purging

  $dbh->do(
    q{DELETE FROM arptable WHERE (? - date_part('epoch', lastchk)) > ?},
    undef, $t, $cfg->arptableage
  ) or return 'Cannot delete from database (spam)';

  #--- mactable purging

  $dbh->do(
    q{DELETE FROM mactable WHERE (? - date_part('epoch', lastchk)) > ?},
    undef, $t, $cfg->mactableage
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
# Argument: 1. host to be processed (SPAM::Host instance)
#===========================================================================

sub sql_autoreg
{
  my $host = shift;
  my @insert;

  # get site-code from hostname
  my $site = $cfg->site_conv($host->name);

  # iterate over all ports
  $host->iterate_ports(sub {
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
        push(@insert,
          sprintf(
            qq{INSERT INTO porttable VALUES ( '%s', '%s', '%s', '%s', 'swcoll' )},
            $host->name, $port, $cp_descr, $site
          )
        );
      }
    }
  });

  # insert data into database
  my $msg = sprintf(
    'Found %d entr%s to autoregister',
    scalar(@insert), scalar(@insert) == 1 ? 'y' : 'ies'
  );
  tty_message("[%s] %s\n", $host->name, $msg);
  if(@insert > 0) {
    my $e = sql_transaction(\@insert);
    if(!$e) {
      tty_message("[%s] Auto-registration successful\n", $host->name);
    } else {
      tty_message("[%s] Auto-registration failed ($e)\n", $host->name);
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
    $host,         # 1. host instance
    $snmp_object   # 2. (strg) SNMP object to be saved
  ) = @_;

  #--- other variables

  my $dbh = $cfg->get_dbi_handle('spam');
  my %stats = ( insert => 0, update => 0, delete => 0 );
  my $err;                 # error message
  my $debug_fh;            # debug file handle
  my $ref_time = time();   # reference 'now' point of time

  #--- open debug file

  if($ENV{'SPAM_DEBUG'}) {
    open($debug_fh, '>>', "debug.save_snmp_object.$$.log");
    if($debug_fh) {
      printf $debug_fh
        "==> sql_save_snmp_object(%s,%s)\n", $host->name, $snmp_object->name;
      printf $debug_fh
        "--> REFERENCE TIME: %s\n", scalar(localtime($ref_time));
    }
  }

  #=========================================================================
  #=== try block start =====================================================
  #=========================================================================

  try {

    # ensure database connection
    die 'Cannot connect to database (spam)' unless ref $dbh;

    # find the MIB object we're saving
    my $obj = $cfg->find_object($snmp_object->name);
    my @object_index = @{$snmp_object->index};
    printf $debug_fh "--> OBJECT INDEX: %s\n", join(', ', @object_index)
      if $debug_fh;

    # find the object in $swdata
    my $object = $host->get_snmp_object($snmp_object->name);
    die "Object $snmp_object does not exist" unless $object;

    # load the current state to %old
    my %old;
    my $old_row_count = 0;
    my $table = 'snmp_' . $snmp_object->name;

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
    my $r = $sth->execute($host->name);
    die "Database query failed\n" .  $sth->errstr() . "\n" unless $r;
    while(my $h = $sth->fetchrow_hashref()) {
      hash_create_index(
        \%old, $h,
        map { $h->{lc($_)}; } @object_index
      );
      $old_row_count++;
    }

    # debugging output
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
          $snmp_object->name
        ),
        $host->name
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
                $snmp_object->name,
                join(',', (
                  'chg_when = current_timestamp',
                  'fresh = true',
                  map { "$_ = ?" } @{$snmp_object->columns}
                )),
                join(' AND ', map { "$_ = ?" } ('host', @object_index))
              ),
              ( map {
                $leaf->{$_}{'enum'} // $leaf->{$_}{'value'} // undef
              } @{$snmp_object->columns} ),
              $host->name, @idx,
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
                $snmp_object->name,
                join(',',
                  ('host', 'fresh', @object_index, @{$snmp_object->columns})
                ),
                join(',',
                  ('?') x (2 + @object_index + @{$snmp_object->columns})
                ),
              ),
              $host->name, 't', @idx,
              map {
                $leaf->{$_}{'enum'} // $leaf->{$_}{'value'} // undef
              } @{$snmp_object->columns}
            ]
          );
        }
      }
    );

  #--- DELETE

    my $dbmaxage = $snmp_object->dbmaxage // undef;
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
                  $snmp_object->name,
                  join(' AND ', map { "$_ = ?" } ('host', @{$snmp_object->index}))
                ),
                $host->name, @idx
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

  # finish
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
	$cfg = SPAM::Config->instance();
	tty_message("[main] Loading master config (finished)\n");

	#--- initialize SPAM_SNMP library

	$SPAM_SNMP::snmpget = $cfg->snmpget;
	$SPAM_SNMP::snmpwalk = $cfg->snmpwalk;

	#--- bind to native database ---------------------------------------

	if(!exists $cfg->config()->{dbconn}{spam}) {
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

	if(!exists $cfg->config()->{dbconn}{ondb}) {
	  die "Database binding 'ondb' not defined\n";
        }

	#--- retrieve list of switches -------------------------------------

	{
          if($cmd->list_hosts()) {
            my $n = 0;
            print "\nDumping configured switches:\n\n";
            for my $k (sort keys %{$cfg->hosts()}) {
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
            for my $k (sort { $a->[0] cmp $b->[0] } @{$cfg->arpservers()}) {
              print $k->[0], "\n";
              $n++;
            }
            print "\n$n ARP servers configured\n\n";
            die "OK\n";
          }
	}

	#--- close connection to ondb database -----------------------------

	tty_message("[main] Closing connection to ondb database\n");
	$cfg->close_dbi_handle('ondb');

	#--- load port and outlet tables -----------------------------------

	tty_message("[main] Loading port table (started)\n");
        my $ret;
	($ret, $port2cp) = load_port_table();
	if($ret) { die "$ret\n"; }
	undef $ret;
	tty_message("[main] Loading port table (finished)\n");

	#--- disconnect parent database handle before forking --------------

	$cfg->close_dbi_handle('spam');

	#--- create work list of hosts that are to be processed ------------

	my @work_list;
	my $wl_idx = 0;
	my $poll_hosts_re = $cmd->hostre();
	foreach my $host (sort keys %{$cfg->hosts()}) {
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

              try { if(!poll_host($host, $cmd->mactable, $cmd->hostinfo)) {

                # only hostinfo
                die "\n" if $cmd->hostinfo;

	      #--- find changes and update status table ---

                tty_message("[$host] Updating status table (started)\n");
                my ($update_plan, $update_stats) = find_changes($swdata2{$host});
                tty_message(
                  sprintf(
                    "[%s] Updating status table (%d/%d/%d/%d)\n",
                    $host, @$update_stats
                  )
                );
                my $e = sql_status_update($swdata2{$host}, $update_plan);
                if($e) { tty_message("[$host] Updating status table (failed, $e)\n"); }
                tty_message("[$host] Updating status table (finished)\n");

                #--- update swstat table ---

                tty_message("[$host] Updating swstat table (started)\n");
                switch_info($swdata2{$host});
                $e = sql_switch_info_update($swdata2{$host});
                if($e) { tty_message("[$host] Updating swstat table ($e)\n"); }
                tty_message("[$host] Updating swstat table (finished)\n");

            #--- update mactable ---

                if($cmd->mactable()) {
                  tty_message("[$host] Updating mactable (started)\n");
                  $e = sql_mactable_update($swdata2{$host});
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

	            }}

              catch {
                chomp;
                tty_message("[$host] Host poll failed ($_)\n") if $_;
              };

            } # host processing block ends here

            #--- getting arptable

            elsif($task->[0] eq 'arp') {
              tty_message("[arptable] Updating arp table (started)\n");
              my $r = snmp_get_arptable(
                $cfg->arpservers(), $cfg->snmp_community,
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
