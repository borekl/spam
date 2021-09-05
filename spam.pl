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

  #--- ensure database connection ---

  if(!ref($dbh)) { return 'Cannot connect to database (spam)'; }

  #--- reset 'active' field to 'false'

  $tx->add(
    q{UPDATE mactable SET active = 'f' WHERE host = ? and active = 't'},
    $host->name
  );

  #--- get list of VLANs, exclude non-numeric keys (those do not denote VLANs
  #--- but SNMP objects)

  my @vlans = sort { $a <=> $b } grep(/^\d+$/, keys %$h);

  #--- gather update plan ---

  my $aux = strftime("%c", localtime());

  $host->snmp->iterate_macs(sub (%arg) {
    my ($q, @bind);
    if(
      $host->mactable_db->get_mac($arg{mac})
      || exists $mac_current{$arg{mac}}
    ) {
      # update
      my @fields = (
        'host = ?', 'portname = ?', 'lastchk = ?', q{active = 't'},
      );
      @bind = ( $host->name, $arg{p}, $aux, $arg{mac} );
      $q = sprintf(
        q{UPDATE mactable SET %s WHERE mac = ?},
        join(',', @fields)
      );
    } else {
      my @fields = (
        'mac', 'host', 'portname', 'lastchk', 'active'
      );
      @bind = ( $arg{mac}, $host->name, $arg{p}, $aux, 't' );
      $q = sprintf(
        q{INSERT INTO mactable ( %s ) VALUES ( ?,?,?,?,? )},
        join(',', @fields)
      );
      $mac_current{$arg{mac}} = 1;
    }
    $tx->add($q, @bind) if $q;
  });

  #--- sent data to db and finish---

  $ret = $tx->commit;
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
  foreach my $portname (keys %$idx) {
    my $if = $idx->{$portname};
    $stat->{p_total}++;
    $stat->{p_patch}++ if $port2cp->exists($host->name, $portname);
    $stat->{p_act}++ if $host->snmp->iftable($portname, 'ifOperStatus') == 1;
    # p_errdis used to count errordisable ports, but required SNMP variable
    # is no longer available
    #--- unregistered ports
    if(
      $knownports
      && $host->snmp->iftable($portname, 'ifOperStatus') == 1
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
        strftime('%Y-%m-%d %H:%M:%S', localtime($host->snmp->boottime)),
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

  # --force-host processing
  if($cmd->has_forcehost) {
    # if --force-host is in effect and neither --host or --hostre are present
    # the loaded list of hosts is dropped as only forced host will be processed;
    # FIXME: in that case loading of the host list is unnecessary
    @work_list = () unless $cmd->has_hostre || @{$cmd->hosts};
    # add forced hosts to worklist unless it already is in it
    foreach my $fhost (@{$cmd->forcehost}) {
      push(@work_list, [ 'host', $fhost, undef ])
      unless grep { $_->[0] eq 'host' && $_->[1] eq $fhost } @work_list;
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
          die "hostinfo only\n" if $cmd->hostinfo;

          # find changes and update status table
          $hi->update_db;

          # update swstat table
          tty_message("[$host] Updating swstat table (started)\n");
          switch_info($hi);
          my $e = sql_switch_info_update($hi);
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
