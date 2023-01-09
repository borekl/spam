#!/usr/bin/perl

#===========================================================================
# SWITCH PORTS ACTIVITY MONITOR, 3rd GENERATION
# """""""""""""""""""""""""""""""""""""""""""""
# SNMP COLLECTOR component
#
# © 2000-2023 Borek Lupomesky <Borek.Lupomesky@vodafone.com>
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
use Carp;
use Feature::Compat::Try;

use SPAM::Misc;
use SPAM::SNMP;
use SPAM::Cmdline;
use SPAM::Config;
use SPAM::Host;
use SPAM::DbTransaction;

$| = 1;

# global variables
my $arptable;        # arptable data (hash reference)

#===========================================================================
# This function updates arptable in backend database
#===========================================================================

sub sql_arptable_update
{
  my $cfg = SPAM::Config->instance;
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
	my $cfg = SPAM::Config->instance();
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
    maintenance();
    tty_message("[main] Maintaining database (finished)\n");
	  die "OK\n";
	}

	#--- host removal --------------------------------------------------

	# Currently only single host removal, the hostname must match
	# precisely

	if(my $cmd_remove_host = $cmd->remove_host()) {
	  tty_message("[main] Removing host $cmd_remove_host (started)\n");
    SPAM::Host->new(name => $cmd_remove_host)->drop;
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

          # display SNMP profile
          tty_message("[$host] SNMP profile: %s\n", $hi->snmp_profile);

          # perform host poll
          $hi->poll($cmd->mactable, $cmd->hostinfo);

          # only hostinfo, no more processing
          die "hostinfo only\n" if $cmd->hostinfo;

          # find changes and update status table
          $hi->update_db;

          # update swstat table
          tty_message("[$host] Updating swstat table (started)\n");
          $hi->swstat->update($hi->snmp, $hi->port_stats);
          tty_message("[$host] Updating swstat table (finished)\n");

          # update mactable
          if($cmd->mactable()) {
            tty_message("[$host] Updating mactable (started)\n");
            $hi->update_mactable;
            tty_message("[$host] Updating mactable (finished)\n");
          }

          # save SNMP data for use by frontend
          $hi->save_snmp_data;

          # run autoregistration
          if($cmd->autoreg()) {
            tty_message("[$host] Running auto-registration (started)\n");
            $hi->autoregister;
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
  die "Assertion failed! \$tasks_cur non-zero." if $tasks_cur;
  tty_message("[main] Concurrent section finished\n");

} catch ($err) {
  if($err && $err ne "OK\n") {
    if (! -t STDOUT) { print "spam: "; }
    print $_;
  }
}

# release lock file
unlink("/tmp/spam.lock") unless $cmd->no_lock();
