#!/usr/bin/perl -I../

#=============================================================================
# SWITCH PORTS ACTIVITY MONITOR -- BACKEND
# """"""""""""""""""""""""""""""""""""""""
# 2015 Borek Lupomesky <borek.lupomesky@vodafone.com>
#
# Backend script for client-side JavaScript.
#=============================================================================


#=== pragmas/modules =========================================================

use strict;
use integer;

use CGI;
use SPAMv2;
use JSON;



#=== data === ================================================================
# FIXME: Move this into a config file

my %views;
$views{swlist} = <<EOHD;
SELECT
  host, location, ports_total, ports_active, ports_patched,
  ports_illact, ports_errdis, ports_inact, vtp_domain, vtp_mode,
  extract('epoch' from current_timestamp - chg_when) > 2592000 AS stale
FROM swstat
ORDER BY host ASC
EOHD

$views{hwinfo} = 'SELECT n, partnum, sn FROM hwinfo WHERE host = ?';



#=== globals =================================================================

my $debug = 0;
my $js;
my %dbh;
my ($db_ondb, $db_spam);


#=============================================================================
# Entry routine; called once per instance (but not once per request, since
# one instance can handle multiple request)
#=============================================================================

BEGIN {
  $js = new JSON;
  binmode STDOUT, ":utf8";
  dbinit('spam', 'spam', 'swcgi', 'InvernessCorona', 'l5nets01.oskarmobil.cz');
  dbinit('ondb', 'ondb', 'swcgi', 'InvernessCorona', 'l5nets01.oskarmobil.cz');
  $dbh{'spam'} = $db_spam = dbconn('spam');
  $dbh{'ondb'} = $db_ondb = dbconn('ondb');
}



#=============================================================================
# Function to remove keys for a hash that have undefined values. This does not
# iterate over sub-hashes.
#=============================================================================

sub remove_undefs
{
  my $h = shift;
  
  for my $key (keys %$h) {
    if(!defined($h->{$key})) {
      delete $h->{$key}
    }
  }
}



#=============================================================================
# Evaluate user's access, this function does checks for overrides.
#
# Arguments: 1. access right name
#            2. user id
# Returns:   1. undef on success, error message otherwise
#            2. 0|1 -> fail|pass
#=============================================================================

sub user_access_evaluate
{
  my ($access, $user) = @_;
  my ($v);

  #--- sanitize arguments

  if(!$access) { return 'Required argument missing'; }
  $user = $ENV{REMOTE_USER} if !$user;
  $user = lc($user);
  $access = lc($access);

  #--- query

  my $sth = $db_ondb->prepare(qq{SELECT authorize_user(?,'spam',?)::int});
  my $r = $sth->execute($user, $access);
  if(!$r) {
    return sprintf('Database query failed (ondb, %s)', $sth->errstr());
  }
  ($v) = $sth->fetchrow_array();
  return (undef, $v);
}



#=============================================================================
# Run SELECT and encode the output into JSON or return hashref.
#=============================================================================

sub sql_select
{
  #--- arguments
  
  my (
    $dbid,      # 1. database id
    $query,     # 2. SQL query
    $args,      # 3. list of args (arrayref or scalar)
    $func,      # 4. function called for each row (optional)
    $norend,    # 5. don't output JSON but pass data structure (optional)
    $aref       # 6. return arrayref instead of hashref
  ) = @_;
  
  if($args && !ref($args)) {
    $args = [ $args ];
  }

  #--- other init
  
  my $dbh = $dbh{$dbid};
  my %re;

  #--- some debugging info
  
  if($debug) { 
    $re{'debug'} = 1; 
    $re{'query'} = sprintf(
      '%s (%s)', 
      $query, 
      join(',', map { "'$_'" } @$args)
    );
  }

  eval { #>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
  
  #--- ensure database connection
  
    if(!ref($dbh)) {
      $re{'dberr'} = 'Not connected';
      die;
    }
  
  #--- read data from db
	
    my $sth = $dbh->prepare($query);
    my $r = $sth->execute(@$args);
    if(!$r) {
      $re{'dberr'} = $sth->errstr();
      die;
    }
    $re{'fields'} = $sth->{NAME};
    $re{'result'} = $sth->fetchall_arrayref($aref ? () : {});
    $re{'status'} = 'ok';
  
  }; #<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

  #--- failure
  
  if($@) {
    $re{'status'} = 'error';
    $re{'errmsg'} = 'Database error';
  }  
  
  #--- optional post-processing
  
  if($func) {
    for my $row (@{$re{'result'}}) {
      &$func($row);
    }
  }

  #--- finish
  
  return \%re if $norend;
  print $js->encode(\%re);
}


