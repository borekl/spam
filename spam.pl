#!/usr/bin/perl

#===========================================================================
# SWITCH PORTS ACTIVITY MONITOR, 3rd GENERATION
# """""""""""""""""""""""""""""""""""""""""""""
# SNMP COLLECTOR component
#
# © 2000-2015 Borek Lupomesky <Borek.Lupomesky@vodafone.com>
# © 2002      Petr Cech
#
# This script does retrieving SNMP data from switches and updating
# backend database.
#
# Run with --help to see command line options
#===========================================================================

use strict;
use Getopt::Long;
use POSIX qw(strftime);
use SPAMv2;
use SPAM_SNMP;
use Socket;
use Data::Dumper;

$| = 1;


#=== global variables ======================================================

my $cfg;             # complete configuration holder (new)
my $port2cp;         # switchport->CP mapping (from porttable)
my %swdata;          # holder for all data retrieved from hosts
my $arptable;        # arptable data (hash reference)
my @known_platforms; # list of known platform codes


#===========================================================================
# This function displays usage help
#===========================================================================

sub help
{
  print "Usage: spam.pl [OPTIONS]\n\n";
  print "  --[no]arptable   turn polling for ARP table on or off (default off)\n";
  print "  --[no]mactable   turn getting bridging table on or off (default on)\n";
  print "  --[no]autoreg    turn autoregistration of outlets on or off (default off)\n";
  print "  --quick          equivalent of --noarptable and --nomactable\n";
  print "  --host=HOST      poll only HOST, can be used multiple times (default all hosts)\n";
  print "  --hostre=RE      poll only hosts matching the regexp\n";
  print "  --tasks=N        number of tasks to be run (N is 1 to 16, default 8)\n";
  print "  --remove=HOST    remove HOST from database and exit\n";
  print "  --maint          perform database maintenance and exit\n";
  print "  --arpservers     list known ARP servers and exit\n";
  print "  --worklist       display list of switches that would be processed and exit\n";
  print "  --hosts          list known hosts and exit\n";
  print "  --debug          turn on debug mode\n";
  print "  --help, -?       this help\n";
  print "\n";
}


#===========================================================================
# This function loads list of switches from external database that must
# be already bound under name 'ondb'.
#
# Arguments: -none-
# Returns:   undef on sucess, error message otherwise
#===========================================================================

sub cfg_switch_list_load
{
  my $dbh = dbconn('ondb');
  my ($r, $s, $cmty, $ip_addr);

  if(!ref($dbh)) { return 'Cannot connect to database (ondb)'; }
  my $sth = $dbh->prepare('SELECT * FROM v_switchlist');
  $r = $sth->execute();
  if(!$r) {
    return sprintf('Database query failed (ondb, %s)', $sth->errstr());
  }
  # FIXME: We're modifying $cfg which is plain wrong. $cfg should really
  # be immutable
  while(($s, $cmty, $ip_addr) = $sth->fetchrow_array()) {
    if(!$cmty) { $cmty = undef; }
    $cfg->{host}{lc($s)}{community} = $cmty;
    $cfg->{host}{lc($s)}{ip} = $ip_addr;
  }
  return undef;
}


#===========================================================================
# This function loads list of ARP servers, ie. routers that are used as
# source of mac->ip address mapping, from already connected database 'ondb'
#===========================================================================

