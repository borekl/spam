#!/usr/bin/perl

#=============================================================================
# SWITCH PORTS ACTIVITY MONITOR -- BACKEND
# """"""""""""""""""""""""""""""""""""""""
# 2015-2017 Borek Lupomesky <borek.lupomesky@vodafone.com>
#
# Backend script for client-side JavaScript.
#=============================================================================



#=== pragmas =================================================================

use strict;
use warnings;
use integer;
use utf8;
use charnames ':full';
use lib '../', '../lib';


#=== modules =================================================================

use Cwd qw(abs_path);
use CGI;
use SPAMv2;
use JSON::MaybeXS;
use Data::Dumper;
use Try::Tiny;
use ONdb::Authorize;
use SPAM::Config;
use SPAM::Entity;
use SPAM::EntityTree;


#=== globals =================================================================

my $debug = JSON->false;    # debugging flag, is set acc. to user's ondb entry
my $cfg;                    # configuration from spam.cfg
my $cfg2;
my $js;
my %dbh;
my ($db_ondb, $db_spam);



#=============================================================================
# Entry routine; called once per instance (but not once per request, since
# one instance can handle multiple request)
#=============================================================================

BEGIN
{
  #--- read config

  # we're assuming the path of the script is in form
  # "/<prefix>/{prod,dev}/<suffix>/<script>" and that the 'spam.cfg' is in
  # "/<prefix>/{prod,dev}" directory.

  my $cfg_file = sprintf(abs_path($0));
  $cfg_file =~ s/^(\/.+\/(?:prod|dev))\/.*$/$1/;
  $cfg_file = sprintf('%s/spam.cfg.json', $cfg_file);
  $cfg2 = SPAM::Config->instance(config_file => $cfg_file);
  $cfg = load_config();

  #--- misc init

  $js = new JSON::MaybeXS;
  binmode STDOUT, ":utf8";

  #--- database init

  $dbh{'spam'} = $db_spam = $cfg2->get_dbi_handle('spamui');
  $dbh{'ondb'} = $db_ondb = $cfg2->get_dbi_handle('ondbui');
}



#=============================================================================
# Function to remove keys for a hash that have undefined values. This does not
# iterate over sub-hashes.
#=============================================================================

sub remove_undefs
{
  my ($h) = @_;

  while(my ($key, $value) = each %$h) {
    delete $h->{$key} if !defined($value);
  }
}



#=============================================================================
# Return JSON boolean value of an argument.
#=============================================================================

sub js_bool
{
  return $_[0] ? JSON->true : JSON->false;
}



#=============================================================================
# Parse PostgreSQL error messages, returning them in structured form,
# explanation by an example:
#
# "errdb" : {
#
#   //--- extracted error message
#   "error" : "duplicate key value violates unique constraint \"porttable_pkey\"",
#
#   //--- extracted detail message
#   "detail" : "Key (host, portname)=(stos76, Fa0/10) already exists.",
#
#   //--- the whole message from db parsed into lines
#   "lines" : [
#     "ERROR:  duplicate key value violates unique constraint \"porttable_pkey\"",
#     "DETAIL:  Key (host, portname)=(stos76, Fa0/10) already exists."
#   ],
#
#   //--- constraint name
#   "constraint" : "porttable_pkey",
#
#   //--- short-word type of the error/conflict
#   "type" : "dupkey",
#
#   //--- (for type=dupkey) this contains field=value pairs of the constraint
#   //--- that are in conflict
#   "conflict" : {
#     "portname" : "Fa0/10",
#     "host" : "stos76"
#   }
# }
#=============================================================================

sub pg_errmsg_parse
{
  #--- arguments

  my $errmsg = shift;    # error message from DBI errstr() method

  #--- other variables

  my @err_lines;         # error message split into individual lines
  my %re;                # returned hash

  #--- split error message into array of sing lines

  @err_lines = split(/\n/, $errmsg);

  #--- ERROR and DETAIL messages

  ($re{'error'}) = grep(/^ERROR:\s/, @err_lines);
  $re{'error'} =~ s/^ERROR:\s+//;
  ($re{'detail'}) = grep(/^DETAIL:\s/, @err_lines);
  $re{'detail'} =~ s/^DETAIL:\s+//;

  #--- ERROR: duplicate key value

  $re{'error'} =~ /^duplicate key value .* constraint "(\w+)"/ && do {
    $re{'type'} = 'dupkey';
    $re{'constraint'} = $1;

    $re{'detail'} =~ /^Key \((.+)\)=\((.+)\) already exists\.$/;
    my ($fields, $values) = ($1, $2);
    my @fields = split(/,\s/, $fields);
    my @values = split(/,\s/, $values);
    @{$re{'conflict'}}{@fields} = @values if @fields;
  };

  #--- ERROR: not-null constraint violation

  $re{'error'} =~ /^null value in column "(\w+)"/ && do {
    $re{'type'} = 'nullval';
    $re{'field'} = $1;
  };

  #--- finish

  $re{'lines'} = \@err_lines;
  return \%re;
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
    $aref       # 5. return arrayref instead of hashref
  ) = @_;

  if($args && !ref($args)) {
    $args = [ $args ];
  }

  #--- other init

  my $dbh = $dbh{$dbid};
  my %re;

  #--- some debugging info

  $re{'debug'} = $debug;
  if($debug) {
    $re{'query'} = sql_show_query($query, @$args);
  }

  try { #>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

  #--- ensure database connection

    if(!ref($dbh)) {
      $re{'errdb'} = { 'type' => 'Not connected' };
      die;
    }

  #--- read data from db

    my $sth = $dbh->prepare($query);
    my $r = $sth->execute(@$args);
    if(!$r) {
      $re{'errdb'} = pg_errmsg_parse($sth->errstr());
      die;
    }
    $re{'fields'} = $sth->{NAME};
    $re{'result'} = $sth->fetchall_arrayref($aref ? () : {});
    $re{'status'} = 'ok';

  } #<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

  #--- failure

  catch {
    $re{'status'} = 'error';
    $re{'errmsg'} = 'Database error';
  };

  #--- optional post-processing

  if($func) {
    for my $row (@{$re{'result'}}) {
      &$func($row);
    }
  }

  #--- finish

  return \%re;
}


#=============================================================================
# This function takes flag field returned from db and turns it into a hashref
#=============================================================================