#=============================================================================
# This function takes flag field returned from db and turns it into a hashref
#=============================================================================

sub port_flag_unpack
{
  my $flags = shift;
  my %re;
  
  #--- preserve original packed form
  $re{'flags_raw'} = $flags;

  #--- CDP (Cisco Discovery Protocol)
  $re{'cdp'} = 1 if $flags & 1;               # receiving CDP

  #--- Spanning Tree Protocol
  $re{'stp_pfast'} = 1 if $flags & 2;         # STP fast start mode
  $re{'stp_root'} = 1 if $flags & 4;          # STP root port

  #--- trunking
  $re{'tr_dot1q'} = 1 if $flags & 8;          # 802.1q trunk
  $re{'tr_isl'}   = 1 if $flags & 16;         # ISL trunk
  $re{'tr_unk'}   = 1 if $flags & 32;         # unknown trunk
  $re{'tr_any'}   = 1 if $flags & (8+16+32);  # trunk (any mode)

  #--- Power Over Ethernet
  # poe and poe_enable are strange, needs checking
  #$re{'poe'}          = 1 if $flags &  4096;  # PoE
  #$re{'poe_enabled'}  = 1 if $flags &  8192;  # PoE is enabled
  $re{'poe_power'}    = 1 if $flags & 16384;  # PoE is supplying power

  #--- 802.1x (port-level authentication)
  $re{'dot1x_fauth'}  = 1 if $flags & 64;     # force-authorized
  $re{'dot1x_fuauth'} = 1 if $flags & 128;    # force-unauthorized
  $re{'dot1x_auto'}   = 1 if $flags & 256;    # auto (not yet authorized)
  $re{'dot1x_authok'} = 1 if $flags & 512;    # auto, authorized
  $re{'dot1x_unauth'} = 1 if $flags & 1024;   # auto, unauthorized
  $re{'mab_success'}  = 1 if $flags & 2048;   # MAB active
  
  #--- finish
  
  return \%re;
}



#=============================================================================
# Transformation from formatted SNMP location string to user readable
# location. This function require complete row from swstat table.
#=============================================================================

sub mangle_location
{
  #--- arguments
  
  my $row = shift;           # 1. row from swstat table (hashref)
  
  #--- other variables
  
  my @l = split(/;/, $row->{'location'});
  my ($shop, $site, $descr);
  
  #--- field 0: should be 5-letter site code
  
  $site = $l[0] if $l[0];
  $site =~ s/^(\S{5}).*$/\1/;
  
  #--- field 3: "shop Sxx"
  
  $l[3] =~ /^Shop [ST](\d{2}|xx)/ && do {
    $shop = 1;
    $descr = sprintf('S%s %s, %s', $1, $l[4], $l[5]);
  };
  
  #--- if not shop, but in proper format
  
  if($l[3]) {
    $descr = sprintf('%s, %s, %s', @l[3..5]);
  }

  #--- if not shop, copy 'location' to 'descr'
  
  elsif(!exists $row->{'descr'}) {
    $descr = $row->{'location'};
  }
  
  #--- finish
  
  return (
    $descr,        # 1. description derived from location
    $site,         # 2. 5-letter site code
    $shop          # 3. shop flag 
  );
}



#=============================================================================
#=============================================================================

sub mangle_swlist
{
  my $row = shift;
  my @l = split(/;/, $row->{'location'});
  my $shop;

  #--- remove undefined values
  
  remove_undefs($row);
  
  #--- mangle location  

  ($row->{'descr'}, $row->{'site'}, $shop) = mangle_location($row);
  
  #--- switch groups (for distributing the switches among tabs for better
  #--- user access)
  
  my $code = substr($row->{'host'}, 0, 3);
  $row->{'group'} = 'oth';
  if(
    $code eq 'str' || $code eq 'rcn' || $code eq 'chr' || $code eq 'brr'
    || $code eq 'bsc' || $code eq 'sto'
  ) {
    $row->{'group'} = $code;
  }
  if($code eq 'ric') {
    $row->{'group'} = 'rcn';
  } 
  if($shop) {
    $row->{'group'} = 'sho';
  }
  
}



