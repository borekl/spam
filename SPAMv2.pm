#!/usr/bin/perl

#===========================================================================
# Switch Ports Activity Monitor -- support library, DBI version
# """""""""""""""""""""""""""""
# 2000-2010 Borek Lupomesky <Borek.Lupomesky@oskarmobil.cz>
#===========================================================================


package SPAMv2;
require Exporter;
use Carp;
use DBI;
use JSON::MaybeXS;
use integer;
use warnings;
use strict;

our @ISA = qw(Exporter);
our @EXPORT = qw(
  dbinit
  dbconn
  dbdone
  html_begin
  html_end
  html_fill_up
  load_config
  period
  site_conv
  speed_fmt
  str_maxlen
  tty_message
  user_access_evaluate
  sql_find_user_group
  compare_ports
  load_port_table
  sql_sites
  sql_site_uses_cp
  multipush
  file_lineread
  sql_show_query
);


#=== variables =============================================================

#--- configuration
my $cfg;

#--- Database connection parameters ---
my %dbconn;
my %sites_cache;

#--- configuration ---
my %dbi_params = ( AutoCommit => 1, pg_enable_utf => 1, PrintError => 0 );


#===========================================================================
# Load configuration from JSON file (with relaxed parsing rules, so comments
# and trailing commas are allowed. Return value can be either:
#
# 1) hashref -> config was successfully loaded from the specified file
#               OR config was loaded previously and cached content was used
# 2) scalar  -> error message
# 3) undef   -> loading of the file was attempted, but no file was specified
#               (in other words, the caller tried to get a cached value,
#               which did not exist).
#===========================================================================

sub load_config
{
  #--- if config already loaded, just return it, note, that the config is
  #--- returned regardless of the file that's passed in

  return $cfg if ref($cfg);

  #--- if the config file is undefined, return undef; this is important
  #--- because of the above behaviour

  my ($cfg_file) = @_;
  return undef if !$cfg_file;

  #--- read and parse config

  my $json_input;
  my $js = JSON->new()->relaxed(1);

  local $/;
  open(my $fh, '<', $cfg_file) || return 'Cannot open configuration file';
  $json_input = <$fh>;

  return $cfg = $js->decode($json_input);
}


#===========================================================================
# Express time in seconds in NNdNNhNNm form
#
# Arguments: 1. Number of seconds
# Returns:   1. Formatted string
#===========================================================================

sub period
{
  my ($p) = @_;
  my ($d, $h, $m, $r);
    
  $d = $p / 86400;  $p %= 86400;
  $h = $p / 3600;   $p %= 3600;
  $m = $p / 60;
          
  if($d >= 1) { $m = 0; }
  if($d >= 30) { $h = 0; }
          
  $r = '';
  $r .= "${d}d" if $d;
  $r .= "${h}h" if $h;
  $r .= "${m}m" if $m;
                  
  return $r;
}
                    

#===========================================================================
# Fill a string given as an argument up with spaces to a given length. HTML
# markups are not considered to be a part of the string as its length is
# concerned! Resulting string is returned as a function value.
#
# Arguments: 1. String to be filled-up
#            2. Desired length of resulting string
# Returns:   1. Filled-up string
#===========================================================================

sub html_fill_up
{
  my ($s, $n) = @_;
  my $q;
  
  $q = $s;
  $q =~ s/\<.*?\>//g;

  return $s . (" " x ($n - length($q)));
}


#===========================================================================
# Convert raw speed in bytes per seconds to bit more condensed format
# using M and G suffixes.
#
# Arguments: 1. Unsuffixed number
# Returns:   1. Suffixed number
#===========================================================================

sub speed_fmt
{
  my ($speed) = @_;
  
  if($speed eq "10000000") { return "10M"; }
  if($speed eq "100000000") { return "100M"; }
  if($speed eq "1000000000") { return "1G"; }
  return "?";
}


#===========================================================================
# Closes database connection and frees binding.
#
# Arguments: 1. Connection id
#===========================================================================