sub port_flag_unpack
{
  my $flags = shift;
  my %re;

  #--- map keywords to bitmap

  my %flag_map = (
    'cdp'          => 1,          # receiving CDP
    'stp_pfast'    => 2,          # STP fast start mode
    'stp_root'     => 4,          # STP root port
    'tr_dot1q'     => 8,          # 802.1q trunk
    'tr_isl'       => 16,         # ISL trunk
    'tr_unk'       => 32,         # unknown trunk
    'tr_any'       => 8+16+32,    # trunk (any mode)
    #'poe'          => 4096,       # PoE
    #'poe_enabled'  => 8192,       # PoE is enabled
    'poe_power'    => 16384,      # PoE is supplying power
    'dot1x_fauth'  => 64,         # force-authorized
    'dot1x_fuauth' => 128,        # force-unauthorized
    'dot1x_auto'   => 256,        # auto (not yet authorized)
    'dot1x_authok' => 512,        # auto, authorized
    'dot1x_unauth' => 1024,       # auto, unauthorized
    'mab_success'  => 2048        # MAB active
  );

  #--- create flags hash

  for my $k (keys %flag_map) {
    $re{$k} = 1 if $flags & $flag_map{$k};
  }

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
  return undef if !ref($row) || !$row->{'location'};

  #--- other variables

  my @l = split(/;/, $row->{'location'});
  my ($shop, $site, $descr);

  #--- field 0: should be 5-letter site code

  $site = $l[0] if $l[0];
  $site =~ s/^(\S{5}).*$/$1/;

  #--- field 3: "shop Sxx"

  $l[3] && $l[3] =~ /^Shop [ST](\d{2}|xx)/ && do {
    $shop = 1;
    $descr = sprintf('S%s %s, %s', $1, $l[4], $l[5]);
  };

  #--- if not shop, but in proper format

  if($l[3]) {
    $descr = join(
      ', ',
      grep { $_ ne 'x' } @l[3..$#l]
    );
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
  my @l = split(/;/, $row->{'location'} // '');
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
# Normalizing outlet/cp representation
#=============================================================================

sub normalize_outcp
{
  my $outcp = shift;

  # convert to upper-case
  $outcp = uc($outcp);

  # "N/N/N" -> "N.N.N"
  $outcp =~ s/(\d+)\/(\d+)\/(\d+)/$1.$2.$3/;

  # "-N A"
  $outcp =~ s/^(.*\d)\s*([A-Z])$/$1 $2/;

  # "A N-"
  $outcp =~ s/^([A-Z]+)\s*(\d.*)$/$1 $2/;

  return $outcp;
}



#=============================================================================
# Code for accepting multiple MAC address formats.
#=============================================================================

sub normalize_mac
{
  my $mac = shift;
  my @mac;

  #--- convert to lower-case

  $mac = lc($mac);

  #--- remove anything but hex digits and * wildcards

  $mac =~ s/[^*[:xdigit:]]//g;

  #--- consequent * to one

  $mac =~ s/\*{2,}/*/g;

  #--- parse the mac

  while(length($mac) && scalar(@mac) < 6) {
    if($mac =~ /^[[:xdigit:]]{2}/) {
      push(@mac, substr($mac,0,2));
      $mac = substr($mac, 2);
    } elsif($mac =~ /^\*/) {
      push(@mac, '*');
      $mac = substr($mac, 1);
    } elsif(length($mac) == 1) {
      last;
    };
  }

  #--- if there's less than 6 octets, fill-in * wildcard,
  #--- unless one is already there

  if(scalar(@mac) < 6) {
    if(!grep { /\*/ } @mac) {
      push(@mac, '*');
    }
  }

  #--- finish

  return join(':', @mac);
}



#=============================================================================
# Perform normalization of what user enteres in Search Tool form. This
# normalization can be suppressed by entering ' (U+0027 APOSTROPHE) or
# = (U+003D EQUALS SIGN) as the first character of the value.
#=============================================================================

sub normalize_search
{
  #--- variables

  my $parm_in = shift;
  my %parm_out;

  #--- iterate over all parameters

  for my $k (keys %$parm_in) {
    my $val = $parm_in->{$k};

    # leading apostrophe or equals sign suppresses the normalization;
    # lone apostrophe or equals sign are still considered normal text
    if($val =~ /^['=]./) {
      $parm_out{$k} = $val;
      next;
    }

    # trim leading/trailing whitespace
    $val =~ s/^\s+|\s+$//g;

    # normalize outlet name
    $val = normalize_outcp($val) if $k eq 'outcp';

    # normalize mac address
    $val = normalize_mac($val) if $k eq 'mac';

    # normalize portname
    if($k eq 'portname') {
      $val =~ s/\s//g;
      $val = lc($val);
      $val = ucfirst($val);
    }

    # normalize switch name
    if($k eq 'host') {
      $val =~ s/\W//g;
      $val = lc($val);
    }

    # normalize IPv4 address
    $val =~ s/[^0-9*\/.]//g if $k eq 'ip';

    $parm_out{$k} = $val;
  }

  #--- finish

  return \%parm_out;
}



#=============================================================================
# Gets hwinfo from database and stores it under 'hwlist' key in supplied
# hashref.
#=============================================================================

sub sql_get_hwinfo
{
  #--- arguments

  my (
    $re,           # 1. hashref where the result is stored
    $host          # 2. switch hostname
  ) = @_;

  #--- read modwire information from database

  my $modwire_re = sql_select(
    'spam',
    "SELECT m, n, location FROM modwire WHERE host = ?",
    $host
  );
  my $modwire = $modwire_re->{'status'} eq 'ok' ? $modwire_re->{'result'} : [];

  #--- read entity information from database

  my $local_re = sql_select(
    'spam',
    "SELECT * FROM snmp_entPhysicalTable s
     LEFT JOIN snmp_entAliasMappingTable USING ( host, entPhysicalIndex )
     WHERE s.host = ?",
     $host
  );
  if($local_re->{'status'} eq 'ok') {
    my @entities;
    foreach my $row (@{$local_re->{'result'}}) {
      push(@entities,
        SPAM::Entity->new(
          entPhysicalIndex => $row->{entphysicalindex},
          entPhysicalDescr => $row->{entphysicaldescr},
          entPhysicalContainedIn => $row->{entphysicalcontainedin},
          entPhysicalClass => $row->{entphysicalclass},
          entPhysicalParentRelPos => $row->{entphysicalparentrelpos},
          entPhysicalName => $row->{entphysicalname},
          entPhysicalHardwareRev => $row->{entphysicalhardwarerev},
          entPhysicalFirmwareRev => $row->{entphysicalfirmwarerev},
          entPhysicalSoftwareRev => $row->{entphysicalsoftwarerev},
          entPhysicalSerialNum => $row->{entphysicalserialnum},
          entPhysicalModelName => $row->{entphysicalmodelname},
          ifIndex => $row->{entaliasmappingidentifier},
        )
      );
    }
    my $tree = SPAM::EntityTree->new(entities => \@entities);

    $re->{'hwinfo'}{'result'} = $tree->hwinfo($modwire);
  }

  return $local_re;

}



#=============================================================================
# Gets swstat entry from database and stores it under 'swinfo' key in supplied
# hashref.
#=============================================================================

sub sql_get_swinfo
{
  #--- arguments

  my (
    $re,           # 1. hashref where the result is stored
    $host          # 2. switch hostname
  ) = @_;

  #--- do the query

  my $local_re = sql_select(
    'spam', 'SELECT * FROM v_swinfo WHERE host = ?',
    $host
  );
  if($local_re->{'status'} eq 'ok') {
    $local_re->{'result'} = $local_re->{'result'}[0];

    # VSS flag
    if(
      $local_re->{'result'}{'platform'} =~ /(vss|VirtualSwitch)$/
    ) {
      $local_re->{'result'}{'vss'} = 1;
    }

    $local_re->{'result'}{'platform'} =~ /vss$/ && do {
      $local_re->{'result'}{'vss'} = 1;
    };
    ($local_re->{'result'}{'descr'}) = mangle_location($local_re->{'result'});
  }
  $re->{'swinfo'} = $local_re;
}



#=============================================================================
# Function that gets search result and produces new search result with
# switch linecard info interleaved within for the benefit of the front-end
# template.
#=============================================================================

sub search_hwinfo_interleave
{
  #--- arguments

  my $re = shift;

  #--- other variables

  my @new;    # the new search result we're creating here
  my $vss;    # the switch is Cisco VSS

  $vss = $re->{'swinfo'}{'result'}{'vss'} // 0;

  #--- iterate over the search output and create a new one

  my $n_last = '';
  for my $row (@{$re->{'search'}{'result'}}) {

  #--- parse portname and get the linecard number; note
  #--- that on VSS switches line-card number is in form of
  #--- sw#/linecard#

    $row->{'portname'} =~ /^[a-z]+(\d+|\d+\/\d+)\/(\d+)$/i;
    my $n_curr = $1;

  #--- if the last line-card id is different from the current
  #--- it means we're in the place of the list where we want
  #--- to enter the line-card info

    if($n_curr ne $n_last) {

  #--- for VSS switches, reading of present line-cards
  #--- is not working with the standard MIB (FIXME);
  #--- therefore we merely push the line-card designation without
  #--- any additional information

      if($vss) {
        $n_curr =~ /^(\d+)\/(\d+)$/;
        my ($chassis, $module) = ($1, $2);
        my ($hwentry) = grep {
          exists $_->{'n'}
          && $_->{'n'} eq $module
          && $_->{'m'} eq $chassis
        } @{$re->{'hwinfo'}{'result'}};
        if(ref($hwentry)) { # found a hwentry
          push(@new, $hwentry);
        } else { # found no hwentry
          push(@new, { 'n' => $chassis, 'm' => $module});
        }
      }

  #--- for non-VSS switch we try to find the associated line-card
  #--- info stored in 'hwinfo' key; if we find it, we push the
  #--- hwinfo entry, otherwise just the line-card designation

      else {
        my ($hwentry) = grep {
          $_->{'type'} eq 'linecard'
          && $_->{'n'} == $n_curr;
        } @{$re->{'hwinfo'}{'result'}};
        if(ref($hwentry)) { # found a hwentry
          push(@new, $hwentry);
        } else { # found no hwentry
          push(@new, { 'n' => int($n_curr)});
        }
      }

  #--- end of current line-card boundary processing

      $n_last = $n_curr;

    }

  #--- regular row push (merely copies the source)

    push(@new, $row);

  }

  #--- replace the old search result with the new

  $re->{'search'}{'result'} = \@new;

}



#=============================================================================
# Function to determine searching for switch portname from user input.
# It pushes SQL conditionals and their values into two fields used to build
# the WHERE statement.
#
# Supported searches:
# - exact match ("Gi1/1", "Eth113/1/20")
# - match ignoring iftype ("1/1", "113/1/20")
#=============================================================================

sub search_portname
{
  #--- arguments

  my $cond = shift;      # 1. SQL WHERE condition element arrayref
  my $args = shift;      # 2. SQL WHERE placeholder value arrayref
  my $portname = shift;  # 3. field value

  #--- portname without interface type (tail-anchored match)

  if(
    $portname =~ /^\d+\/\d+$/ ||
    $portname =~ /^\d+\/\d+\/\d+$/
  ) {
    $portname = sprintf('[^\d/]%s$', $portname);
    push(@$cond, 'portname ~ ?');
  }

  #--- portname with interface type (exact match)

  else {
    push(@$cond, 'portname = ?');
  }

  #--- finish

  push(@$args, $portname);
}



#=============================================================================
# Function to determine how we match IPv4 addresses.
#
# Supported searches:
# - CIDR format ("1.2.3.4/24")
# - wildcard format ("1.2.3.*")
# - exact match ("1.2.3.0")
#
# Note that we're not ensuring correct syntax here; we're just selecting the
# way the matching is done.
#=============================================================================

sub search_ip
{
  #--- arguments

  my (
    $cond,      # 1. SQL WHERE condition element arrayref
    $args,      # 2. SQL WHERE placeholder value arrayref
    $ip         # 3. field value
  ) = @_;

  #--- CIDR format

  if($ip =~ /^[0-9.]+\/\d{1,2}$/) {
    push(@$cond, 'ip << ?');
  }

  #--- wildcard format

  elsif(
    $ip =~ /^[0-9.*]+$/
    && $ip =~ /\*/
  ) {
    $ip =~ s/\*/.*/g;
    push(@$cond, 'ip::text ~ ?');
  }

  #--- default (exact match)

  else {
    push(@$cond, 'ip = ?');
  }

  #--- finish

  push(@$args, $ip);
}



#=============================================================================
# Function to determine how we match MAC
#
# Supported searches:
# - wildcard match ("00:21:ab:*")
# - exact match ("00:21:ab:34:3a:4f")
#=============================================================================

sub search_mac
{
  #--- arguments

  my $cond = shift;      # 1. SQL WHERE condition element arrayref
  my $args = shift;      # 2. SQL WHERE placeholder value arrayref
  my $mac = shift;       # 3. field value

  #--- wildcard match

  if($mac =~ /\*/) {
    if($mac =~ /^[^*]/) {
      $mac = '^' . $mac;
    }
    if($mac =~ /[^*]$/) {
      $mac = $mac . '$';
    }
    $mac =~ s/\*/.*/g;
    push(@$cond, 'mac::text ~ ?');
  }

  #--- exact match

  else {
    push(@$cond, 'mac = ?');
  }

  #--- finish

  push(@$args, $mac);
}



#=============================================================================
# Search for outlet/cp.
#
# Supported searches:
# - regexp case-insensitive search ("/^.*17 [AB]$")
# - exact search ("=2017 A")
# - substring case-insensitive search ("2017", "'2017 A")
#=============================================================================

sub search_outcp
{
  #--- arguments

  my $cond = shift;      # 1. SQL WHERE condition element arrayref
  my $args = shift;      # 2. SQL WHERE placeholder value arrayref
  my $outcp = shift;     # 3. field value

  #--- remove leading apostrophe, if it exists; it was relevant during
  #--- field normalization

  if($outcp =~ /^'(.+)/) {
    $outcp = $1;
  }

  #--- regexp search

  if($outcp =~ /^\/(.+)/) {
    $outcp = $1;
    push(@$cond, '( outlet ~* ? OR cp ~* ? )');
  }

  #--- exact search

  elsif($outcp =~ /^=(.+)/) {
    $outcp = $1;
    push(@$cond, '( outlet = ? OR cp = ? )');
  }

  #--- substring search
  # is there simpler way of doing substring search in PgSQL?

  else {
    push(
      @$cond,
      '( position(lower(?) in lower(outlet))::boolean OR ' .
      'position(lower(?) in lower(cp))::boolean )'
    );
  }

  #--- finish

  push(@$args, ($outcp) x 2);
}



#=============================================================================
# Search for common string
#
# Supported searches:
# - regexp case-insensitive search (leading /)
# - exact search (leading =)
# - substring case-insensitive search
#=============================================================================

sub search_common_string
{
  #--- arguments

  my $cond = shift;      # 1. SQL WHERE condition element arrayref
  my $args = shift;      # 2. SQL WHERE placeholder value arrayref
  my $value = shift;     # 3. field value
  my $field = shift;     # 4. field name

  #--- remove leading apostrophe, if it exists; it was relevant during
  #--- field normalization

  if($value =~ /^'(.+)/) {
    $value = $1;
  }

  #--- regexp search

  if($value =~ /^\/(.+)/) {
    $value = $1;
    push(@$cond, "$field ~* ?");
  }

  #--- exact search

  elsif($value =~ /^=(.+)/) {
    $value = $1;
    push(@$cond, "$field = ?");
  }

  #--- substring search
  # is there simpler way of doing substring search in PgSQL?

  else {
    push(@$cond, "position(lower(?) in lower($field))::boolean");
  }

  #--- finish

  push(@$args, $value);
}



#=============================================================================
# Search the database, function that does the heavy lifting for the Search
# Tool. The database queries all use views, so they are not defined here.
#
# Apart from parameters coming from user input, there's special key 'view'
# that allows implicitly selecting view; this is needed when sql_search()
# is used internally.
#
# Another special field is 'mode', that is used signal additional information
# from client to view-selection code. 'view' always takes precedence, though.
#
# Output:
# ------
# params -> raw        ... parameters as we got them from the front-end
# params -> normalized ... parameters passed through server-side normalization
# hwinfo               ... sql_get_hwinfo() output, list of known hw entities
# swinfo               ... sql_get_swinfo() output, statistics about switch
# search               ... result of the actual search (whole subtree)
# search -> lines      ... number of result entries
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

  $re{'params'}{'raw'} = $par;

  #--- normalize search parameters

  if(
    !exists $par->{'mode'}
    || $par->{'mode'} ne 'portlist'
    && $par->{'mode'} ne 'portinfo'
  ) {
    $re{'params'}{'normalized'} = $par = normalize_search($par);
  }

  #--- parameter suppression function

  # this will be used to suppress certain parameters that are incompatible
  # with selected database view

  my $param_suppress = sub {
    for my $sup (@_) {
      if(exists $par->{$sup}) {
        $re{'params'}{'suppressed'}{$sup} = $par->{$sup};
        delete $par->{$sup};
      }
    }
  };

  #--- function to do some mangling of data

  my $plist = sub {
    my $row = shift;

    #--- remove undefined keys (why are we doing this?)

    remove_undefs($row);

    #--- unpack port flags into a hash for easy access in the front-end
    #--- if no flags are set, then make the key 'undef', because that's what
    #--- dust.js can easily test for with {?exists/} section.

    if($row->{'flags'}) {
      $row->{'flags'} = port_flag_unpack($row->{'flags'});
    } else {
      $row->{'flags'} = undef;
    }

    #--- "knownports" feature

    if(
      exists $row->{'host'} &&
      scalar(grep { $_ eq $row->{'host'} } @{$cfg->{'knownports'}}) &&
      $row->{'status'} != 0 &&
      !$row->{'cp'}
    ) {
      $row->{'unregistered'} = 1;
    }

    #--- convert "vlans" field into useful information

    # "vlans" field is a bitstring of 4096 bits that corresponds to vlans
    # 1-4096; 1s represent enabled vlans. For the front-end use, we convert
    # this into list of enabled vlans

    {
      my ($vlans_list, $vlans_ranges)
      = vlans_bitstring_to_range_list($row->{'vlans'} // '');
      $row->{'vlans_fmt'} = join(",\N{ZERO WIDTH SPACE}", @$vlans_ranges);
      $row->{'vlans_cnt'} = @$vlans_list;
      $row->{'vlans'};
    }

  };

  #--- get hwinfo and swinfo in case the only parameter is "host"

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

    sql_get_hwinfo(\%re, $par->{'host'});

  #--- swstat (information about platform)

    sql_get_swinfo(\%re, $par->{'host'});
    $vss = $re{'swinfo'}{'result'}{'vss'} // 0;
  }

  #--- modular switch?

  my $modular = 0;
  if(
    exists $re{'hwinfo'}
    && grep { $_->{'type'} eq 'linecard' } @{$re{'hwinfo'}{'result'}}
  ) {
    $modular = 1;
  }

  #--- decide what view to use

  if($par->{'view'}) {
    $view = $par->{'view'};
  }
  elsif(exists $par->{'mode'} && $par->{'mode'} eq 'portlist') {
    $view = $modular ? 'v_port_list_mod' : 'v_port_list';
  }
  elsif($par->{'host'} || $par->{'portname'}) {
    $view = $modular ? 'v_search_status_mod' : 'v_search_status';
  }
  elsif($par->{'outcp'}) {
    $view = 'v_search_outlet';
  }
  elsif($par->{'mac'} || $par->{'ip'}) {
    $view = 'v_search_mac';
  }
  elsif($par->{'username'}) {
    $view = 'v_search_user';
    $param_suppress->('mac', 'ip');
  }
  else {
    $view = 'v_search_status';
  }

  if($view ne 'v_search_user') {
    $param_suppress->('username');
  }

  #--- SQL WHERE conditions

  for my $k (qw(site outcp host portname mac ip username inact vlan vlans)) {
    if(exists $par->{$k} && $par->{$k}) {
      if($k eq 'outcp') {
        search_outcp(\@cond, \@args, $par->{$k});
      } elsif($k eq 'portname') {
        search_portname(\@cond, \@args, $par->{$k});
      } elsif($k eq 'ip') {
        search_ip(\@cond, \@args, $par->{$k});
      } elsif($k eq 'mac') {
        search_mac(\@cond, \@args, $par->{$k});
      } elsif($k eq 'username') {
        search_common_string(
          \@cond, \@args, $par->{$k}, 'cafsessionauthusername'
        );
      } elsif($k eq 'inact') {
        push(@cond, 'inact >= ?');
        push(@args, decode_age($par->{$k}));
      } elsif($k eq 'vlans') {
        push(@cond, '(flags & 8+16+32)::boolean', 'get_bit(vlans, ?)::boolean');
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

  try {

    $re{'search'} = sql_select(
      'spam', "SELECT * FROM $view" . $where . $orderby, \@args, $plist
    );
    if($re{'search'}{'status'} ne 'ok') {
      die "$view query failed";
    }
    $re{'search'}{'lines'} = scalar(@{$re{'search'}{'result'}});

    if(exists $par->{'mode'} && $par->{'mode'} eq 'portlist') {
      $re{'search'}{'result'} = query_reduce(
        $re{'search'}{'result'}, 'portname'
      );
    }

  }

  #---------------------------------------------------------------------------

  catch {
    $re{'status'} = 'error';
    $re{'errmsg'} = $_;
    $re{'errfunc'} = sprintf('sql_search()');
  } finally {
    if(!exists $re{'status'}) {
      $re{'status'} = 'ok';
      $re{'errmsg'} = 'no error';
    }
  };

  #--- compose hwinfo with search result

  # The search result need to be interleaved with module info for modular
  # switches; but only when user is searching by switch name; non-linecard
  # hw entities have n >= 1000, so the hwinfo/search composition is only done
  # for switches where we detected linecards

  if(
    $re{'hwinfo'}
    && grep { exists $_->{'n'} && $_->{'n'} < 1000 } @{$re{'hwinfo'}{'result'}}
  ) {
    search_hwinfo_interleave(\%re);
  }

  #--- finish

  return \%re;
}



#=============================================================================
# Function to supply data to the Port Info feature. It basically does standard
# sql_search(), but then does additional processing of the result before its
# returned to the client.
#=============================================================================

sub sql_portinfo
{
  #--- arguments

  my (
    $site,
    $host,
    $portname
  ) = @_;

  #--- other variables

  my $re;
  my %arg = (
    'site' => $site,
    'host' => $host,
    'portname' => $portname,
    'view' => 'v_portinfo',
    'mode' => 'portinfo',
  );

  #--- get data from db

  $re = sql_search(\%arg);
  if($re->{'status'} eq 'ok') {

  #--- do some reprocessing

  # point of this step is to collate multiple MAC and IP addresses and
  # put them into single row in the response

    my (@mac, @ip);
    my $idx = 0;

    for my $row (@{$re->{'search'}{'result'}}) {

      if($row->{'mac'}) {
        push(@mac, {
          'addr'    => $row->{'mac'},
          'age'     => $row->{'mac_age'},
          'age_fmt' => $row->{'mac_age_fmt'},
          'idx'     => $idx
        });
      }

      if($row->{'ip'}) {
        push(@ip, {
          'addr'    => $row->{'ip'},
          'age'     => $row->{'ip_age'},
          'age_fmt' => $row->{'ip_age_fmt'},
          'idx'     => $idx
        });
      }

      $idx++;
    }

  # get rid of the result rows

    $re->{'search'}{'result'} = $re->{'search'}{'result'}[0];

  # replace mac/ip keys with what we have collated

    $re->{'search'}{'result'}{'mac'} = \@mac;
    $re->{'search'}{'result'}{'ip'} = \@ip;
    for my $k (qw(mac_age mac_age_fmt ip_age ip_age_fmt)) {
      delete $re->{'search'}{'result'}{$k};
    }

  #--- CDP information

    $re->{'cdp'} = sql_select(
      'spam',
      'SELECT * FROM snmp_cdpcachetable WHERE host = ? AND cdpcacheifindex = ?',
      [ $host, $re->{'search'}{'result'}{'ifindex'} ]
    );
    if($re->{'cdp'}{'status'} ne 'ok' || !@{$re->{'cdp'}{'result'}}) {
      delete $re->{'cdp'};
    } else {
      $re->{'search'}{'result'}{'cdp'} = $re->{'cdp'}{'result'};
      delete $re->{'cdp'}{'result'};
    }

  #--- auth info

    $re->{'auth'} = sql_select(
      'spam',
      'SELECT *, fmt_inactivity(current_timestamp - chg_when) AS chg_age_fmt, '
      . 'extract(epoch from (current_timestamp - chg_when))::int AS chg_age '
      . 'FROM snmp_cafsessiontable WHERE host = ? AND ifindex = ? '
      . 'AND cafsessionauthusername IS NOT NULL ORDER BY chg_when DESC',
      [ $host, $re->{'search'}{'result'}{'ifindex'} ]
    );
    if($re->{'auth'}{'status'} eq 'ok' && @{$re->{'auth'}{'result'}}) {
      $re->{'search'}{'result'}{'auth'} = query_reduce(
        $re->{'auth'}{'result'},
        'host', 'cafsessionauthvlan', 'cafsessionauthusername',
        'cafsessionvlangroupname'
      );
    }

  }

  #--- finish

  return $re;
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
    1
  );

  return \%re;
}



#=============================================================================
# Value normalizer for the Add Patches form.
#=============================================================================

sub addp_normalize
{
  my ($type, $value) = @_;

  $value =~ s/^\s+|\s+$//g;

  # 'undef' is a special value
  if($type eq 'cp' && lc($value) eq 'undef') {
    return 'undef';
  }

  if($type eq 'cp' || $type eq 'ou') {
    return normalize_outcp($value);
  }

  return undef;
}



#==========================================================================
# Used by Add Patches form to inquire whether given site uses outlets not.
# Most sites don't use outlets.
#==========================================================================

sub backend_useoutlet
{
  my $site = shift;
  my %re = ( 'arg' => { 'site' => $site } );

  $re{'result'} = sql_site_uses_cp($site);
  $re{'status'} = 'ok';
  return \%re;
}



#==========================================================================
# Used by Add Patches to normalize host (switch name) and portname and
# verify their existence.
#==========================================================================

sub backend_swport
{

  #--- arguments

  my (
    $site,         # 1. three letter site code
    $host,         # 2. switch hostname
    $port          # 3. switch port name
  ) = @_;

  #--- structure returned to client as JSON, 'arg' key contains
  #--- the input values for later reference

  my %re = (
    'arg' => {
      'site'     => $site,
      'host'     => $host,
      'portname' => $port
    }
  );

  #--- normalization (just removing whitespace)

  $host =~ s/\s//g;
  $port =~ s/\s//g;

  #--- only PORTNAME

  #--- (this means nothing is done since we cannot lookup the portname
  #--- without knowing the switch hostname)

  if($port && !$host) {
    $re{'result'}{'host'} = undef;
    $re{'result'}{'portname'} = $port;
  } else {

  #--- both HOST and PORT

    if($port) {
      my $query = 'SELECT * FROM status WHERE substring(host for 3) = ? AND host = ? ';
      my $port_arg;
      if($port =~ /^\d[\/\d]*\d$/) {
        $query .= 'AND lower(portname) ~* ? LIMIT 1';
        $port_arg = sprintf('[a-z]%s$', $port);
      } else {
        $query .= 'AND lower(portname) = ? LIMIT 1';
        $port_arg = lc($port);
      }

      my $r = sql_select('spam', $query, [ lc($site), lc($host), $port_arg ]);
      if(ref($r) && scalar(@{$r->{'result'}})) {
        $re{'result'}{'host'} = $r->{'result'}[0]{'host'};
        $re{'result'}{'portname'} = $r->{'result'}[0]{'portname'};
        $re{'result'}{'exists'}{'host'} = JSON->true;
        $re{'result'}{'exists'}{'portname'} = JSON->true;
      } else {
        $re{'result'}{'exists'}{'portname'} = JSON->false;
      }
    }

  #--- only HOST

    if(!exists $re{'result'}{'host'}) {
      my $r = sql_select(
        'spam',
        'SELECT * FROM status WHERE substring(host for 3) = ? AND host = ? LIMIT 1',
        [ lc($site), lc($host) ]
      );
      if(ref($r) && scalar(@{$r->{'result'}})) {
        $re{'result'}{'host'} = $r->{'result'}[0]{'host'};
        $re{'result'}{'portname'} = undef;
        $re{'result'}{'exists'}{'host'} = JSON->true;
      } else {
        $re{'result'}{'exists'}{'host'} = JSON->false;
        delete $re{'result'}{'exists'}{'portname'};
      }
    }

  }

  #--- finish

  $re{'status'} = 'ok';
  return \%re;
}



#==========================================================================
# Function that tries to find and return cp that is associated with
# an outlet.
#==========================================================================

sub sql_get_cp_by_outlet
{
  #--- arguments

  my (
    $site,
    $outlet
  ) = @_;

  #--- perform the query

  my $r = sql_select(
    'spam',
    'SELECT * FROM out2cp WHERE site = ? AND outlet = ?',
    [ $site, $outlet ]
  );

  #--- process the result

  if($r->{'status'} eq 'ok') {
    return ($r->{'result'}[0]{'cp'}, $r);
  } else {
    return undef;
  }
}



#==========================================================================
# This function collects information about entries affected by
# sql_add_patches() function by querying the database using v_search_status
# view.
#==========================================================================

sub sql_update_summary
{
  #--- arguments

  my (
    $site,
    $work_info
  ) = @_;

  #--- other variables

  my $dbh = $dbh{'spam'};   # database handle
  my %re;                   # return data
  my @update_summary;       # result

  #--- loop over the work_info entries

  my $sth = $dbh->prepare(
    'SELECT * FROM v_search_status WHERE host = ? AND portname = ?'
  );
  while(my $entry = shift @$work_info) {
    my $r = $sth->execute(@$entry);
    if(!$r) {
      $re{'status'} = 'error';
      $re{'errmsg'} = 'Database error';
      $re{'errwhy'} = 'Failed to retrieve update summary';
      $re{'errdb'}  = pg_errmsg_parse($sth->errstr());
      return \%re;
    }
    my ($row) = $sth->fetchrow_hashref();
    $row->{'flags'} = port_flag_unpack($row->{'flags'});
    push(@update_summary, $row);
  }

  #--- finish

  $re{'status'} = 'ok';
  $re{'result'} = \@update_summary;
  $re{'lines'} = scalar(@update_summary);
  return \%re;
}



#==========================================================================
# Add Patches form executive. The $arg parameter contains the form data
# as key-value pairs.
#==========================================================================

sub sql_add_patches
{
  #--- arguments

  my (
    $arg,                   # 1. form fields from client (hashref)
    $site                   # 2. site the form was submited for
  ) = @_;

  #--- other variables

  my $dbh = $dbh{'spam'};   # database handle
  my $r;                    # database return value
  my %re;                   # return structure (sent to client as JSON)

  # list of (switch, portname) pairs used to collect information about
  # porttable/status (through v_search_status view) entries that were
  # affected by adding new patches; this is displayed to the user as
  # instant feedback about what they have actually done.

  my @work_info;

  #--- init

  $re{'debug'} = $debug;
  $re{'function'} = 'sql_add_patches';
  $re{'result'} = [];

  #--- are we using outlets for this site?

  $re{'useoutlet'} = do {
    my $useoutlet = backend_useoutlet($site);
    js_bool($useoutlet->{'status'} eq 'ok' && $useoutlet->{'result'});
  };

  #--- function to store/access form data

  # aux function to store/retrieve the form data while keeping them in
  # a structure suitable for client-side JS

  my $form = sub {
    my ($row, $type, $val) = @_;
    my $store = $re{'result'};
    my $name = sprintf('addp_%s%02d', $type, $row);

    if(defined $val) {
      # $val is non-empty hashref, add the keys
      if(ref($val) && %$val) {
        for my $k (keys %$val) {
          $store->[$row]{$type}{$k} = $val->{$k};
        }
        $store->[$row]{$type}{'name'} = $name;
        return $store->[$row]{$type};
      }
      # $val is empty-hashref, remove the 'type' node entirely
      elsif(ref($val) && !%$val) {
        delete $store->[$row]{$type};
      }
      # $val is scalar, return value for given type/key
      else {
        return $store->[$row]{$type}{$val};
      }
    }
    # $val is undef, return the whole type-hashref
    else {
      if(!$store->[$row]) {
        $store->[$row]{$type} = {};
      }
      return $store->[$row]{$type};
    }
  };

  #--- normalization and validation, pass 1

  # Following is done in this section:
  #
  # 1. normalize cp/outlet values (so that values that get into the datbase
  #    hove some chance of being sane)
  # 2. check whether host (switch) actually exists
  # 3. check whether switch port exists and turn it into its normal form
  #    (users need only to enter the numeric part, not the iftype prefix)
  #
  # The result is array of hashrefs in $re{'result'}, each hashref has
  # following keys: --FIX ME--
  #
  #   name  -- the HTML input name attribute
  #   value -- the normalized value
  #   valid -- boolean whether we think the vale is valid; invalid value is
  #            handled as error in the client and the user must reenter it

  for(my $row_no = 0;; $row_no++) {

  #--- get values, finish if no more values

    my $v = sprintf('%02d', $row_no);
    my $form_sw = $arg->{"addp_sw$v"};
    my $form_pt = $arg->{"addp_pt$v"};
    my $form_cp = $arg->{"addp_cp$v"};
    my $form_ou = $arg->{"addp_ou$v"};
    last if !($form_sw || $form_pt || $form_cp || $form_ou);

  #--- get switch/port feedback

    my $s = backend_swport($site, $form_sw, $form_pt);
    if($s->{'status'} ne 'ok') { $s = undef; }
    push(@{$re{'swport'}}, $s) if $debug;

  #--- switch

    if($form_sw) {
      my $sw_valid = js_bool($s->{'result'}{'exists'}{'host'});
      $form->($row_no, 'sw', {
        'value' => $s->{'result'}{'host'} // $form_sw,
        'valid' => $sw_valid
      });
      $form->($row_no, 'sw', { 'err' => 'Unknown switch' })
        if !$sw_valid;
    }

  #--- portname

    if($form_pt) {
      my $pt_valid = js_bool($s->{'result'}{'exists'}{'portname'});
      $form->($row_no, 'pt', {
        'value' => $s->{'result'}{'portname'} // $form_pt,
        'valid' => $pt_valid
      });
      $form->($row_no, 'pt', { 'err' => 'Invalid switch port' })
        if !$pt_valid;
      $form->($row_no, 'pt', { 'err' => 'Cannot validate switch port' })
        if !$pt_valid && !$s->{'result'}{'exists'}{'host'};
    }

  #--- cp

    if($form_cp) {
      my $cp_norm = addp_normalize('cp', $form_cp);
      $form->($row_no, 'cp', {
        'value' => $cp_norm,
        'valid' => js_bool($cp_norm)
      });
    }

  #--- outlet

    if($form_ou && $re{'useoutlet'}) {
      my $ou_norm = addp_normalize('ou', $form_ou);
      $form->($row_no, 'ou', {
        'value' => $ou_norm,
        'valid' => js_bool($ou_norm)
      });
    }

  }

  #--- validation, pass 2

  # fill in cp where user entered outlet; delete outlet entirely if that site
  # does not use outlet; if users enters both outlet than the db-provided value
  # of cp overrides the user supplied one

  for(my $row_no = 0; $row_no < scalar(@{$re{'result'}}); $row_no++) {
    my $outlet = $form->($row_no, 'ou');

    if($re{'useoutlet'} && $outlet->{'value'}) {
      my ($r_cp, $ret) = sql_get_cp_by_outlet($site, $outlet->{'value'});
      if($r_cp) {
        $form->($row_no, 'cp', {
          value => $r_cp,
          valid => JSON->true
        });
        $form->($row_no, 'ou', { valid => JSON->true });
      } else {
        $form->($row_no, 'cp', {
          value => undef,
          valid => JSON->false
        });
        $form->($row_no, 'ou', {
          valid => JSON->false,
          err => 'Outlet does not exist'
        });
      }
    } else {
      $form->($row_no, 'ou', {});
    }
  }

  #--- abort if validation resulted in at least one invalid form fields

  for(my $row_no = 0; $row_no < scalar(@{$re{'result'}}); $row_no++) {
    for my $type (qw(sw pt cp)) {
      if(!$form->($row_no, $type, 'valid')) {
        $re{'status'} = 'error';
        $re{'errmsg'} = 'Form validation failed';
        $re{'errwhy'} = 'Invalid user entry, validation failed';
        return \%re;
      }
    }
  }

  #--- try block start

  try {

  #--- begin transaction

    $r = $dbh->begin_work();
    if(!$r) {
      $re{'status'} = 'error';
      $re{'errmsg'} = 'Database error';
      $re{'errwhy'} = 'Failed to initiate database transaction';
      $re{'errdb'}  = pg_errmsg_parse($dbh->errstr());
      die "FAIL\n";
    }

  #--- loop over form rows

    for(
      my ($i, $n) = (0, scalar(@{$re{'result'}}));
      $i < $n;
      $i++
    ) {
      my (@fields, @values);
      my $pushdb = multipush(\@fields, \@values);
      my $row = $re{'result'}[$i];

      $pushdb->('host',      $form->($i, 'sw', 'value'));
      $pushdb->('portname',  $form->($i, 'pt', 'value'));
      $pushdb->('cp',        $form->($i, 'cp', 'value'));
      $pushdb->('site',      $site);
      $pushdb->('chg_who',   $ENV{'REMOTE_USER'}) if $ENV{'REMOTE_USER'};
      $pushdb->('chg_where', $ENV{'REMOTE_ADDR'}) if $ENV{'REMOTE_ADDR'};

      push(@work_info, [
        $form->($i, 'sw', 'value'),
        $form->($i, 'pt', 'value')
      ]);

      my $qry = sprintf(
        'INSERT INTO porttable ( %s ) VALUES ( %s )',
        join(',', @fields),
        join(',', ('?') x scalar(@fields))
      );

    #--- insert into 'porttable'

      my $r = $dbh->do($qry, undef, @values);
      if(!$r) {
        $re{'errwhy'} = 'Failed to insert data into database';
        $re{'errdb'} = pg_errmsg_parse($dbh->errstr());
        $re{'query'} = sql_show_query($qry, @values);
        $re{'formrow'} = $i;

        # interpret the error
        if($re{'errdb'}{'constraint'} eq 'porttable_pkey') {
          $form->($i, 'pt', {
            'valid' => JSON->false,
            'err' => 'Port already in use'
          });
        }

        # abort
        die "ABORT\n";
      }

    #--- update status so that the port appears fresh (ie. not inactive),
    #--- this gives the user time to actually start using the port

      $qry = "UPDATE status
                SET
                  lastchg = current_timestamp,
                  lastchk = current_timestamp
                WHERE host = ? AND portname = ?";

      $r = $dbh->do(
        $qry, undef, $form->($i, 'sw', 'value'), $form->($i, 'pt', 'value')
      );
      if(!$r) {
        $re{'errwhy'} = 'Failed to update data in the database';
        $re{'errdb'} = pg_errmsg_parse($dbh->errstr());
        $re{'query'} = sql_show_query($qry, @values);
        $re{'formrow'} = $i;
        die "ABORT\n";
      }

    }

  #--- try block end

  }

  #--- error processing

  catch {
    $re{'status'} = 'error';
    $re{'errmsg'} = 'Database error';
    chomp($_);
    if($_ eq 'ABORT') {
      $dbh->rollback();
    }
  };

  #--- commit transaction

  if($re{'status'} ne 'error') {
    $r = $dbh->commit();
    if(!$r) {
      $re{'errdb'} = pg_errmsg_parse($dbh->errstr());
      $re{'errwhy'} = 'Failed to commit database transaction';
      $re{'status'} = 'error';
      $re{'errmsg'} = 'Database error';
    }
    $re{'status'} = 'ok';
  }

  #--- search affected switch/ports pairs using v_search_status view
  #--- and return the info to backend, this is feedback for the user
  #--- saved under the 'search' key because we're reusing the template
  #--- from the Search Tool

  if(@work_info) {
    $re{'search'} = sql_update_summary($site, \@work_info);
  }

  #--- in case of error caused by duplicate portname, perform
  #--- collect update summary, which will cause the conflicting
  #--- entry to be displayed to the user

  if(
    $re{'errdb'}{'type'} eq 'dupkey'
    && $re{'errdb'}{'constraint'} eq 'porttable_pkey'
  ) {
    $re{'search'} = sql_update_summary(
      $site,
      [[ $re{'errdb'}{'conflict'}{'host'}, $re{'errdb'}{'conflict'}{'portname'} ]]
    );
  }

  #--- finish

  return \%re;
}



#=============================================================================
# Function to delete (individual) patches.
#=============================================================================

sub sql_del_patch
{
  #--- variables

  my ($host, $portname) = @_;
  my (%re, $qry, $r);

  #--- init

  $re{'function'} = 'sql_del_patch';
  $re{'debug'} = $debug;

  #--- perform query

  $qry = 'DELETE FROM porttable WHERE host = ? AND portname = ?';
  $re{'query'} = sql_show_query($qry, $host, $portname);
  $r = $db_spam->do($qry, undef, $host, $portname);
  $re{'dbrv'} = $r;
  if(!defined $r) {
    $re{'errdb'} = pg_errmsg_parse($db_spam->errstr());
    $re{'errwhy'} = 'Failed to remove database row';
    $re{'status'} = 'error';
    $re{'errmsg'} = 'Database error';
  } elsif($r <= 0) {
    $re{'errwhy'} = 'Failed to remove database row';
    $re{'status'} = 'error';
    $re{'errmsg'} = 'Database error';
  } else {
    $re{'status'} = 'ok';
  }

  #--- finish

  return \%re;
}



#=============================================================================
# Function to insert/update/delete modwire information (the modwire table,
# links linecards to wiring info, typically a patchpanel id).
#=============================================================================

sub sql_modwire
{
  #--- arguments

  my ($host, $m, $n, $location) = @_;

  #--- other variables

  my $dbh = $dbh{'spam'};   # database handle
  my %re;                   # return data
  my $qry;                  # query
  my $r;                    # query return value
  my @fld;                  # query fields

  #--- init

  $re{'function'} = 'sql_modwire';
  $re{'debug'} = $debug;
  if(!defined($m)) { $m = 0; }

  #>>> try block start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

  try {

  #--- deleting the entry

    if(!$location) {
      $qry = 'DELETE FROM modwire WHERE host = ? AND m = ? AND n = ?';
      @fld = ( $host, $m, $n );
      $re{'query'} = sql_show_query($qry, @fld);
      $r = $dbh->do($qry, undef, @fld);
      $re{'dbrv'} = $r;
      if(!$r) {
        $re{'errdb'} = pg_errmsg_parse($dbh->errstr());
        $re{'errwhy'} = 'Failed to remove database row';
        die;
      } elsif($r <= 0) {
        $re{'errwhy'} = 'Database row not found, nothing was deleted';
        die;
      }
    }

  #--- update/insert

    else {
      $qry =
        "UPDATE modwire
        SET location = ?, chg_who = ?, chg_where = ?, chg_when = now()
        WHERE host = ? AND m = ? AND n = ?";
      @fld = ($location, $ENV{REMOTE_USER}, $ENV{REMOTE_ADDR}, $host, $m, $n);
      $re{'query'} = sql_show_query($qry, @fld);
      $r = $dbh->do($qry, undef, @fld);
      $re{'dbrv'} = $r;
      if(!$r) {
        $re{'errdb'} = pg_errmsg_parse($dbh->errstr());
        $re{'errwhy'} = 'Failed to update database row';
        die;
      } elsif($r == 0) {
        $qry =
          "INSERT INTO modwire
          ( host, m, n, location, chg_who, chg_where )
          VALUES ( ?, ?, ?, ?, ?, ? )";
        @fld = ($host, $m, $n, $location, $ENV{REMOTE_USER}, $ENV{REMOTE_ADDR});
        $re{'query'} = sql_show_query($qry, @fld);
        $r = $dbh->do($qry, undef, @fld);
        $re{'dbrv'} = $r;
        if(!$r) {
          $re{'errdb'} = pg_errmsg_parse($dbh->errstr());
          $re{'errwhy'} = 'Failed to insert database row';
          die;
        }
      }
    }

  #<<< try block end <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

  } catch {
    $re{'status'} = 'error';
    $re{'errmsg'} = 'Database error';
  } finally {
    if(!exists $re{'status'}) { $re{'status'} = 'ok'; }
  };

  #--- finish

  return \%re;
}



#=============================================================================
#===   __  __    _    ___ _   _   ============================================
#===  |  \/  |  / \  |_ _| \ | |  ============================================
#===  | |\/| | / _ \  | ||  \| |  ============================================
#===  | |  | |/ ___ \ | || |\  |  ============================================
#===  |_|  |_/_/   \_\___|_| \_|  ============================================
#===                              ============================================
#=============================================================================


#--- process arguments -------------------------------------------------------

my %args;
my $q = new CGI;
my $req;           # request type

# below code allows the arguments to be specified on command line for
# debugging purposes as "par1=val1 par2=val2 ... "; command-line parameters
# also trigger debug mode and pretty JSON output; note

for my $arg (@ARGV) {
  my @x = split(/=/, $arg);
  $args{$x[0]} = $x[1] if $x[0];
}
if($args{'r'}) {
  $debug = JSON->true;
  $js->pretty(1);
  $req = $args{'r'};
} else {
  $req = $q->param('r');
}
$req //= '';

#--- define argument fetching function

my $arg = sub {
  my @r;
  for my $k (@_) {
    push(@r, $q->param($k) // $args{$k});
  }
  return @r;
};

#--- preamble ----------------------------------------------------------------

print "Content-type: application/json; charset=utf-8\n\n";

#--- verify database availability --------------------------------------------

if(my @db_unavail = grep { !ref($dbh{$_}) } keys %dbh) {
  print $js->encode({
    'userid' => $ENV{'REMOTE_USER'},
    'status' => 'error',
    'errmsg' => 'Database connection failed',
    'errwhy' => 'Unavailable db: ' . join(', ', @db_unavail)
  });
  exit(1);
}

#--- verify config is loaded in the BEGIN section ----------------------------

if(!ref($cfg)) {
  print $js->encode({
    'status' => 'error',
    'userid' => $ENV{'REMOTE_USER'},
    'errmsg' => 'Failed to load configuration file',
    'errwhy' => $cfg
  });
  exit(1);
}

#--- debugging mode ----------------------------------------------------------

my $auth = ONdb::Authorize->new(
  dbh => $dbh{'ondb'},
  user => $ENV{'REMOTE_USER'},
  tab_assign => 'assign_new',
  tab_access => 'access_new',
  system => 'spam',
);

if($#ARGV == -1) {
  $debug = js_bool(1) if $auth->authorize('debug');
  $js->pretty(1) if $debug;
}

#=============================================================================
#=== central dispatch ========================================================
#=============================================================================

#--- switch list -------------------------------------------------------------

if($req eq 'swlist') {
  my $re = sql_select('spam', 'SELECT * FROM v_swinfo', [], \&mangle_swlist);
  if(
    (grep { $_->{'stale'} } @{$re->{'result'}})
    && $debug
  ) {
    $re->{'showstale'} = 1;
  }
  print $js->encode($re);
}

#--- search tool -------------------------------------------------------------

if($req eq 'search') {
  my %par;
  for my $k (
    qw(site outcp host portname mac ip sortby mode username inact vlan vlans)
  ) {
    ($par{$k}) = &$arg($k);
  }
  remove_undefs(\%par);
  print $js->encode(sql_search(\%par));
}

#--- port info --------------------------------------------------------------

if($req eq 'portinfo') {
  print $js->encode(
    sql_portinfo($arg->('site'), $arg->('host'), $arg->('portname'))
  );
}

#--- use cp inquiry ---------------------------------------------------------

if($req eq 'usecp') {
  print $js->encode(backend_useoutlet(&$arg('site')));
}

#--- auxiliary data ---------------------------------------------------------

if($req eq 'aux') {
  print $js->encode(sql_aux_data());
}

#--- add patches -------------------------------------------------------------

if($req eq 'addpatch') {
  my @names = %args ? keys %args : $q->param();
  my %form;
  for my $k (@names) { ($form{$k}) = $arg->($k); }
  print $js->encode(sql_add_patches(\%form, $arg->('site')));
}

#--- remove patch ------------------------------------------------------------

if($req eq 'delpatch') {
  print $js->encode(sql_del_patch($arg->('host'), $arg->('portname')));
}

#--- add/update/remove modwire information -----------------------------------

if($req eq 'modwire') {
  print $js->encode(
    sql_modwire($arg->('host'), $arg->('m'), $arg->('n'), $arg->('location'))
  );
}

#--- default -----------------------------------------------------------------

print $js->encode({
  'userid' => $ENV{'REMOTE_USER'},
  'status' => 'ok',
  'debug'  => $debug
}) if !$req;
