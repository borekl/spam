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
use experimental 'signatures', 'postderef';
use POSIX qw(strftime);
use Socket;
use Carp;
use Feature::Compat::Try;

use SPAM::Misc;
use SPAM::SNMP;
use SPAM::Cmdline;
use SPAM::Config;
use SPAM::Host;

$| = 1;

#-------------------------------------------------------------------------------
# This function finds another task to be scheduled for run.
sub schedule_task ($work_list)
{
  die unless ref $work_list;
  foreach (@$work_list) { return $_ unless defined $_->[1] }
  return undef;
}

#-------------------------------------------------------------------------------
# This function sets "pid" field in work list to 0, marking it as finished.
sub clear_task_by_pid ($work_list, $pid)
{
  foreach (@$work_list) {
    if($_->[1] == $pid) {
      $_->[1] = 0;
      return $_;
    }
  }
  return undef;
}

# display title
tty_message(<<EOHD);

Switch Ports Activity Monitor
by Borek.Lupomesky\@vodafone.com
---------------------------------
EOHD

# parse command line
my $cmd = SPAM::Cmdline->instance;

# ensure single instance via lockfile
unless($cmd->no_lock) {
  if(-f '/tmp/spam.lock') {
    print "Another instance running, exiting\n";
    exit(1);
  }
  open(F, '> /tmp/spam.lock') || die 'Cannot open lock file';
  print F $$;
  close(F);
}