sub dbdone
{
  my ($dbid) = @_;

  #--- sanitize input
    
  if(!defined $dbid) {
    croak 'dbdone(): Undefined id passed in as an argument';
  }
  
  #--- if not connected, do nothing
  
  return if !$dbconn{$dbid};
  
  #--- disconnect from db, forget the handle
  
  $dbconn{$dbid}->disconnect();
  delete $dbconn{$dbid};
}


#===========================================================================
# This is kept only for compatibility with the old SPAM version
#===========================================================================

sub dbinit
{
  my $dbid = $_[0];
  $cfg->{'dbconn'}{$dbid} = {
    'dbname' => $_[1],
    'dbuser' => $_[2],
    'dbpass' => $_[3],
    'dbhost' => $_[4]
  };
}


#===========================================================================
# Function returns valid DBI database handle. If the
# connection does not exist yet it tries to create one. If such attempt
# is unsuccessful, undef is returned.
#
# Arguments: 1. Connection id
# Returns:   1. DBI handle or undef or error message
#===========================================================================

sub dbconn
{
  my ($dbid) = @_;
  
  #--- sanitize input
  
  if(!defined $dbid) {
    croak "dbconn(): Undefined id passed in as an argument";
  }
  
  #--- if alread connected, just return the handle
  
  if(exists $dbconn{$dbid}) {
    return $dbconn{$dbid};
  }

  #--- otherwise try to connect to the database
  
  my @dbd_src;
  my $dbc = $cfg->{'dbconn'}{$dbid};
  push(@dbd_src, 'dbi:Pg:dbname=' . $dbc->{'dbname'});
  push(@dbd_src, 'host=' . $dbc->{'dbhost'}) if $dbc->{'dbhost'};
  my $dbh = DBI->connect(
    join(';', @dbd_src),
    $dbc->{'dbuser'},
    $dbc->{'dbpass'},
    \%dbi_params
  );
  if(!ref($dbh)) {
    return DBI::errstr();
  }

  return $dbconn{$dbid} = $dbh;
}


#===========================================================================
# Begins HTML page
#
# Arguments: 1. File descriptor
#            2. HTML title
#            3. optional CSS style definition file(s) (array reference)
#===========================================================================

sub html_begin
{
  my ($html, $title, $css) = @_;

  print $html '<!doctype html>';
  print $html "\n\n<html>\n\n";
  print $html "<head>\n";
  print $html "  <title>$title</title>\n";
  foreach(@$css) {
    print $html qq{  <link rel=stylesheet type="text/css" href="$_">\n};
  }
  print $html "</HEAD>\n\n";
  print $html "<BODY>\n\n";
}


#===========================================================================
# Ends HTML page
#
# Arguments: 1. File descriptor
#===========================================================================

sub html_end
{
  my ($html) = @_;

  print $html "\n</BODY>\n</HTML>\n";
}


#===========================================================================
# Displays message on TTY
#
# Arguments: 1. message
#===========================================================================

sub tty_message
{
  my $msg = shift;

  if(!defined $msg) { $msg = "done\n"; }
  printf($msg, @_) if -t STDOUT;
}


#===========================================================================
# This function strips strings to given size and adds ellipsis.
#===========================================================================

sub str_maxlen
{
  my ($s, $n) = @_;

  if(length($s) > $n) {
    $s = substr($s, 0, $n - 3);
    $s .= '...';
  }
  return $s;
}


#===========================================================================
# Convert hostname (e.g. 'vdcS02c') to site code (e.g. 'vin')
#===========================================================================

sub site_conv
{
  my $host = shift;
  my $hc;
  
  $host =~ /^(...)/;
  $hc = lc($1);
  my $site = $cfg->{siteconv}{$hc};
  if(!$site) { $site = $hc; }
  return $site;
}


#===========================================================================
# Evaluate user's access, this function does checks for overrides.
# 
# Arguments: 1. user id
#            2. access right name
# Returns:   1. undef on success, error message otherwise
#            2. 0|1 -> fail|pass
#===========================================================================

