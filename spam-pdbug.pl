#!/usr/bin/perl -I/home/spam/SPAM

#===========================================================================
# SWITCH PORTS ACTIVITY MONITOR, 3rd GENERATION
# """""""""""""""""""""""""""""""""""""""""""""
# PORT DOWN BUG component
#===========================================================================

use strict;
use SPAMv2;

my $cfg;
my @monit_hosts = qw(vdcs00c vdcs01c vdcs02c vdcs03c vdcs04c vdcs05c vdcs06c vdcs07c vdcs08c);
my $query1 = <<EOHD;
SELECT
  portname, vlan, s.descr, flags, cp, p.chg_who, p.chg_when, errdis,
  extract(epoch from (lastchk - lastchg)) as inact, hostname, grpid, r.descr
FROM status s
  FULL JOIN porttable p USING (host, portname)
  LEFT JOIN hosttab h USING (site, cp)
  LEFT JOIN prodstat r ON prodstat = prodstat_i
WHERE s.host = ?
  AND grpid = ?
  AND status = 'f'
  AND adminstatus = 't'
EOHD

my $query2 = <<EOHD;
SELECT
  portname, vlan, s.descr, flags, cp, p.chg_who, p.chg_when, errdis,
  extract(epoch from (lastchk - lastchg)) as inact, hostname, grpid, r.descr
FROM status s
  FULL JOIN porttable p USING (host, portname)
  LEFT JOIN hosttab h USING (site, cp)
  LEFT JOIN prodstat r ON prodstat = prodstat_i
WHERE s.host = ?
  AND status = 'f'
  AND adminstatus = 't'
EOHD
              
my $query_grp = 'SELECT grpid, email FROM groups WHERE email IS NOT NULL';


#===========================================================================
#===========================================================================

sub load_switch_data
{
  my $grpid = shift;
  my $db_spam = dbconn('spam');

  if(!ref($db_spam)) {
    chomp($db_spam);
    return "$db_spam\n";
  }
  my %swdata;
  for my $sw (@monit_hosts) {
    my $sth;
    if(!$grpid) {
      $sth = $db_spam->prepare($query2);
      $sth->execute($sw) || return 'Cannot query database (' . $sth->errstr . ')';
    } else {
      $sth = $db_spam->prepare($query1);
      $sth->execute($sw, $grpid) || return 'Cannot query database (' . $sth->errstr . ')';
    }
    $swdata{$sw} = $sth->fetchall_arrayref();
  }
  return \%swdata;
}


#===========================================================================
#===========================================================================

sub create_report
{
  my $swdata = shift;
  my $result;
  my $hosthead;

  $result .= "port     vla  cp        inactive   description       owner     hostname      status    \n";
  $result .= "====     ===  ========  =========  ================  ========  ============  ==========\n";
  for my $host (sort keys %$swdata) {
    $hosthead = "--- $host ---------------------------------------------------------------------------\n";
    for my $row (@{$swdata->{$host}}) {
      if($hosthead) { $result .= $hosthead; $hosthead = undef; }
      $result .= sprintf('%-7s  ', $row->[0]);     # portname
      $result .= sprintf('%3d  ', $row->[1]);      # vlan
      $result .= sprintf('%-8s  ', substr($row->[4],0,8)); # cp
      $result .= sprintf('%-9s  ', period($row->[8])); # inactivity
      $result .= sprintf('%-16s  ', substr($row->[2],0,16)); # descr
      $result .= sprintf('%-8s  ', $row->[10]); # owner group
      $result .= sprintf('%-12s  ', substr($row->[9],0,12)); # hostname
      $result .= sprintf('%-8s  ', $row->[11]);  # production status
      $result .= "\n";
    }
  }
  return $result;
}


#===========================================================================
# MAIN
#===========================================================================

#--- splash ----------------------------------------------------------------

tty_message("\nSPAM port down bug\n\n");

#--- lock ------------------------------------------------------------------

if(-f '/tmp/spam-pdbug.lock') {
  print "Another instance running, exiting\n";
  exit 1;
}
open(F, '> /tmp/spam-pdbug.lock') || die 'Cannot open lock file';
print F $$;
close(F);


#--- eval begins here ------------------------------------------------------

eval {

#--- load config -----------------------------------------------------------

tty_message('Loading master config ... ');
if(!ref($cfg = load_config('spam.cfg'))) {
  chomp($cfg);
  die "$cfg\n";
}
tty_message();

#--- database binding ------------------------------------------------------

if(!exists $cfg->{dbconn}{spam}) { die "Database binding 'spam' not defined\n"; }
dbinit('spam', $cfg->{dbconn}{spam}[0], $cfg->{dbconn}{spam}[1],
       $cfg->{dbconn}{spam}[2], $cfg->{dbconn}{spam}[3]); 

if(!exists $cfg->{dbconn}{ondb}) { die "Database binding 'ondb' not defined\n"; }
dbinit('ondb', $cfg->{dbconn}{ondb}[0], $cfg->{dbconn}{ondb}[1],
       $cfg->{dbconn}{ondb}[2], $cfg->{dbconn}{ondb}[3]);
      
#--- connect to database ---------------------------------------------------

my $db_ondb = dbconn('ondb');
if(!ref($db_ondb)) {
  chomp($db_ondb);
  die "$db_ondb\n";
} else {
  $db_ondb->{FetchHashKeyName} = 'NAME_lc';
}

#--- load groups

my $grpdata;
{
  tty_message("Loading groups from ONDB ... ");
  my $sth = $db_ondb->prepare($query_grp);
  $sth->execute() || die 'Cannot query database (' . $sth->errstr . ')';
  $grpdata = $sth->fetchall_hashref('grpid');
  tty_message();
}

#--- iterate over all groups -----------------------------------------------

my %report;
for my $grp (keys %$grpdata) {
  my $swdata;
  tty_message("Retrieving data for group $grp ... ");
  if($grp eq 'nmc' || $grp eq 'netit') {
    $swdata = load_switch_data(undef);
  } else {
    $swdata = load_switch_data($grp);
  }
  my $cnt = 0;
  for my $sw (@monit_hosts) {
    $cnt += scalar(@{$swdata->{$sw}});
  }
  tty_message("$cnt\n");
  next if($cnt == 0);
  $report{$grp} = create_report($swdata);
}

#--- mail

#for my $g (keys %report) {
for my $g ('netit') {
  next if !$report{$g};
  open(F, '|-', "mail -s 'SPAM Host Monitoring' '" . $grpdata->{$g}{email} . "'") || die "Cannot send mail";
  print F "Following switch ports are down\n\n";
  print F $report{$g};
  close(F)
}

#--- eval ends here --------------------------------------------------------

};
if($@ && $@ ne "OK\n") {
  print $@;
}
unlink('/tmp/spam-pdbug.lock');
