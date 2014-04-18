#!/usr/bin/perl -I/home/spam/SPAM

#===========================================================================
# SWITCH PORTS ACTIVITY MONITOR, 3rd GENERATION
# """""""""""""""""""""""""""""""""""""""""""""
# SWITCH BUG component
#===========================================================================

use strict;
use SPAM;
use SPAMv2;
use Pg;


#--- mailing targets -------------------------------------------------------

my @mail = (
#  [ 'all', 'borek.lupomesky@vodafone.com' ]
  [ 'vin', 'pbxadminml@vodafone.cz' ],
  [ 'all', 'netit@vodafone.cz' ]
);

#--- SQL queries -----------------------------------------------------------

my %sql;
$sql{inactive} =
  "SELECT s.host, s.portname, date_trunc('days', (current_timestamp - lastchg)), cp " .
  "FROM status s LEFT JOIN porttable p " .
  "ON ( s.host = p.host AND s.portname = p.portname ) " .
  "WHERE cp IS NOT NULL AND (current_timestamp - lastchg) > interval '%%'" .
  "AND NOT EXISTS ( SELECT 1 FROM permout WHERE p.site = site AND p.cp = cp )";

$sql{unreg} =
  "SELECT s.host, s.portname, status, cp, flags " .
  "FROM status s LEFT JOIN porttable p " .
  "ON ( s.host = p.host AND s.portname = p.portname ) " .
  "WHERE cp IS NULL AND status = 't' AND (flags % 2) = 0";

#--- global variables ------------------------------------------------------

my $cfg;
      

#===========================================================================

sub compare_ports
{
  my ($p1, $p2) = @_;
  
  #--- parse port names
    
  $p1 =~ /^[A-Za-z]*(\d+)\/(\d+)$/;
  my $p1_mod = $1;
  my $p1_port = $2;
        
  $p2 =~ /^[A-Za-z]*(\d+)\/(\d+)$/;
  my $p2_mod = $1;
  my $p2_port = $2;
                
  #--- compare module numbers, then port numbers
                  
  if($p1_mod != $p2_mod) { return $p1_mod <=> $p2_mod; }
  return ($p1_port <=> $p2_port);
}
                      

#===========================================================================

sub sql_load
{
  my ($type) = @_;
  my $c = v1_dbconn('spam');
  my $q = $sql{$type};
  my $i = $cfg->{inactivethreshold2};
  my $r;
  my @result;
  
  if(!defined $c) { return 'Cannot connect to ONDB database'; }
  if($type eq 'inactive') { $q =~ s/%%/$i seconds/; }
  $r = $c->exec($q);
  if($r->resultStatus != PGRES_TUPLES_OK) {
    my $e = $c->errorMessage;
    chomp($e);
    return "Database query failed ($e)";
  }
  while(my @a = $r->fetchrow) {
    if(grep { $_ eq $a[0]  } @{$cfg->{knownports}}) {
      push(@result, \@a);
    }
  }
  return \@result;
}


#===========================================================================

sub list_inactive
{
  my ($inactive) = @_;
  my (%h, %cp);
  my $s;
  my @result;
  
  #--- header
  
  push(@result, [ undef, "INACTIVE PORTS\n" ]);
  push(@result, [ undef, "==============\n" ]);
  push(@result, [ undef, "Following ports are patched, but long time inactive.\n\n" ]);
  
  #--- make two hashes keyed by host: %h for inactivity period, %cp for cp name

  for my $k (@$inactive) {
    $h{$k->[0]}{$k->[1]}= $k->[2];
    $cp{$k->[0]}{$k->[1]}= $k->[3];
  }
  
  #--- put out actual data
  
  for my $k (sort keys %h) {
    my $no_of_ports = scalar(keys %{$h{$k}});
    my $key = ($k =~ /^(...)/, $1);
    $s = sprintf("%s, %d inactive ports", $k, $no_of_ports);
    push(@result, [ $key, $s . "\n" ]);
    push(@result, [ $key, ('-' x length($s)) . "\n" ]);
    for my $l (sort { compare_ports($a, $b); } keys %{$h{$k}}) {
      push(@result, [ $key, sprintf("%s, %s, %s\n", $l, $h{$k}{$l}, $cp{$k}{$l}) ]);
    }
    push(@result, [ $key, "\n" ]);
  }
  return \@result;
}