sub user_access_evaluate
{
  my ($user, $access) = @_;
  my $c = dbconn('ondb');
  my ($sth, $r, $v);
  
  #--- sanitize arguments

  if(!$user || !$access) { return 'Required argument missing'; }
  $user = lc $user;
  $access = lc $access;
  
  #--- ensure database connection
  
  if(!ref($c)) { return 'Database connection failed (ondb)'; }
  
  #--- query
  
  $sth = $c->prepare(q{SELECT authorize_user(?, 'spam', ?)::int});
  $r = $sth->execute($user, $access);
  if(!$r) {
    return 'Database query failed (' . $c->errstr() . ')';
  }
  ($v) = $sth->fetchrow_array();
  return (undef, $v);
}


#===========================================================================
# This finds a group associated with current user; this info is retrieved
# from database "ondb", table "users", field "grpid". 
# 
# Arguments: 1. user id
#
# Returns:   1. undef on success, error message otherwise
#            2. group id
#===========================================================================

sub sql_find_user_group
{
  my ($user) = @_;
  my $c = dbconn('ondb');
  my ($q, $r, $sth, $group);

  #--- sanitize arguments

  if(!$user) { return 'No user name specified'; }
  $user = lc $user;

  #--- ensure database connection

  if(!ref($c)) {
    return 'Database connection failed (ondb)';
  }

  #--- perform query

  $sth = $c->prepare('SELECT grpid FROM users WHERE userid = ?');
  $r = $sth->execute($user);
  if(!$r) {
    return 'Database query failed (' . $sth->errstr() . ')';
  }
  ($group) = $sth->fetchrow_array();

  if(!$group) { return "Cannot find user or no group assigned"; }
  return (undef, $group);
}


#==========================================================================
# Parse switch port designation (as in ifName) into an array of sub-tokens
# (returned as array-ref).
#
# Arguments: 1. ifName
#
# Returns:   2. undef on error, on success array reference with sub-tokens
#==========================================================================