sub cfg_arpservers_list_load
{
  my $dbh = dbconn('ondb');
  my ($q, $r, $s, $cmty);

  if(!ref($dbh)) { return 'Cannot connect to database (ondb)'; }
  my $sth = $dbh->prepare('SELECT * FROM v_arpservers');
  $r = $sth->execute();
  if(!$r) {
    return sprintf('Database query failed (ondb, %s)', $sth->errstr());
  }
  while(($s, $cmty) = $sth->fetchrow_array()) {
    if(!$cmty) { $cmty = undef; }
    push(@{$cfg->{arpserver}}, [$s, $cmty])
      unless scalar(grep { $_->[0] eq $s } @{$cfg->{arpserver}}) != 0;
  }
  return undef;
}


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
  my $dbh = dbconn('spam');

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  my $qry = 'SELECT %s FROM status WHERE host = ?';
  my @fields = (
    'portname', 'status', 'inpkts', 'outpkts',
    q{date_part('epoch', lastchg)}, q{date_part('epoch', lastchk)},
    'vlan', 'descr', 'duplex', 'rate', 'flags', 'adminstatus', 'errdis',
    q{floor(date_part('epoch',current_timestamp) - date_part('epoch',lastchg))}
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
  my $dbh = dbconn('spam');

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

  my $community = $cfg->{'community'};
  my $s;      # aux variable used for shortening access deep into $swdata

  #--- host-specific community override ------------------------------------

  $community = $cfg->{'host'}{$host}{'community'}
    if $cfg->{'host'}{$host}{'community'};

  #--- skip excluded hosts -------------------------------------------------

  if(grep(/^$host$/, @{$cfg->{'excludehost'}})) {
    return 'Excluded host';
  }

  #--- check if the hostname can be resolved

  if(!inet_aton($host)) {
    tty_message("[$host] Hostname cannot be resolved\n");
    return 'DNS resolution failed';
  }

  #--- get system info

  tty_message("[$host] Getting host system info (started)\n");
  my ($sysinfo, $platform, $uptime) = snmp_system_info($host, $community);
  if(!ref($sysinfo)) {
    tty_message("[$host] Getting host system info (failed, %s)\n", $sysinfo);
    return 'Cannot get system info';
  } else {
    tty_message(
      "[$host] System info: platform=%s boottime=%s\n",
      $platform, strftime('%Y-%m-%d', localtime($uptime))
    );
    $swdata{$host}{'stats'}{'platform'} = $platform;
    $swdata{$host}{'stats'}{'sysuptime'} = $uptime;
    $swdata{$host}{'stats'}{'syslocation'}
    = $sysinfo->{'sysLocation'}{0}{'value'}
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

  for my $mib_entry (@{$cfg->{'mibs-new'}}) {
    my $mib = $mib_entry->{'mib'};
    my @vlans = ( undef );

    for my $object (@{$mib_entry->{'objects'}}) {

  #--- match platform string

      my $include_re = $object->{'include'} // undef;
      my $exclude_re = $object->{'exclude'} // undef;
      next if $include_re && $platform !~ /$include_re/;
      next if $exclude_re && $platform =~ /$exclude_re/;

  #--- process additional flags

      if(exists $object->{'flags'}) {
        my $object_flags = $object->{'flags'};
        if(!ref($object_flags)) { $object_flags = [ $object_flags ]; }

        # 'vlans' flag; this causes to VLAN number to be added to the
        # community string (as community@vlan) and the tree retrieval is
        # iterated over all known VLANs; this means that vtpVlanName must be
        # already retrieved; this is required for reading MAC addresses from
        # switch via BRIDGE-MIB

        if(grep($_ eq 'vlans', @$object_flags)) {
          @vlans = keys %{$swdata{$host}{'mibs-new'}{'CISCO-VTP-MIB'}{'vtpVlanTable'}{'1'}};
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
        my $cmtvlan = $community . ($vlan ? "\@$vlan" : '');

  #--- retrieve the SNMP object

        my $r = snmp_get_object(
          'snmpwalk', $host, $cmtvlan, $mib,
          $object->{'table'} // $object->{'scalar'},
          $object->{'columns'} // undef,
          sub {
            my ($var, $cnt) = @_;
            return if !$var;
            my $msg = "[$host] Loading $mib::$var";
            if($vlan) { $msg .= " $vlan"; }
            if($cnt) { $msg .= " ($cnt)"; }
            tty_message("$msg\n");
          }
        );

  #--- handle error

        if(!ref($r)) {
          tty_message(
            "[%s] Processing %s (failed, %s)\n",
            $host, $mib, $r
          );
        }

  #--- process result

        else {
          my $object_name = $object->{'table'} // $object->{'scalar'};
          if($vlan) {
            $swdata{$host}{'mibs-new'}{$mib}{$vlan}{$object_name} = $r;
          } else {
            $swdata{$host}{'mibs-new'}{$mib}{$object_name} = $r;
          }
        }
      }
    }
  }

  #--- prune non-ethernet interfaces and create portName -> ifIndex hash

  my $cnt_prune = 0;
  my (%by_ifindex, %by_ifname);
  if(
    exists $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifTable'} &&
    exists $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifXTable'}
  ) {
    tty_message("[$host] Pruning non-ethernet interfaces (started)\n");
    for my $if (keys %{ $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifTable'} }) {
      if(
        # interfaces of type other than 'ethernetCsmacd'
        $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifTable'}{$if}{'ifType'}{'enum'}
          ne 'ethernetCsmacd'
        # special case; some interfaces are ethernetCsmacd and yet they are
        # not real interfaces (good job, Cisco) and cause trouble
        || $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'}
          =~ /^vl/i
      ) {
        # matching interfaces are deleted
        delete $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifTable'}{$if};
        delete $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifXTable'}{$if};
        $cnt_prune++;
      } else {
        #non-matching interfaces are indexed
        $by_ifindex{$if}
        = $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'};
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
    exists $swdata{$host}{'mibs-new'}{'CISCO-STACK-MIB'}
    && exists $swdata{$host}{'mibs-new'}{'CISCO-STACK-MIB'}{'portTable'}
  ) {
    my $s = $swdata{$host}{'mibs-new'}{'CISCO-STACK-MIB'}{'portTable'};
    for my $idx_mod (keys %$s) {
      for my $idx_port (keys %{$s->{$idx_mod}}) {
        $by_portindex{$s->{$idx_mod}{$idx_port}{'portIfIndex'}{'value'}}
        = [ $idx_mod, $idx_port ];
      }
    }
    $swdata{$host}{'idx'}{'ifIndexToPortIndex'} = \%by_portindex;
  }

  #--- create mapping from IF-MIB to BRIDGE-MIB interfaces

  my %by_dot1d;
  if(
    exists $swdata{$host}{'mibs-new'}{'BRIDGE-MIB'}{1}{'dot1dBasePortTable'}
  ) {
    my @vlans
    = keys %{
      $swdata{$host}{'mibs-new'}{'CISCO-VTP-MIB'}{'vtpVlanTable'}{'1'}
    };
    for my $vlan (@vlans) {
      my @dot1idxs
      = keys %{
        $swdata{$host}{'mibs-new'}{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
      };
      for my $dot1d (@dot1idxs) {
        $by_dot1d{
          $swdata{$host}{'mibs-new'}{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}{$dot1d}{'dot1dBasePortIfIndex'}{'value'}
        } = $dot1d;
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

      my $ifTable = $h->{'mibs-new'}{'IF-MIB'}{'ifTable'}{$if};
      my $ifXTable = $h->{'mibs-new'}{'IF-MIB'}{'ifXTable'}{$if};
      my $portTable
         = $h->{'mibs-new'}{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};
      my $vmMembershipTable
         = $h->{'mibs-new'}{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};

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
        [ 'ifAlias', 's', $old->[6],
          $ifXTable->{'ifAlias'}{'value'} ],
        [ 'portDuplex', 'n', $old->[7],
          $portTable->{'portDuplex'}{'value'} ],
        [ 'ifSpeed', 'n', $old->[8],
          ($ifTable->{'ifSpeed'}{'value'} / 1000000) ],
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
    my $ifTable = $hdata->{'mibs-new'}{'IF-MIB'}{'ifTable'}{$if};
    my $ifXTable = $hdata->{'mibs-new'}{'IF-MIB'}{'ifXTable'}{$if};
    my $vmMembershipTable
       = $hdata->{'mibs-new'}{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};
    my $portTable
       = $hdata->{'mibs-new'}{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};

    #--- INSERT

    if($k->[0] eq 'i') {

      @fields = qw(
        host portname status inpkts outpkts lastchg lastchk
        ifindex vlan descr duplex rate flags adminstatus errdis
      );
      @vals = ('?') x 15;
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
        $ifXTable->{'ifAlias'}{'value'},
        $portTable->{'portDuplex'}{'value'},
        ($ifTable->{'ifSpeed'}{'value'} / 1000000) =~ s/\..*$//r,
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
          'outpkts = ?', 'ifindex = ?', 'vlan = ?', 'descr = ?',
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
          $ifXTable->{'ifAlias'}{'value'} =~ s/'/''/gr,
          $portTable->{'portDuplex'}{'value'},
          ($ifTable->{'ifSpeed'}{'value'} / 1000000) =~ s/\..*$//r,
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
  my $dbh = dbconn('spam');
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

  if((scalar(@db) > 0) && (!exists $swdata{$host}{hw})) {
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

  if(scalar(@update_plan) > 0) {
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
  my $dbh = dbconn('spam');
  my $r;
  my $fh;         # debugging output filehandle

  #--- write the transation to file (for debugging)

  if($ENV{'SPAM_DEBUG'}) {
    my $line = 1;
    open($fh, '>>', "debug.transaction.$$.log");
    if($fh) {
      printf $fh "---> TRANSACTION LOG START\n";
      for my $row (@$update) {
        printf $fh "%d. %s\n", $line++,
          sql_show_query($row->[0], [ @{$row}[1 .. scalar(@$row)-1] ]);
      }
      printf $fh "---> TRANSACTION LOG END\n";
    }
  }

  eval { #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

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

  }; #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

  #--- log debug info into transaction log

  my $rv;
  if($@) {
    chomp($@);
    $rv = $@;
    printf $fh "---> TRANSACTION FAILED (%s)\n", $@ if $fh;
    if(!$dbh->rollback()) {
      printf $fh "---> TRANSACTION ABORT FAILED (%s)\n", $dbh->errstr() if $fh;
      $rv .= ', ' . $dbh->errstr();
    } else {
      printf $fh "---> TRANSACTION ABORTED SUCCESSFULLY\n" if $fh
    }
  } else {
    printf $fh "---> TRANSACTION FINISHED SUCCESSFULLY\n" if $fh;
  }

  #--- finish successfully

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
  my $h = $swdata{$host}{'mibs-new'}{'BRIDGE-MIB'};
  my $dbh = dbconn('spam');
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

      next if !exists $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifTable'}{$if};

      #--- skip MACs on ports that are receiving CDP

      next if exists $swdata{$host}{'mibs-new'}{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if};

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
          $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'},
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
          $swdata{$host}{'mibs-new'}{'IF-MIB'}{'ifXTable'}{$if}{'ifName'}{'value'},
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
  my $dbh = dbconn('spam');
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
            join(',', (('?') x scalar(@fields)))
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

  foreach my $if (keys %{$h->{'mibs-new'}{'IF-MIB'}{'ifTable'}}) {
    my $ifTable = $h->{'mibs-new'}{'IF-MIB'}{'ifTable'};
    my $ifXTable = $h->{'mibs-new'}{'IF-MIB'}{'ifXTable'};
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
        exists $h->{'mibs-new'}{'CISCO-CDP-MIB'}
        && exists $h->{'mibs-new'}{'CISCO-CDP-MIB'}{$if}
        && exists $h->{'mibs-new'}{'CISCO-CDP-MIB'}{$if}{'cdpCacheTable'}
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
    exists $hdata->{'mibs-new'}{'CISCO-VTP-MIB'}
    && exists $hdata->{'mibs-new'}{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}
  ) {
    my $trunk_flag;
    my $s = $hdata->{'mibs-new'}{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}{$port};
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
    exists $hdata->{'mibs-new'}{'IEEE8021-PAE-MIB'}
    && exists $hdata->{'mibs-new'}{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}
  ) {
    my %dot1x_flag;
    my $s 
    = $hdata->{'mibs-new'}{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}{$port};
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
    exists $hdata->{'mibs-new'}{'CISCO-AUTH-FRAMEWORK-MIB'}
    && exists $hdata->{'mibs-new'}{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}
  ) {
    my $s = $hdata->{'mibs-new'}{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}{$port};
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
    exists $hdata->{'mibs-new'}{'CISCO-CDP-MIB'}
    && exists $hdata->{'mibs-new'}{'CISCO-CDP-MIB'}{'cdpCacheTable'}
    && exists $hdata->{'mibs-new'}{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$port}
  ) {
    $result |= 1;
  }

  #--- power over ethernet

  if(exists $hdata->{'mibs-new'}{'POWER-ETHERNET-MIB'}{'pethPsePortTable'}) {
    my $pi = $hdata->{'idx'}{'ifIndexToPortIndex'}{$port};
    if(
      exists
        $hdata->{'mibs-new'}
                {'POWER-ETHERNET-MIB'}
                {'pethPsePortTable'}
                {$pi->[0]}{$pi->[1]}
                {'pethPsePortDetectionStatus'}
    ) {
      my $s = $hdata->{'mibs-new'}
                      {'POWER-ETHERNET-MIB'}
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
    exists $hdata->{'mibs-new'}{'BRIDGE-MIB'}
    && exists $hdata->{'mibs-new'}{'BRIDGE-MIB'}{'dot1dStpRootPort'}
  ) {
    my $dot1d_stpr = $hdata->{'mibs-new'}{'BRIDGE-MIB'}{'dot1dStpRootPort'}{'0'};
    for my $vlan (keys %{$hdata->{'mibs-new'}{'BRIDGE-MIB'}}) {
      # the keys under BRIDGE-MIB are both a) vlans b) object names
      # that are not defined per-vlan (such as dot1dStpRootPort);
      # that's we need to filter non-vlans out here
      next if $vlan !~ /^\d+$/;
      if(
        exists $hdata->{'mibs-new'}{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
                       {$dot1d_stpr}
      ) {
        $result |= 4;
        last;
      }
    }
  }

  #--- STP portfast

  if(
    exists $hdata->{'mibs-new'}{'CISCO-STP-EXTENSIONS-MIB'}
    && exists $hdata->{'mibs-new'}{'CISCO-STP-EXTENSIONS-MIB'}{'stpxFastStartPortTable'}
  ) {
    my $port_dot1d = $hdata->{'idx'}{'ifIndexToDot1d'}{$port};
    my $portmode
    = $hdata->{'mibs-new'}{'CISCO-STP-EXTENSIONS-MIB'}
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
  my $dbh = dbconn('spam');
  my ($r, @list, @list2);

  #--- pull data from database ---

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }
  my $sth = $dbh->prepare('SELECT * FROM vtpmasters');
  if(!$sth->execute()) {
    return 'Database query failed (spam,' . $sth->errstr() . ')';
  }
  while(my @a = $sth->fetchrow_array) {
    $a[2] = $cfg->{'community'};  # pre-fill default community string
    if(exists $cfg->{'host'}{$a[0]}{'community'}) {
      $a[2] = $cfg->{'host'}{$a[0]}{'community'};
    }
    push(@list, \@a);
  }

  #--- for VTP domains with preferred masters, eliminate all other masters;
  #--- preference is set in configuration file with "VLANServer" statement

  for my $k (keys %{$cfg->{vlanserver}}) {
    for(my $i = 0; $i < scalar(@list); $i++) {
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
  my $dbh = dbconn('spam');
  my ($sth, $qtype, $q);
  my (@fields, @args, @vals);
  my $managementDomainTable
  = $swdata{$host}{'mibs-new'}{'CISCO-VTP-MIB'}{'managementDomainTable'}{1};

  #--- ensure database connection

  if(!ref($dbh)) { return "Cannot connect to database (spam)"; }

  #--- eval begins here ----------------------------------------------------

  eval {

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
      @vals = ('?') x scalar(@fields);
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

  #--- eval ends here ------------------------------------------------------

  };
  chomp($@);
  my ($msg, $err) = split(/\|/,$@);
  if($msg eq 'DBERR') {
    print "Database update error ($err) on query '$q'\n";
    return "Database update error ($err) on query '$q'";
  }

  #--- ???: why is this updated HERE? ---
  # $swdata{HOST}{stats}{vtpdomain,vtpmode} are not used anywhere

  $stat->{vtpdomain} = $managementDomainTable->{'managementDomainName'}{'value'};
  $stat->{vtpmode} = $managementDomainTable->{'managementDomainLocalMode'}{'value'};

  #--- return successfully

  return undef;
}


#===========================================================================
# This function performs database maintenance.
#
# Returns: 1. Error message or undef
#===========================================================================

sub maintenance
{
  my $dbh = dbconn('spam');
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
  for(my $i = 0; $i < scalar(@$work_list); $i++) {
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
  if(scalar(@insert) > 0) {
    my $e = sql_transaction(\@insert);
    if(!$e) {
      tty_message("[$host] Auto-registration successful\n");
    } else {
      tty_message("[$host] Auto-registration failed ($e)\n");
    }
  }
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

tty_message(
  "\nSwitch Ports Activity Monitor\n"
  . "by Borek.Lupomesky\@vodafone.com\n"
  . "---------------------------------\n"
);

#--- parse command line ----------------------------------------------------


my $get_arptable = 0;
my $get_mactable = 1;
my $quick_mode = 0;
my $no_lock = 0;           # inhibit creation of lock file
my $tasks_max = 8;         # maximum number of background tasks
my $tasks_cur = 0;         # current number of background tasks
my $autoreg = 0;           # autoreg feature
my $cmd_worklist = 0;      # display only a worklist
my ($help, $maint, $list_arpservers, $list_hosts, $cmd_remove_host);
my @poll_hosts;
my $poll_hosts_re;

if(!GetOptions('host=s'     => \@poll_hosts,
               'hostre=s'   => \$poll_hosts_re,
               'arptable!'  => \$get_arptable,
               'help|?'     => \$help,
               'mactable!'  => \$get_mactable,
               'maint'      => \$maint,
               'quick!'     => \$quick_mode,
               'arpservers' => \$list_arpservers,
               'hosts'      => \$list_hosts,
               'tasks=i'    => \$tasks_max,
               'autoreg'    => \$autoreg,
               'remove=s'   => \$cmd_remove_host,
               'worklist'   => \$cmd_worklist,
               'debug'      => \$ENV{'SPAM_DEBUG'}
              )) {
  print "\n"; help(); exit(1);
}
if(scalar(@ARGV) != 0) { print "Invalid arguments\n\n"; help(); exit(1); }
if($help) {
  help();
  exit(0);
}
if($tasks_max < 0 || $tasks_max > 16) {
  print "Number of tasks invalid\n\n";
  exit(1);
}
if($quick_mode == 1) {
  $get_arptable = $get_mactable = 0;
}
if($list_arpservers || $list_hosts) {
  $no_lock = 1;
}

#--- ensure single instance via lockfile -----------------------------------

if(!$no_lock) {
  if(-f "/tmp/spam.lock") {
    print "Another instance running, exiting\n";
    exit 1;
  }
  open(F, "> /tmp/spam.lock") || die "Cannot open lock file";
  print F $$;
  close(F);
}

eval {

	#--- load master configuration file --------------------------------

	tty_message("[main] Loading master config (started)\n");
	if(!ref($cfg = load_config('spam.cfg.json'))) {
	  die "$cfg\n";
	}
	tty_message("[main] Loading master config (finished)\n");

	#--- initialize SPAM_SNMP library

	$SPAM_SNMP::snmpget = $cfg->{snmpget};
	$SPAM_SNMP::snmpwalk = $cfg->{snmpwalk};

	#--- bind to native database ---------------------------------------

	if(!exists $cfg->{dbconn}{spam}) {
	  die "Database binding 'spam' not defined\n";
        }

	#--- run maintenance when user told us to do so --------------------

	if($maint) {
	  tty_message("[main] Maintaining database (started)\n");
	  my $e = maintenance();
	  if($e) { die "$e\n"; }
          tty_message("[main] Maintaining database (finished)\n");
	  die "OK\n";
	}

	#--- host removal --------------------------------------------------

	# Currently only single host removal, the hastname must match
	# precisely

	if($cmd_remove_host) {
	  tty_message("[main] Removing host $cmd_remove_host (started)\n");
	  my $e = sql_host_remove($cmd_remove_host);
	  if($e) {
	    die $e;
	  }
	  tty_message("[main] Removing host $cmd_remove_host (finished)\n");
	  die "OK\n";
	}

	#--- bind to ondb database -----------------------------------------

	if(!exists $cfg->{dbconn}{ondb}) {
	  die "Database binding 'ondb' not defined\n";
        }

	#--- retrieve list of switches -------------------------------------

	{
	  my $e = cfg_switch_list_load;
          tty_message("[main] Loading list of switches (started)\n");
	  if($e) { die "Cannot get switch list ($e)\n"; }
          tty_message("[main] Loading list of switches (finished)\n");
          if($list_hosts) {
            my $n = 0;
            print "\nDumping configured switches:\n\n";
            for my $k (sort keys %{$cfg->{host}}) {
              print $k, "\n";
              $n++;
            }
            print "\n$n switches configured\n\n";
            die "OK\n";
          }
	}

	#--- retrieve list of arp servers ----------------------------------

	if($get_arptable || $list_arpservers) {
          tty_message("[main] Loading list of arp servers (started)\n");
	  my $e = cfg_arpservers_list_load();
	  if($e) { die "Cannot get arp servers list ($e)\n"; }
          tty_message("[main] loading list of arp servers (finished)\n");
          if($list_arpservers) {
            my $n = 0;
            print "\nDumping configured ARP servers:\n\n";
            for my $k (sort { $a->[0] cmp $b->[0] } @{$cfg->{arpserver}}) {
              print $k->[0], "\n";
              $n++;
            }
            print "\n$n ARP servers configured\n\n";
            die "OK\n";
          }
	}

	#--- close connection to ondb database -----------------------------

	tty_message("[main] Closing connection to ondb database\n");
	dbdone('ondb');

	#--- load port and outlet tables -----------------------------------

	tty_message("[main] Loading port table (started)\n");
        my $ret;
	($ret, $port2cp) = load_port_table();
	if($ret) { die "$ret\n"; }
	undef $ret;
	tty_message("[main] Loading port table (finished)\n");

	#--- disconnect parent database handle -----------------------------
	# I'm not sure about behaviour of DBI database handles when using
	# fork(), so let's play safe here. The handle will be automatically
	# reopened by SPAMv2 library.

	dbdone('spam');

	#--- create work list of hosts that are to be processed ------------

	my @work_list;
	my $wl_idx = 0;
	foreach my $host (sort keys %{$cfg->{host}}) {
          if(
            (
              scalar(@poll_hosts) &&
              grep { lc($host) eq lc($_); } @poll_hosts
            ) || (
              $poll_hosts_re &&
              $host =~ /$poll_hosts_re/i
            ) || (
              !scalar(@poll_hosts) && !defined($poll_hosts_re)
            )
          ) {
            push(@work_list, [ 'host', $host, undef ]);
          }
	}
	tty_message("[main] %d hosts scheduled to be processed\n", scalar(@work_list));

	#--- add arptable task to the work list

	if($get_arptable) {
	  push(@work_list, [ 'arp', undef, undef ]);
	}

        #--- --worklist option selected, only print the worklist and finish

        if($cmd_worklist) {
          printf("\nFollowing host would be scheduled for polling\n");
          printf(  "=============================================\n");
          for my $we (@work_list) {
            printf("%s %s\n",@{$we}[0..1]);
          }
          print "\n";
          die "OK\n";
        }

	#--- loop through all tasks ----------------------------------------

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
            if($tasks_cur >= $tasks_max) {
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
              if(!poll_host($host, $get_mactable)) {

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

                if($get_mactable) {
                  tty_message("[$host] Updating mactable (started)\n");
                  $e = sql_mactable_update($host);
                  if(defined $e) { print $e, "\n"; }
                  tty_message("[$host] Updating mactable (finished)\n");
                }

            #--- run autoregistration
	    # this goes over all port descriptions and those, that contain outlet
	    # designation AND have no associated outlet in porttable are inserted
            # there

                if($autoreg) {
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
                $cfg->{'arpserver'}, $cfg->{'community'},
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

};
if($@ && $@ ne "OK\n") {
  if (! -t STDOUT) { print "spam: "; }
  print $@;
}

#--- release lock file ---

if(!$no_lock) {
  unlink("/tmp/spam.lock");
}