#===========================================================================

sub list_unreg
{
  my ($unreg) = @_;
  my %h;
  my @result;

  #--- header
  
  push(@result, [ undef, "UNREGISTERED PORTS\n" ]);
  push(@result, [ undef, "==================\n" ]);
  push(@result, [ undef, "Following ports are active, but not associated with outlet/cp.\n\n" ]);

  #--- make a hash keyed by host

  for my $k (@$unreg) {
    $h{$k->[0]}{$k->[1]}= $k->[2];
  }  

  #--- put out actual data

  for my $k (sort keys %h) {
    my $no_of_ports = scalar(keys %{$h{$k}});
    my $key = ($k =~ /^(...)/, $1);
    my $s = sprintf("%s, %d unregistered ports", $k, $no_of_ports);
    push(@result, [ $key,  $s . "\n" ]);
    push(@result, [ $key, ('-' x length($s)) . "\n" ]);
    for my $l (sort { compare_ports($a, $b); } keys %{$h{$k}}) {
      push(@result, [ $key, sprintf("%s\n", $l) ]);
    }
    push(@result, [ $key, "\n" ]);
  }
  return \@result;
}


#===========================================================================

sub mail_out
{
  my ($data, $site, $email, $subj) = @_;

  open(F, '|-', "mail -s '$subj' '$email'") or return "error sending mail";
  for my $l (@$data) {
    if($site eq $l->[0] || $site eq 'all' || $site == undef ) {
      print F $l->[1];
    }
  }
  close(F);
  return undef;
}


#===========================================================================
#=== main ==================================================================
#===========================================================================

#--- init ------------------------------------------------------------------

tty_message("\nSPAM switch bug\n\n");
if(-f '/tmp/spam-bug.lock') {
  print "Another instance running, exiting\n";
  exit 1;
}
open(F, '> /tmp/spam-bug.lock') || die 'Cannot open lock file';
print F $$;
close(F);

#--- main eval block --------------------------------------------------------

eval {
        #--- load config
        
        tty_message('Loading master config ... ');
        if(!ref($cfg = load_config('spam.cfg'))) {
          chomp($cfg);
          die "$cfg\n";
        }
	tty_message();
        
        #--- bind to native database
        
	if(!exists $cfg->{dbconn}{spam}) {
	  die "Database binding 'spam' not defined\n";
	}
	v1_dbinit('spam', $cfg->{dbconn}{spam}[0], $cfg->{dbconn}{spam}[1], $cfg->{dbconn}{spam}[2], $cfg->{dbconn}{spam}[3]);

	#--- load list of inactive patched ports

	tty_message('Loading list of inactive patched ports ... ');	
	my $inactive = sql_load('inactive');
	if(!ref($inactive)) { die "$inactive\n"; }
	tty_message("done (" . scalar(@$inactive)  . ")\n");

	#--- load list of unregistered active ports

	tty_message('Loading list of unregistered active ports ... ');	
	my $unreg = sql_load('unreg');
	if(!ref($unreg)) { die "$unreg\n"; }
	tty_message("done (" . scalar(@$unreg) . ")\n");

	#--- generate output data

	my $out_inactive = list_inactive($inactive);
	my $out_unreg = list_unreg($unreg);
	
	#--- mailing
	
	for my $k (@mail) {
          tty_message('Mailing reports (' .$k->[0] . ', ' . $k->[1] . ') ... inactive, ');
	  mail_out($out_inactive, $k->[0], $k->[1], 'Inactive switch ports');
	  tty_message('unreg, ');
	  mail_out($out_unreg, $k->[0], $k->[1], 'Unregistered switch ports');
	  tty_message();
	}
};
if($@) {
  print $@, "\n";
}

#--- delete lock file -------------------------------------------------------

unlink('/tmp/spam-bug.lock');
