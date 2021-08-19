#!/usr/bin/perl

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
use experimental 'signatures';
use POSIX qw(strftime);
use Socket;
use Data::Dumper;
use Carp;
use Feature::Compat::Try;

use SPAM::Misc;
use SPAM::SNMP;
use SPAM::Cmdline;
use SPAM::Config;
use SPAM::Host;
use SPAM::DbTransaction;
use SPAM::Model::Porttable;

$| = 1;


#=== global variables ======================================================

my $cfg;             # SPAM::Config instance
my $port2cp;         # switchport->CP mapping (from porttable)
my $arptable;        # arptable data (hash reference)


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
  my $idx = $host->snmp->port_to_ifindex;
  my @idx_keys = (keys %$idx);
  my @update_plan;
  my @stats = (0) x 4;  # i/d/U/u
  my $debug_fh;
  my $s = $host->snmp->_d;

  #--- debug init

  if($ENV{'SPAM_DEBUG'}) {
    open($debug_fh, '>', "debug.find_changes.$$.log");
    if($debug_fh) {
      printf $debug_fh "--> find_changes(%s)\n", $host->name
    }
  }

  # delete: ports that no longer exist (not found via SNMP)
  push(@update_plan, map { [ 'd', $_ ] } $host->vanished_ports);
  $stats[1] = @update_plan;

  #--- now we scan entries found via SNMP ---

  foreach my $k (@idx_keys) {
    # interface's ifIndex
    my $if = $idx->{$k};
    # interface's [portModuleIndex, portIndex]
    my $pi = $host->snmp->ifindex_to_portindex->{$if}
      if $host->snmp->has_ifindex_to_portindex;

    if($host->ports_db->has_port($k)) {

      my $portTable
         = $s->{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};
      my $vmMembershipTable
         = $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};

      #--- update: entry is not new, check whether it has changed ---

      my $old = $host->ports_db;
      my $errdis = 0; # currently unavailable

      #--- collect the data to compare

      my @data = (
        [ 'ifOperStatus', 'n', $old->oper_status($k),
          $host->snmp->iftable($k, 'ifOperStatus') ],
        [ 'ifInUcastPkts', 'n', $old->packets_in($k),
          $host->snmp->iftable($k, 'ifInUcastPkts') ],
        [ 'ifOutUcastPkts', 'n', $old->packets_out($k),
          $host->snmp->iftable($k, 'ifOutUcastPkts') ],
        [ 'vmVlan', 'n', $old->vlan($k),
          $vmMembershipTable->{'vmVlan'}{'value'} ],
        [ 'vlanTrunkPortVlansEnabled', 's', $old->vlans($k),
          $host->snmp->trunk_vlans_bitstring($if) ],
        [ 'ifAlias', 's', $old->descr($k),
          $host->snmp->iftable($k, 'ifAlias') ],
        [ 'portDuplex', 'n', $old->duplex($k),
          $portTable->{'portDuplex'}{'value'} ],
        [ 'ifSpeed', 'n', $old->speed($k),
          $host->snmp->iftable($k, 'ifSpeed') ],
        [ 'port_flags', 'n', $old->flags($k),
          $host->snmp->get_port_flags($if) ],
        [ 'ifAdminStatus', 'n', $old->admin_status($k),
          $host->snmp->iftable($k, 'ifAdminStatus') ],
        [ 'errdisable', 'n', $old->errdisable($k),
          $errdis ]
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
  my $idx = $host->snmp->port_to_ifindex;
  my ($r, $q, $fields);
  my (@fields, @vals, @bind);
  my $s = $host->snmp->_d;

  # get new transaction
  my $tx = SPAM::DbTransaction->new;

  #--- aux function to handle ifSpeed/ifHighSpeed

  # ifSpeed only works up to 40 Gbps), so we prefer ifHighSpeed whenever it
  # is available

  my $ifrate = sub {
    my $if = shift;
    my $ifHighSpeed = $s->{'IF-MIB'}{'ifXTable'}{$if}{'ifHighSpeed'}{'value'};
    my $ifSpeed = $s->{'IF-MIB'}{'ifTable'}{$if}{'ifSpeed'}{'value'};

    if($ifHighSpeed) {
      return $ifHighSpeed;
    } else {
      return int($ifSpeed / 1000000);
    }
  };

  #--- create entire SQL transaction into @update array ---

  for my $k (@$update_plan) {

    my $if = $idx->{$k->[1]};
    my $pi = $host->snmp->ifindex_to_portindex->{$if}
      if $host->snmp->has_ifindex_to_portindex;
    my $current_time = strftime("%c", localtime());
    my $ifTable = $s->{'IF-MIB'}{'ifTable'}{$if};
    my $ifXTable = $s->{'IF-MIB'}{'ifXTable'}{$if};
    my $vmMembershipTable
       = $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if};
    my $portTable
       = $s->{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]};

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
        $host->trunk_vlans_bitstring($if),
        $ifXTable->{'ifAlias'}{'value'},
        $portTable->{'portDuplex'}{'value'},
        #($ifTable->{'ifSpeed'}{'value'} / 1000000) =~ s/\..*$//r,
        $ifrate->($if),
        $host->snmp->get_port_flags($if),
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
          $host->snmp->trunk_vlans_bitstring($if),
          $ifXTable->{'ifAlias'}{'value'} =~ s/'/''/gr,
          $portTable->{'portDuplex'}{'value'},
          #($ifTable->{'ifSpeed'}{'value'} / 1000000) =~ s/\..*$//r,
          $ifrate->($if),
          $host->snmp->get_port_flags($if),
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
    $tx->add($q, @bind);
  }

  #--- sent data to db and finish---

  return $tx->commit;
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
  my %mac_current;         # contents of 'mactable'
  my $debug_fh;

  # get new transaction instance
  my $tx = SPAM::DbTransaction->new;

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

  $tx->add(
    q{UPDATE mactable SET active = 'f' WHERE host = ? and active = 't'},
    $host->name
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
      $tx->add($q, @bind) if $q;
    }
  }

  #--- sent data to db and finish---

  $ret = $tx->commit;
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
  my ($mac, $ret, $q);

  # get new transaction instance
  my $tx = SPAM::DbTransaction->new;

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

      $tx->add(
        q{UPDATE arptable SET ip = ?, lastchk = ? WHERE mac = ?},
        $arptable->{$mac}, $aux, $mac
      );

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

        $tx->add(
          sprintf(
            q{INSERT INTO arptable ( %s ) VALUES ( %s )},
            join(',', @fields),
            join(',', (('?') x @fields))
          ),
          @bind
        );
      }
    }
  }

  #--- send update to the database ---

  return $tx->commit;
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

  my $tx = SPAM::DbTransaction->new;
  my $r;

  #--- perform removal

  for my $table (qw(status hwinfo swstat badports mactable modwire)) {
    $tx->add("DELETE FROM $table WHERE host = ?", $host);
  }
  return $tx->commit;
}