try {

	# load master configuration file
	tty_message("[main] Loading master config (started)\n");
	my $cfg = SPAM::Config->instance();
	tty_message("[main] Loading master config (finished)\n");

	# initialize SPAM_SNMP library
	$SPAM_SNMP::snmpget = $cfg->snmpget;
	$SPAM_SNMP::snmpwalk = $cfg->snmpwalk;

	# bind to native database
  die "Database binding 'spam' not defined\n"
  unless exists $cfg->config()->{dbconn}{spam};

	# run maintenance when user told us to do so
	if($cmd->maintenance()) {
	  tty_message("[main] Maintaining database (started)\n");
    maintenance();
    tty_message("[main] Maintaining database (finished)\n");
	  die "OK\n";
	}

  # host removal; currently only single host removal, the hostname must much
  # exactly
	if(my $cmd_remove_host = $cmd->remove_host) {
	  tty_message("[main] Removing host $cmd_remove_host (started)\n");
    SPAM::Host->new(name => $cmd_remove_host)->drop;
	  tty_message("[main] Removing host $cmd_remove_host (finished)\n");
	  die "OK\n";
	}

	# bind to ondb database
  die "Database binding 'ondb' not defined\n"
  unless exists $cfg->config()->{dbconn}{ondb};

	# retrieve list of switches
  if($cmd->list_hosts) {
    my $n = 0;
    print "\nDumping configured switches:\n\n";
    for my $k (sort keys $cfg->hosts->%*) {
      print $k, "\n";
      $n++;
    }
    print "\n$n switches configured\n\n";
    die "OK\n";
  }

	# retrieve list of arp servers
	if($cmd->arptable || $cmd->list_arpservers) {
    tty_message("[main] Loading list of arp servers (started)\n");
    if($cmd->list_arpservers) {
      my $n = 0;
      print "\nDumping configured ARP servers:\n\n";
      for my $k (sort { $a->[0] cmp $b->[0] } $cfg->arpservers->@*) {
        print $k->[0], "\n";
        $n++;
      }
      print "\n$n ARP servers configured\n\n";
      die "OK\n";
    }
	}

  # create work list of hosts that are to be polled for data
  my $poll_hosts_re = $cmd->hostre;
  my $hosts = $cfg->worklist(sub ($h, $v) {
    my $rv = $v;
    # filtering by host enumeration
    $rv = undef if $cmd->hosts->@* && !(grep { lc($h) eq lc($_); } $cmd->hosts->@*);
    # filtering by host regular expression
    $rv = undef if $poll_hosts_re && $h !~ /$poll_hosts_re/i;
    # remove arptable
    $rv = [ grep { $_ ne 'arpsource' } @$rv ] unless $cmd->arptable;
    # finish
    return $rv;
  });

  # --force-host processing
  if($cmd->has_forcehost) {
    # if --force-host is in effect and neither --host or --hostre are present
    # the loaded list of hosts is dropped as only forced host will be processed;
    # FIXME: in that case loading of the host list is unnecessary
    $hosts = {} unless $cmd->has_hostre || $cmd->hosts->@*;
    # add forced hosts to worklist unless it already is in it
    foreach my $fhost ($cmd->forcehost->@*) {
      $hosts->{$fhost} = [ 'switch '];
    }
  }

	tty_message(
    "[main] %d hosts scheduled to be processed\n", scalar(keys %$hosts)
  );

  # --worklist option selected, only print the worklist and finish
  if($cmd->list_worklist) {
    printf("\nFollowing host would be scheduled for polling\n");
    printf(  "=============================================\n");
    for my $h (sort keys %$hosts) {
      print scalar(grep { $_ eq 'switch' } $hosts->{$h}->@*) ? 'S' : ' ';
      print scalar(grep { $_ eq 'arpsource' } $hosts->{$h}->@*) ? 'A' : ' ';
      printf("  %s\n", $h);
    }
    printf("\n%d hosts scheduled\n\n", scalar(keys %$hosts));
    die "OK\n";
  }

  # host instance creation helper
  my $ht = sub ($h, $roles) {
    SPAM::Host->new(
      name => $h, roles => $roles, mesg => sub ($s, @arg) {
        tty_message("$s\n", @arg);
      }
    );
  };

  # convert current list of hosts to worklist array
  my @work_list;
  foreach my $h (keys %$hosts) {
    push(@work_list, [ $ht->($h, $hosts->{$h}), undef ]);
  }

	# loop through all tasks
	my $tasks_cur = 0;

	while(defined(my $task = schedule_task(\@work_list))) {
    my $hi = $task->[0];
    my $pid = fork();

    # failed to fork
    if($pid == -1) {
      die "Cannot fork() new process";
    }

    # parent process
    elsif($pid > 0) {
      $tasks_cur++;
      $task->[1] = $pid;
      tty_message("[main] Child %s (pid %d) started\n", $hi->name, $pid);
      if($tasks_cur >= $cmd->tasks) {
        my $cpid;
        if(($cpid = wait()) != -1) {
          $tasks_cur--;
          my $ctask = clear_task_by_pid(\@work_list, $cpid);
          tty_message("[main] Child %s reaped\n", $ctask->[0]->name);
        } else {
          die 'Assertion failed! No children running.';
        }
      }
    }

    # child process
    else {
      tty_message(
        "[%s] Processing started (%s)\n", $hi->name, join(',', $hi->roles->@*)
      );

      try {

        # display SNMP profile
        tty_message("[%s] SNMP profile: %s\n", $hi->name, $hi->snmp_profile);

        # perform host poll
        $hi->poll($cmd->mactable, $cmd->hostinfo);

        # only hostinfo, no more processing
        die "hostinfo only\n" if $cmd->hostinfo;

        # find changes and update status table
        $hi->update_db;

        if($hi->has_role('switch')) {

          # update swstat table
          tty_message("[%s] Updating swstat table (started)\n", $hi->name);
          $hi->swstat->update($hi->snmp, $hi->port_stats);
          tty_message("[%s] Updating swstat table (finished)\n", $hi->name);

          # update mactable
          if($cmd->mactable()) {
            tty_message("[%s] Updating mactable (started)\n", $hi->name);
            $hi->update_mactable;
            tty_message("[%s] Updating mactable (finished)\n", $hi->name);
          }

          # save SNMP data for use by frontend
          $hi->save_snmp_data;

          # run autoregistration
          if($cmd->autoreg()) {
            tty_message("[%s] Running auto-registration (started)\n", $hi->name);
            $hi->autoregister;
            tty_message("[%s] Running auto-registration (finished)\n", $hi->name);
          }

        }
      }

      catch ($err) {
        chomp $err;
        tty_message("[%s] Host poll failed ($err)\n", $hi->name);
      }

	    # child finish
      exit(0);
	  }

	} # the concurrent section ends here

  #--- clean-up ------------------------------------------------------

  my $cpid;
  while(($cpid = wait()) != -1) {
    $tasks_cur--;
    my $ctask = clear_task_by_pid(\@work_list, $cpid);
    tty_message("[main] Child %s reaped\n", $ctask->[0]->name);
    tty_message("[main] $tasks_cur children remaining\n");
  }
  die "Assertion failed! \$tasks_cur non-zero." if $tasks_cur;
  tty_message("[main] Concurrent section finished\n");

} catch ($err) {
  if($err && $err ne "OK\n") {
    unless(-t STDOUT) { print 'spam: '; }
    print $err;
  }
}

# release lock file
unlink('/tmp/spam.lock') unless $cmd->no_lock;