sub parse_port
{ 
  my $port = shift;
  my @result;
    
  my @p = split(/\//, $port);
  if($p[0] =~ /^([a-z]+)(\d+)$/i) {
    @result = ($1, $2);
  } else {
    return undef;
  }
                    
  for(my $i = 1; $i < scalar(@p) ; $i++) {
    $result[$i+1] = $p[$i];
  }
                           
  return \@result;
}


#==========================================================================
# Compare two switch port names for sorting purposes. 
#
# Arguments: 1. Port 1
#            2. Port 2
#            3. mode (0 - numbers first, 1 - types first)
#
# Returns:   1. integer as from <=> or cmp operators
#==========================================================================

sub compare_ports
{
  my $port1 = shift;
  my $port2 = shift;
  my $mode = shift;
   
  #--- process input
  my $p1 = parse_port($port1);
  my $p2 = parse_port($port2);
  if(!ref($p1) || !ref($p2)) { return undef; }
  
  #--- perform separate type/num comparisons
  my $comp_type = ($p1->[0] cmp $p2->[0]);
  my $comp_num = 0;
  my $n = scalar(@$p1) > scalar(@$p2) ? scalar(@$p1) : scalar(@$p2);
  for(my $i = 1; $i < $n; $i++) {
    if(not exists $p1->[$i]) {
      $comp_num = -1;
      last;
    }
    if(not exists $p2->[$i]) {
      $comp_num = 1;
      last;
    }
    if($p1->[$i] != $p2->[$i]) {
      $comp_num = $p1->[$i] <=> $p2->[$i];
      last;
    }
  }

  #--- integrate result
  if($comp_type == $comp_num) { return $comp_type; }
  if($comp_type == 0) { return $comp_num; }
  if($comp_num == 0) { return $comp_type; }
  if(!$mode) { return $comp_num; }
  return $comp_type;
}
                       

#===========================================================================
# Loads ports to consolidation point map
#
# This seems to be somewhat inefficient since this loads all the 4000+ entry
# porttable into memory even if only one host is being polled. The
# information is only used for swstat generation.
#
# Arguments: -none-
# Returns:   1. error message or empty string
#            2. port to cons. point hash
#===========================================================================

sub load_port_table
{
  my ($r, $e);
  my $dbh = dbconn('spam');
  my %port2cp;
  
  if(!ref($dbh)) { return 'Database connection failed (spam)'; }
  my $sth = $dbh->prepare('SELECT host, portname, cp, chg_who FROM porttable');
  $r = $sth->execute();
  if(!$r) {
    return 'Database query failed (spam, ' . $sth->errstr() . ')';
  } 
  while(my $ra = $sth->fetchrow_arrayref()) {
    my $site = substr($ra->[0], 0, 3);
    $port2cp{$ra->[0]}{$ra->[1]} = $site . '!' . $ra->[2];
  }
  return ('', \%port2cp);
}


#===========================================================================
# GENERALIZED, fix description
# Find possible sites managed by SPAM for "Add" and "Delete" form. We do
# this by doing "SELECT DISTINCT site" on OUT2CP table.
#
# Arugment: 1. which table to query
# Returns:  1. array reference to sites list or error string
#===========================================================================

sub sql_sites
{
  my $table = lc($_[0]);
  if(exists $sites_cache{$table}) { return $sites_cache{$table}; }
  my $dbh = dbconn('spam');
  my $q = "SELECT DISTINCT site FROM $table ORDER BY site ASC";
  my @result;
  
  if(!ref($dbh)) { return 'Cannot connect to database'; }
  my $sth = $dbh->prepare($q);
  my $r = $sth->execute();
  if(!$r) {
    return 'Database query failed (spam, ' . $sth->errstr() . ')';
  }
  while(my $x = $sth->fetchrow_arrayref()) {
    push(@result, $x->[0]);
  }
  
  ### UGLY HACK ### FIXME ###
  push(@result, 'brr');
  push(@result, 'sto');
  @result = sort(@result);
  ###########################

  $sites_cache{$table} = \@result;
  return \@result;
}


#===========================================================================
# This function checks if given site uses two-level connection hierarchy
# (switch-cp-outlet) or single-level hierarchy (switch-outlet).
#===========================================================================

sub sql_site_uses_cp
{
  my $site = lc($_[0]);
  my $dbh = dbconn('spam');
  my $query = qq{SELECT site FROM out2cp GROUP BY site HAVING site = ?};

  if(!ref($dbh) || !$site) { return undef; }
  my $sth = $dbh->prepare($query);
  return int($sth->execute($site));
}


#=============================================================================
# Function to push values into multiple arrays with single function call.
# The arrays are supplied to this function as list of arrayrefs and function
# that will push values to all the arrays at once is returned. This exists
# to make preparing database quieries simpler and more readable (since this
# entails creating arrays of field names and values).
#=============================================================================

sub multipush
{
  my @arrays;
  
  for my $ary (@_) {
    push(@arrays, $ary);
  }
  
  return sub {
    for(my $i = 0; $i < scalar(@_); $i++) {
      push(@{$arrays[$i]}, $_[$i]);
    }
  };
}


#=============================================================================
# Helper function for line-reading files. The callback can abort reading the
# rest of the file by returning true. Returns error message or undef.
#=============================================================================

sub file_lineread
{
  my ($file, $open_mode, $fn) = @_;
  
  open(my $fh, $open_mode, $file) || return 'Failed to open file';
  while(my $l = <$fh>) {
    chomp($l);
    last if $fn->($l);
  }
  close($fh);
  return undef;
}


#=============================================================================
# Receives SQL query with ? placeholders and an array values and replaces
# the placeholders with the values and returns the result. This is used to
# pretty display the queries for debug purposes.
#=============================================================================

sub sql_show_query
{
  my ($qry, $vals) = @_;

  #---  handle $vals being single scalar or undefined

  if($vals && !ref($vals)) {
    $vals = [ $vals ];
  } elsif(!$vals) {
    $vals = [];
  }

  #--- squash extraneous whitespace, replace newlines

  $qry =~ s/\n/ /g;
  $qry =~ s/\s{2,}/ /g;

  #--- do the placeholders replacement

  for(my $i = 0; $i < scalar(@$vals); $i++) {
    my $val = $vals->[$i];
    if(defined $val) {
      $val = "'$val'" if $val !~ /^\d+$/;
    } else {
      $val = 'NULL';
    }
    $qry =~ s/\?/$val/;
  }

  #--- finish

  return $qry;
}


1;