#===========================================================================
# Generate some statistics info on server and store it to host instance.
#===========================================================================

sub switch_info
{
  my ($host) = @_;
  my $stat = $host->port_stats;
  my $knownports = grep { $_ eq $host->name } @{$cfg->knownports};
  my $idx = $host->snmp->port_to_ifindex;

  # if 'knowports' is active, initialize the stat field; the rest is
  # initialized automatically
  $stat->{'p_used'} = 0 if $knownports;

  # do the counts
  foreach my $if (keys %{$host->snmp->{'IF-MIB'}{'ifTable'}}) {
    my $ifTable = $host->snmp->{'IF-MIB'}{'ifTable'};
    my $ifXTable = $host->snmp->{'IF-MIB'}{'ifXTable'};
    my $portname = $ifXTable->{$if}{'ifName'}{'value'};
    $stat->{p_total}++;
    $stat->{p_patch}++ if $port2cp->exists($host->name, $portname);
    $stat->{p_act}++
      if $ifTable->{$if}{'ifOperStatus'}{'enum'} eq 'up';
    # p_errdis used to count errordisable ports, but required SNMP variable
    # is no longer available
    #--- unregistered ports
    if(
      $knownports
      && $ifTable->{$if}{'ifOperStatus'}{'enum'} eq 'up'
      && !$port2cp->exists($host->name, $portname)
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
      if($host->get_port_db($portname, 'age') < 2592000) {
        $stat->{p_used}++;
      }
    }
  }
  return;
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

  return "Database connection failed\n" unless ref $dbh;

  try {
    my $sth = $dbh->prepare('SELECT * FROM vtpmasters');
    $sth->execute;
    while(my @a = $sth->fetchrow_array) {
      $a[2] = $cfg->snmp_community($a[0]);
      push(@list, \@a);
    }
  } catch ($err) {
    chomp $err;
    return 'Database query failed (' . $dbh->errstr . ')';
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
        $host->snmp->location =~ s/'/''/r,
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
        $host->snmp->platform
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
        $host->snmp->location =~ s/'/''/r,
        $stat->{p_total},
        $stat->{p_act},
        $stat->{p_patch},
        $stat->{p_illact},
        $stat->{p_errdis},
        $stat->{p_inact},
        $stat->{p_used},
        strftime('%Y-%m-%d %H:%M:%S', localtime($host->snmp->boottime)),
        $managementDomainTable->{'managementDomainName'}{'value'},
        $managementDomainTable->{'managementDomainLocalMode'}{'value'},
        $host->snmp->platform,
        $host->name
      );

      $q = sprintf($q, join(',', @fields));

    }

    $sth = $dbh->prepare($q);
    $sth->execute(@args);

  #--- try block ends here -------------------------------------------------

  } catch ($err) {
    chomp $err;
    $rv = "Database update error ($err) on query '$q'";
  }

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
  );

  #--- mactable purging

  $dbh->do(
    q{DELETE FROM mactable WHERE (? - date_part('epoch', lastchk)) > ?},
    undef, $t, $cfg->mactableage
  );

  #--- status table purging

  $dbh->do(
    q{DELETE FROM status WHERE (? - date_part('epoch', lastchk)) > ?},
    undef, $t, 7776000 # 90 days
  );

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
  my $tx = SPAM::DbTransaction->new;

  # get site-code from hostname
  my $site = $cfg->site_conv($host->name);

  # iterate over all ports; FIXME: this is iterating ports loaded from the
  # database, not ports actually seen on the host -- this needs to be changed
  # to be correct; the workaround for now is to not run --autoreg on every
  # spam run or just hope the races won't occur
  $host->iterate_ports_db(sub ($portname, $port) {
    my $descr = $port->{descr};
    my $cp_descr;
    if($descr && $descr =~ /^.*?;(.+?);.*?;.*?;.*?;.*$/) {
      $cp_descr = $1;
      next if $cp_descr eq 'x';
      next if $cp_descr =~ /^(fa\d|gi\d|te\d)/i;
      $cp_descr = substr($cp_descr, 0, 10);
      if(!$port2cp->exists($host->name, $portname)) {
        $tx->add($port2cp->insert(
          host => $host->name,
          port => $portname,
          cp => $cp_descr,
          site => $site
        ));
      }
    }
    # continue iterating
    return undef;
  });

  # insert data into database
  my $msg = sprintf(
    'Found %d entr%s to autoregister',
    $tx->count, $tx->count == 1 ? 'y' : 'ies'
  );
  tty_message("[%s] %s\n", $host->name, $msg);
  if($tx->count) {
    my $e = $tx->commit;
    if(!$e) {
      tty_message("[%s] Auto-registration successful\n", $host->name);
    } else {
      tty_message("[%s] Auto-registration failed ($e)\n", $host->name);
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

  die "Database binding 'spam' not defined\n"
  unless exists $cfg->config()->{dbconn}{spam};

	#--- run maintenance when user told us to do so --------------------

	if($cmd->maintenance()) {
	  tty_message("[main] Maintaining database (started)\n");
	  my $e = maintenance();
	  if($e) { die "$e\n"; }
          tty_message("[main] Maintaining database (finished)\n");
	  die "OK\n";
	}

	#--- host removal --------------------------------------------------

	# Currently only single host removal, the hostname must match
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

  die "Database binding 'ondb' not defined\n"
  unless exists $cfg->config()->{dbconn}{ondb};

	#--- retrieve list of switches -------------------------------------

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
	$port2cp = SPAM::Model::Porttable->new;
	tty_message("[main] Loading port table (finished)\n");

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

  push(@work_list, [ 'arp', undef, undef ]) if $cmd->arptable();

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
    }

    #--- child ---------------------------------------------------------

    else {
      if($task->[0] eq 'host') {
        tty_message("[$host] Processing started\n");

        try {

          my $hi = SPAM::Host->new(name => $host, mesg => sub ($s, @arg) {
            tty_message("$s\n", @arg);
          });

          # perform host poll
          $hi->poll($cmd->mactable, $cmd->hostinfo);

          # only hostinfo, no more processing
          die "\n" if $cmd->hostinfo;

          # find changes and update status table
          tty_message("[$host] Updating status table (started)\n");
          my ($update_plan, $update_stats) = find_changes($hi);
          tty_message(
            sprintf(
              "[%s] Updating status table (i=%d/d=%d/U=%d/u=%d)\n",
              $host, @$update_stats
            )
          );
          my $e = sql_status_update($hi, $update_plan);
          if($e) {
            tty_message("[$host] Updating status table (failed, $e)\n");
          } else {
            tty_message("[$host] Updating status table (finished)\n");
          }

          # update swstat table
          tty_message("[$host] Updating swstat table (started)\n");
          switch_info($hi);
          $e = sql_switch_info_update($hi);
          if($e) { tty_message("[$host] Updating swstat table ($e)\n"); }
          tty_message("[$host] Updating swstat table (finished)\n");

          # update mactable
          if($cmd->mactable()) {
            tty_message("[$host] Updating mactable (started)\n");
            $e = sql_mactable_update($hi);
            if(defined $e) { print $e, "\n"; }
            tty_message("[$host] Updating mactable (finished)\n");
          }

          # save SNMP data for use by frontend
          $hi->save_snmp_data;

          # run autoregistration
          if($cmd->autoreg()) {
            tty_message("[$host] Running auto-registration (started)\n");
            sql_autoreg($hi);
            tty_message("[$host] Running auto-registration (finished)\n");
          }
        }

        catch ($err) {
          chomp $err;
          tty_message("[$host] Host poll failed ($err)\n");
        }

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

} catch ($err) {
  if($err && $err ne "OK\n") {
    if (! -t STDOUT) { print "spam: "; }
    print $_;
  }
}

#--- release lock file ---

if(!$cmd->no_lock()) {
  unlink("/tmp/spam.lock");
}