#=============================================================================
# Search the database, function that does the heavy lifting for the Search
# Tool.
#=============================================================================

sub sql_search
{
  #--- arguments
  
  my $par = shift;    # hashref containing search values
  
  #--- other variables
  
  my (
    %re,              # result, this is returned to the client
    @cond,            # SQL query conditions
    @args,            # SQL query arguments
    $view,            # SQL view
    $vss              # VSS flag (true if VSS switch is being queried)
  );

  #--- save search parameters

  $re{'params'} = $par;
      
  #--- function to do some mangling of data
  
  my $plist = sub {
    my $row = shift;
    remove_undefs($row);
    $row->{'flags'} = port_flag_unpack($row->{'flags'});
  };

  #--- get hwinfo an swinfo in case the only parameter is "host"
  
  # this allows us to display module headings for modular switches,
  # which in turn allows use of this function for switch portlist.

  if(
    $par->{'host'} 
    && !$par->{'outcp'}
    && !$par->{'portname'}
    && !$par->{'mac'}
    && !$par->{'ip'}
  ) {
  
  #--- hwinfo (list of linecards)
  
    $re{'hwinfo'} = sql_select(
      'spam', $views{'hwinfo'}, $par->{'host'}, undef, 1
    );
    if(
      $re{'hwinfo'}{'status'} ne 'ok'
      || !scalar($re{'hwinfo'}{'result'})
    ) { 
      delete $re{'hwinfo'};
    }
        
  #--- swstat (information about platform)
  
    $re{'swinfo'} = sql_select(
      'spam', 'SELECT * FROM v_swinfo WHERE host = ?',
      $par->{'host'}, undef, 1
    );
    if($re{'swinfo'}{'status'} ne 'ok') {
      delete $re{'swinfo'};
      delete $re{'hwinfo'} if exists($re{'hwinfo'});
    } else {
      $re{'swinfo'}{'result'} = $re{'swinfo'}{'result'}[0];
      $re{'swinfo'}{'result'}{'platform'} =~ /vss$/ && do {
        $re{'swinfo'}{'result'}{'vss'} = $vss = 1;
      };
      ($re{'swinfo'}{'result'}{'descr'}) = mangle_location($re{'swinfo'}{'result'});

    }
  }
  
  #--- decide what view to use

  if($par->{'host'} || $par->{'portname'}) {
    $view = $re{'hwinfo'} ? 'v_search_status_mod' : 'v_search_status';
  }
  elsif($par->{'outcp'}) {
    $view = 'v_search_outlet';
  }
  elsif($par->{'mac'} || $par->{'ip'}) {
    $view = 'v_search_mac';
  } 
  else {
    $view = 'v_search_status';
  }
  
  #--- conditions
  
  for my $k (qw(site outcp host portname mac ip)) {
    if(exists $par->{$k} && $par->{$k}) {
      if($k eq 'outcp') {
        push(@cond, '(cp = ? OR outlet = ?)');
        push(@args, $par->{'outcp'});
        push(@args, $par->{'outcp'});
      } elsif($k eq 'ip' || $k eq 'mac') {
        push(@cond, sprintf('%s::text ~ ?', $k));
        push(@args, $par->{$k});
      } else {
        push(@cond, sprintf('%s = ?', $k));
        push(@args, $par->{$k});
      }
    }
  } 
  my $where = '';
  $where = ' WHERE ' . join(' AND ', @cond) if scalar(@cond);

  #--- ordering
  
  # only for IP searches; other views have their implicit sorting orders
  
  my $orderby = '';
  $orderby = ' ORDER BY ip' if $par->{'ip'};
      
  #---------------------------------------------------------------------------
  
  eval {
  
    $re{'search'} = sql_select(
      'spam', "SELECT * FROM $view" . $where . $orderby, \@args, $plist, 1
    );
    if($re{'search'}{'status'} ne 'ok') {
      die "$view query failed";
    }
    $re{'search'}{'lines'} = scalar(@{$re{'search'}{'result'}});
  
  };

  #---------------------------------------------------------------------------

  if($@) {
    $re{'status'} = 'error';
    $re{'errmsg'} = $@;
    $re{'errfunc'} = sprintf('sql_search()');
  } else {
    $re{'status'} = 'ok';
    $re{'errmsg'} = 'no error';
  }

  #--- compose hwinfo with search result
  
  # The search result need to be interleaved with module info for modular
  # switches; but only when user is searching by switch name
  
  if($re{'hwinfo'} && scalar(@{$re{'hwinfo'}{'result'}})) {
    my $n_last = '';
    for my $row (@{$re{'search'}{'result'}}) {

  # parse portname and get the linecard number; note
  # that on VSS switches line-card number is in form of
  # sw#/linecard#

      $row->{'portname'} =~ /^[a-z]+(\d+|\d+\/\d+)\/(\d+)$/i;
      my $n_curr = $1;
      if($n_curr ne $n_last) {
  
        # for VSS switches, reading of present line-cards
        # is not working with the standard MIB
  
        if($vss) {
          push(@{$re{'search'}{'result2'}}, { 'n' => $n_curr });
        } else {
          my ($hwentry) = grep {
            $_->{'n'} eq $n_curr;
          } @{$re{'hwinfo'}{'result'}};
          if(ref($hwentry)) {
            push(@{$re{'search'}{'result2'}}, $hwentry);
          } else {
            push(@{$re{'search'}{'result2'}}, { 'n' => $n_curr });
          }
        }
        $n_last = $n_curr;
      }
      push(@{$re{'search'}{'result2'}}, $row);
    }

    $re{'search'}{'result'} = $re{'search'}{'result2'};
    delete $re{'search'}{'result2'};
  }
  
    
  #--- finish
  
  print $js->encode(\%re);
}



#=============================================================================
#=============================================================================

sub sql_aux_data
{
  my %re;

  #--- list of sites
    
  $re{'sites'} = sql_select(
    'ondb',
    'SELECT code, description FROM site ORDER BY code',
    undef,
    undef,
    1,
    1
  );
  
  print $js->encode(\%re);
}



#=============================================================================
#=== MAIN ====================================================================
#=============================================================================


#--- process arguments

my %args;
my $q = new CGI;
my $req = $q->param('r');  # request type

# below code allows the arguments to be specified on command line for
# debugging purposes as "par1=val1 par2=val2 ... "

if(!$req && $ARGV[0]) {
  $debug = 1;
  $js->pretty(1);
  $req = $ARGV[0];
  for my $arg (@ARGV[1 .. scalar(@ARGV)-1]) {
    my @x = split(/=/, $arg);
    $args{$x[0]} = $x[1];
  }
}

#--- preamble

print "Content-type: application/json; charset=utf-8\n\n";

#--- verify database availability

{
  my %re;
  my @db_unavailable = grep { !ref($dbh{$_}) } keys %dbh;

  if(scalar(@db_unavailable)) {
    $re{'userid'} = $ENV{'REMOTE_USER'};
    $re{'status'} = 'error';
    $re{'errmsg'} = 'Database connection failed';
    $re{'errwhy'} = 'Unavailable db: ' . join(', ', @db_unavailable);
    print $js->encode(\%re), "\n";
    exit;
  }
}

#--- debugging mode

my $e;
($e, $debug) = user_access_evaluate('debug');
if($debug) {
  $js->pretty(1);
}
$debug = 1;

#-----------------------------------------------------------------------------
#--- central dispatch --------------------------------------------------------
#-----------------------------------------------------------------------------

#--- switch list

if($req eq 'swlist') {
  sql_select('spam', 'SELECT * FROM v_swinfo', [], \&mangle_swlist);
}

#--- port list

if($req eq 'switch') {
  my $host = $q->param('host') // $args{'host'};
  sql_port_list($host);
}

#--- search tool

if($req eq 'search') {
  my %par;
  for my $k (qw(site outcp host portname mac ip sortby)) {
    $par{$k} = $q->param($k) // $args{$k};
  }
  remove_undefs(\%par);  
  sql_search(\%par);
}

#--- auxiliary data

if($req eq 'aux') {
  sql_aux_data();
}

#--- default

if(!$req) {
  my %re;

  $re{'userid'} = $ENV{'REMOTE_USER'};
  $re{'status'} = 'ok';
  print $js->encode(\%re), "\n";
}
