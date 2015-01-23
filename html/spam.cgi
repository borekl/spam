#!/usr/bin/perl -I../

use SPAMv2;
use CGI;
use POSIX qw(strftime);
use utf8;


#=== global variables ======================================================

$user_group = undef;
$debug = undef;
$mail_cmd = '/usr/sbin/sendmail -t';


#===========================================================================
# Entry routine; called once per instance (but not once per request, since
# one instance can handle multiple request)
#===========================================================================

BEGIN {
  $| = 1;
  #--- global parameters ---
  dbinit('spam', 'spam', 'swcgi', 'InvernessCorona', '172.20.113.118');
  dbinit('ondb', 'ondb', 'swcgi', 'InvernessCorona', '172.20.113.118');
  $logfile = "/var/log/spam/swcgi.log";
  $mail = "borek.lupomesky\@vodafone.com";
  #$mail = "borek\@lupomesky.cz";
  
  #--- open log ---
  {
    my $r;
    $r = open(LOG, ">> $logfile");
    $logging = 1 if $r;
  }
}


#===========================================================================
# Clean-up routine; called when the script is released from memory
#===========================================================================

END {
  #--- close log ---
  close(LOG) if $logging;
  undef $logging;
}


#===========================================================================
# Produce HTTP header, <HEAD> section and open <BODY>. Note, that
# "default.css" is always included even if argument #4 (list of CSS
# stylesheets) is empty.
#===========================================================================

sub http_header
{
  my $q = shift;        # 1. CGI query object
  my $title = shift;    # 2. <TITLE>
  my $cookie = shift;   # 3. HTTP cookie (optional)
  my $css = shift;      # 4. ref to list of CSS stylesheets
  my $js = shift;       # 5. ref to list of JS scripts
  
  #--- default.css
  
  push(@$css, 'default.css');
  
  #--- HTTP header
  
  if($cookie) {
    print $q->header(-charset=>'utf-8', -cookie=>$cookie);
  } else {
    print $q->header(-charset=>'utf-8');
  }  

  #--- HTML header

  print <<EOHD;
<!doctype html>

<html>
<head>
  <title>Switch Ports Activity Monitor - $title</title>
EOHD

  for my $k (@$css) {
    print qq{  <link rel="stylesheet" type="text/css" href="$k" media="screen">\n};
  }
  for my $k (@$js) {
    print qq{  <script type="text/javascript" src="$k"></script>\n};
  }

  print <<EOHD;
</head>

<body>
EOHD
}


#===========================================================================
# This function does little syntax highlighting in SQL query string
#
# Arguments: 1. SQL query
# Returns:   1. SQL query with highlighted keywords using HTML mark-ups
#===========================================================================

sub sql_display
{
  my ($q) = (@_);

  $q =~ s/FROM/<BR>&nbsp;&nbsp;FROM/;
  $q =~ s/WHERE/<BR>&nbsp;&nbsp;WHERE/;
  $q =~ s/ORDER BY/<BR>&nbsp;&nbsp;ORDER BY/;
  $q =~ s/\) LEFT JOIN/\)<BR>&nbsp;&nbsp;&nbsp;&nbsp;LEFT JOIN/g;
  $q =~ s/\) RIGHT JOIN/\)<BR>&nbsp;&nbsp;&nbsp;&nbsp;RIGHT JOIN/g;
  $q =~ s/(SELECT|FROM|WHERE|USING|JOIN|RIGHT|LEFT|FULL|ORDER BY|OR|AND|ASC|DESC)/\<B\>$1\<\/B\>/g;
  return $q;
}


#===========================================================================
# Function for logging of modifications
#===========================================================================

sub modlog
{
  my ($s) = @_;
  my ($r);

  push(@log_m, $s);
#PETA  if(!$logging) { return; }
  $r = strftime("%c", gmtime);
  print LOG $r, " ", $s, "\n";
}


#===========================================================================
# This function mails modification changes to the admin
#===========================================================================

sub modlog_finish
{
  if(open(MAIL, "|$mail_cmd")) {
    print MAIL "From: Switch Ports Activity Monitor <netit\@vodafone.cz>\n";
    print MAIL "To: $mail\n";
    print MAIL "Subject: [spam] Database modification notification\n";
    print MAIL "Content-type: text/html\n\n";
    #print MAIL "<html><head><title>[spam] Database modification notification</title></head><body>\n"
    print MAIL "<pre>\n";
    for(@log_m) { print MAIL $_, "\n"; }
    print MAIL "</pre>\n";
    #print MAIL "</body></html>\n";
    print MAIL ".\n";
    close(MAIL);
    undef @log_m;
  }
}


#===========================================================================
#===========================================================================

sub pgres_err
{
  my ($c) = @_;
  my $err = $c->errorMessage;
  chomp($err);
  $err =~ s/^ERROR: *//;
  $err =~ s/ *$//;
  if(!$err) { $err = "Unknown error"; }
  return $err;
}


#===========================================================================
# Utility function to find index of an item within array.
#===========================================================================

sub array_find
{
  my ($ar, $val) = @_;
  
  for(my $i = 0; $i < scalar(@$ar); $i++) {
    return $i if $ar->[$i] eq $val;
  }
  return undef;
}
            

#===========================================================================
# form validation/normalization routines
#===========================================================================

sub validate_port
{
  my ($v) = @_;
  
  # valid forms: X/Y, X/Y/Z AaX/Y, AaX/Y/Z
  if($v =~ /^\d\/\d{1,2}$/ | 
     $v =~ /^\d\/\d{1,2}\/\d{1,2}$/ |
     $v =~ /^[A-Za-z]{2}\d\/\d{1,2}$/ |
     $v =~ /^[A-Za-z]{2}\d\/\d{1,2}\/\d{1,2}$/) {
    return 1;
  } else {
    return 0;
  }
}


#===========================================================================
# (Attempt to) normalize outlet name. Since outlet numbers can take many
# forms we cannot do any reliable validation.
#===========================================================================

sub normalize_outlet
{
  my $outlet = uc($_[0]);

  #--- remove leading and trailing spaces ---
  $outlet =~ s/^\s+//;
  $outlet =~ s/\s+$//;

  #--- remove superfluous space between numeric and letters part ---
  $outlet =~ s/^(\d+)\s*([[:alpha:]]+)/$1 $2/;
  return $outlet;
}


#===========================================================================
# Just removal of whitespaces.
#===========================================================================

sub normalize_cp
{
  my $cp = uc($_[0]);

  #--- remove leading and trailing spaces ---
  $cp =~ s/^\s+//;
  $cp =~ s/\s+$//;
  return $cp;
}

#===========================================================================
# Normalize tn (the PBX "terminal number")
#===========================================================================

sub normalize_tn
{
  my $tn = shift;
  my $r;

  $tn =~ /(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/;
  $r = sprintf('%d %d %d %d', $1, $2, $3, $4);
  return $r;
}


#===========================================================================
# Normalize PBX patchpanel coordinates.
#===========================================================================

sub normalize_ran
{
  my $ran = shift;
  my $r;
  
  $ran =~ /(-?\d+)\s+(\d+)\s+(\d+)/;
  $r = sprintf('%d %d %d', $1, $2, $3, $4);
  
  return $r;
}


#===========================================================================
# Normalize PBX dn.
#===========================================================================

sub normalize_dn
{
  my $dn = shift;
  my $r;
  
  $dn =~ /\s*(\d+)\s*/;
  $r = $1;
  
  return $r;
}
  

#===========================================================================
# Currently dummy function, since it's not clear how to validate a cons.
# point name.
#===========================================================================

sub validate_cp
{
  my ($v) = @_;
  return 1;
}


#===========================================================================
# Normalize MAC address string to canonic (comma delimited). Alowed MAC
# formats:
#   hh:hh:hh:hh:hh:hh
#   hh-hh-hh-hh-hh-hh
#   hhhh.hhhh.hhhh
#   hhhhhhhhhhhh
# Arguments: 1. MAC address string in one of the valid formats
#            2. 0 - 16-digit hexadecimal number format
#               1 - result in canonic (colon delimited) format
#               2 - same as 1 but allow * wildcard to pass through as
#                   valid character
# Returns:   undef on error or MAC addres in required format
#===========================================================================

sub normalize_mac
{
  my ($mac, $f) = @_;

  $_ = lc($mac);
  if($f != 2) {
    /^([0-9a-f]{1,2}):([0-9a-f]{1,2}):([0-9a-f]{1,2}):([0-9a-f]{1,2}):([0-9a-f]{1,2}):([0-9a-f]{1,2})$/ ||
    /^([0-9a-f]{1,2})-([0-9a-f]{1,2})-([0-9a-f]{1,2})-([0-9a-f]{1,2})-([0-9a-f]{1,2})-([0-9a-f]{1,2})$/ ||
    /^([0-9a-f]{2})([0-9a-f]{2})\.([0-9a-f]{2})([0-9a-f]{2})\.([0-9a-f]{2})([0-9a-f]{2})$/ ||
    /^([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/ ||
    return undef;
    return uc($f ? "$1:$2:$3:$4:$5:$6" : "$1$2$3$4$5$6");
  } else {
    /^([0-9a-f]{1,2}|\*):([0-9a-f]{1,2}|\*):([0-9a-f]{1,2}|\*):([0-9a-f]{1,2}|\*):([0-9a-f]{1,2}|\*):([0-9a-f]{1,2}|\*)$/ ||
    /^([0-9a-f]{1,2}|\*)-([0-9a-f]{1,2}|\*)-([0-9a-f]{1,2}|\*)-([0-9a-f]{1,2}|\*)-([0-9a-f]{1,2}|\*)-([0-9a-f]{1,2}|\*)$/ ||
    /^([0-9a-f]{2}|\*)([0-9a-f]{2}|\*)\.([0-9a-f]{2}|\*)([0-9a-f]{2}|\*)\.([0-9a-f]{2}|\*)([0-9a-f]{2}|\*)$/ ||
    /^([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/ ||
    return undef;
    return uc("$1:$2:$3:$4:$5:$6");
  }
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
  my $dbh = dbconn('ondb');
  my $group;

  #--- sanitize arguments

  if(!$user) { return 'No user name specified'; }
  $user = lc $user;

  #--- ensure database connection

  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }
  
  #--- perform query

  my $sth = $dbh->prepare('SELECT grpid FROM users WHERE userid = ?');
  my $r = $sth->execute($user);
  if(!$r) {
    return sprintf('Database query failed (ondb, %s)', $sth->errstr());
  }
  ($group) = $sth->fetchrow_array();

  #--- return results
  
  if(!$group) { return 'Cannot find user or no group assigned'; }
  return (undef, $group);
}


#===========================================================================
# Load list of switches from ONdb.
#===========================================================================

sub sql_switch_list
{
  my $dbh = dbconn('ondb');
  my @sw;
  
  if(!ref($dbh)) { return 'Cannot connect to database (ondb)'; }
  my $sth = $dbh->prepare('SELECT * FROM v_switchlist');
  my $r = $sth->execute();
  if(!$r) {
    return sprintf('Cannot get list of switches (ondb, %s)', $sth->errstr());
  }
  my $i = 0;
  while(my ($s) = $sth->fetchrown_array()) {
    $sw[$i++] = $s;
  }
  return \@sw;
}


#===========================================================================
# This function loads a table from database and stores it into an array;
# each element of the array is row of the table; array elements are
# references to hashes in the form field -> value.
#
# Arguments: 1. database (binding name)
#            2. query (may be undef, all columns loaded then)
#            3. table name (not used if query is supplied)
#===========================================================================

sub sql_get_table_hash
{
  my $db = shift;     # 1. database
  my $query = shift;  # 2. query (may be undef, all columns loaded then)
  my $table = shift;  # 3. table name (may be undef if query specified)
  my $dbh = dbconn($db);
  my @result;
  
  #--- ensure database connection
  
  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }

  #--- query
  
  if(!$query) { $query = "SELECT * FROM $table"; }
  my $sth = $dbh->prepare($query);
  my $r = $sth->execute();
  if(!$r) {
    return sprintf('Database query failed (ondb, %s)', $sth->errstr());
  }

  my $colnames = $sth->{NAME};
  while(my @a = $sth->fetchrow_array()) {
    my %h;
    for(my $i = 0; $i < scalar(@$colnames); $i++) {
      $h{$colnames->[$i]} = @a[$i];
    }
    push(@result, \%h);
  }
  return \@result;
}


#===========================================================================
# This function retrieves list of know user groups from ondb.
#
# Arguments: -none-
#
# Returns:   1. reference to hash or error message
#===========================================================================

sub sql_get_user_groups
{
  my $dbh = dbconn('ondb');
  my %v;
  
  #--- ensure database connection

  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }

  #--- query

  my $sth = $dbh->prepare('SELECT grpid, descr FROM groups');
  my $r = $sth->execute();
  if(!$r) {
    return sprintf('Database query failed (ondb, %s)', $sth->errstr());
  }
  while(my $ar = $sth->fetchrow_arrayref()) {
    $v{$ar->[0]} = $ar->[1];
  }
  return \%v;
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
  my $dbh = dbconn('ondb');
  my ($v);
  
  #--- sanitize arguments

  if(!$user || !$access) { return 'Required argument missing'; }
  $user = lc $user;
  $access = lc $access;

  #--- ensure database connection
  
  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }
  
  #--- query

  my $sth = $dbh->prepare(qq{SELECT authorize_user(?,'spam',?)::int});
  my $r = $sth->execute($user, $access);
  if(!$r) {
    return sprintf('Database query failed (ondb, %s)', $sth->errstr());
  }
  ($v) = $sth->fetchrow_array();
  return (undef, $v);  
}


#===========================================================================
# Finds real port designation (as returned by SNMP) from X/Y designation.
# For this, table "status" is queried.
# This function is used for port validation and port name expansion (ie.
# user enters 8/4, but SPAM expands it to Gi8/4 before inserting into DB).
#
# Arguments: 1. switch name
#            2. port name in form 'x/y' where x, y are integers
#
# Returns:   1. undef on success, error message otherwise
#            2. real port name, otherwise undef on failure
#            3. VLAN (only on exact find, this functionality is used
#               by html_update_summary())
#===========================================================================

sub sql_find_port
{
  my ($host, $port) = @_;
  my $dbh = dbconn('spam');
  my $r;
  my $q;

  #--- ensure database connection

  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }

  #--- phase 1: try to find exact port

  {
    $host = lc($host);
    my $sth = $dbh->prepare('SELECT portname, vlan FROM status WHERE host = ? AND portname = ?');
    $r = $sth->execute($host, $port);
    if(!$r) {
      return sprintf('Database query failed (ondb, %s)', $sth->errstr());
    }
    my $ar = $sth->fetchrow_arrayref();
    if($ar) {
      return(undef, $ar->[0], $ar->[1]);
    }
  }

  #--- phase 2: try to find port in form IfM/P (such as Fa0/1)

  if($port =~ /^\d+\/\d+$/ | $port =~ /^\d+\/\d+\/\d+$/) { 
    my $sth = $dbh->prepare('SELECT portname FROM status WHERE host = ? AND portname ~ ?');
    $r = $sth->execute($host, "[A-Za-z]+$port\$");
    if(!$r) {
      return sprintf('Database query failed (ondb, %s)', $sth->errstr());
    }
    my $ar = $sth->fetchrow_arrayref();
    if($ar) { return (undef, $ar->[0]) }
  }

  #--- no port found, does the switch exist at all? ---

  {
    my $sth = $dbh->prepare('SELECT * FROM status WHERE host = ? LIMIT 1');
    $r = $sth->execute($host);
    if(!$r) {
      return sprintf('Database query failed (ondb, %s)', $sth->errstr());
    }
    my @a = $sth->fetchrow_array();
    if(scalar(@a) > 0) {
      return "Port $port does not exist on $host";
    } else {
      return "Switch $host does not seem to exist";
    }
  }
}


#===========================================================================
# find cp by outlet
#===========================================================================

sub find_cp_by_outlet
{
  my ($outlet, $site) = @_;

  my $dbh = dbconn('spam');  
  my $r;
  
  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }
  my $sth = $dbh->prepare('SELECT cp FROM out2cp WHERE outlet = ? AND site = ?');
  $r = $sth->execute($outlet, $site);
  if(!$r) {
    return sprintf('Database query failed (spam, %s)', $sth->errstr());
  }
  my @a = $sth->fetchrow_array();
  if(scalar(@a) == 0) { return undef; }
  return $a[0];
}


#===========================================================================
# find outlet by cp
#===========================================================================

sub find_outlet_by_cp
{
  my ($cp, $site) = @_;
  
  my $dbh = dbconn('spam');
  my $r;
  
  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }
  my $sth = $dbh->prepare('SELECT outlet FROM out2cp WHERE cp = ? AND site = ?');
  $r = $sth->execute($cp, $site);
  if(!$r) {
    return sprintf('Database query failed (spam, %s)', $sth->errstr());
  }
  my @a = $sth->fetchrow_array();
  if(scalar(@a) == 0) { return undef; }
  return $a[0];
}


#===========================================================================
# find host from consolidation point
#===========================================================================

sub find_host_by_cp
{
  my ($cp, $site) = @_;
  my $dbh = dbconn('spam');
  my ($r, $v);
  
  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }
  $cp =~ s/\.\d$//;
  my $sth = $dbh->prepare('SELECT host FROM cpranges WHERE site = ? AND (? BETWEEN cpbeg AND cpend)');
  $r = $sth->execute($site, $cp);
  if(!$r) {
    return sprintf('Database query failed (spam, %s)', $sth->errstr());
  }
  my @a = $sth->fetchrow_array();
  if(scalar(@a) == 0) { return undef; }
  return $a[0];
}


#===========================================================================
# find number of given cp instances in porttable
#===========================================================================

sub porttable_cp_num
{
  my ($cp, $site) = @_;
  my $dbh = dbconn('spam');
  my $r;

  if(!ref($dbh)) {
    return 'Database connection failed (ondb)';
  }
  my $sth = $dbh->prepare('SELECT count(*) FROM porttable WHERE cp = ? AND site = ?');
  $r = $sth->execute($cp, $site);
  if(!$r) {
    return -1;
  }
  my $n = $sth->fetchrow_array();
  return $n
}


#===========================================================================
# find if host/port is in badports
#===========================================================================

sub find_badport
{
  my ($host, $port) = @_;

  my $dbh = dbconn('spam');
  my $r;

  if(!ref($dbh)) { return undef; }
  my $sth = $dbh->prepare('SELECT count(*) FROM badports WHERE host = ? AND portname = ?');
  $r = $sth->execute($host, $port);
  my ($n) = $sth->fetchrow_array();
  return $n;
}


#===========================================================================
# HTML heading
#===========================================================================

sub html_header
{
  my ($title) = @_;
  my $user = $user_group;
  if(!$user) { $user = '?'; }
  printf(qq{<p class="loginf">Logged as: <span class="loginfhlt">%s</span> / } 
         . qq{<span class="loginfhlt">%s</span></p>\n},
         $ENV{REMOTE_USER}, $user);
  print "<h1 align=center>${title}</h1>\n";
}


#===========================================================================
# Authentication/authorization violation message
#===========================================================================

sub auth_err
{
  my ($q, $access, $err) = @_;
  
  http_header($q, 'Authorization Error');
  html_header('Access denied');
  if($err) {
    print "<P>An error occured during authorization: $err</P>\n";
  } else {
    print "<P>Access token <B>$access</B> requested, but denied for user ";
    print "<B>$ENV{REMOTE_USER}</B>\n";
  }
}


#===========================================================================
# This function replaces '*' with '.*' but quotes all other special
# characters, so they are matched as literals
#===========================================================================

sub substitute_asterisk
{
  my ($s) = @_;

  $s =~ s/\*/ASTRSK/g;
  $s = quotemeta($s);
  $s =~ s/ASTRSK/\.\*/g;
  return $s;
}


#==========================================================================
# Search Tool SQL query generator. The generated query is executed and the
# content is read into memory
#
# Arguments: 1. hash reference with search conditions (keys are: site,
#               outlet, cp, host, portname, mac, ip
#            2. optional ORDER BY expression(s)
# Returns:   1. scalar: error message
#               array ref: field names
#            2. array ref to contents (array of arrays)
#            3. query string
#
# The query has three forms depending on what fields are searched for:
#  - "porttable" - (either of outlet, cp, host or portname)
#  - "mactable" - only MAC address
#  - "arptable" - only IP adress
#==========================================================================

sub sql_query
{
  my ($s, $order) = @_;
  my ($e, $q, $f, @ra);
  my $qtype;
  my $host_field = 'p';
  my $wh_host;
  
  #--- validate/preprocess input

  $s->{outlet} = normalize_outlet($s->{outlet});
  $s->{host} = lc($s->{host});
  ### FIXME: wildcard form of this only allows for 'colon' format
  $s->{mac} = normalize_mac($s->{mac}, 2) unless index($s->{mac}, '*') != -1;

  #--- load VLANs info

  if($e = sql_load_vlans($s->{site})) {
    return "Cannot load list of VLANs";
  }

  #--- query "root" field selection

  if($s->{outlet}) {
    $root_field = 'o';
  } else {
    $root_field = 's';
  }

  #--- query type ---
  
  if($s->{outlet} || $s->{cp}) {
    $qtype = 'porttable';
  } elsif($s->{host} || $s->{portname}) {
    $qtype = 'status';
  } elsif($s->{mac}) {
    $qtype = 'mactable';
  } elsif($s->{ip}) {
    $qtype = 'arptable';
  }
  if(!$qtype) { $qtype = 'porttable'; }
   
  #--- what we query for ---

  $q  = "SELECT site, host, portname, cp, ";
  $q .= 'outlet, coords, location, vlan, net_ip AS network, hostname, ';
  $q .= "dnsname, ip, mac, manuf(mac), p.chg_who, date_trunc('second', ";
  $q .= 'p.chg_when) as chg_when ';

  #--- where we query from ---

  if($qtype eq 'porttable') {
    $q .= "FROM  out2cp o FULL JOIN porttable p USING ( cp, site ) "; 
    $q .= 'LEFT JOIN status s USING ( host, portname ) ';
    $q .= 'LEFT JOIN mactable m USING ( host, portname ) ';
    $q .= 'LEFT JOIN arptable a USING ( mac ) ';
    $q .= 'LEFT JOIN hosttab h USING ( site, cp ) ';
    $q .= 'LEFT JOIN vlans_tmp v USING ( site, vlan ) ';
  } elsif($qtype eq 'mactable') {
    $q .= "FROM  out2cp o RIGHT JOIN porttable p USING ( cp, site ) "; 
    $q .= 'LEFT JOIN status s USING ( host, portname ) ';
    $q .= 'RIGHT JOIN mactable m USING ( host, portname ) ';
    $q .= 'LEFT JOIN arptable a USING ( mac ) ';
    $q .= 'LEFT JOIN hosttab h USING ( site, cp ) ';
    $q .= 'LEFT JOIN vlans_tmp v USING ( site, vlan ) ';
  } elsif($qtype eq 'arptable') {
    $q .= "FROM  out2cp o RIGHT JOIN porttable p USING ( cp, site ) "; 
    $q .= 'LEFT JOIN status s USING ( host, portname ) ';
    $q .= 'RIGHT JOIN mactable m USING ( host, portname ) ';
    $q .= 'RIGHT JOIN arptable a USING ( mac ) ';
    $q .= 'LEFT JOIN hosttab h USING ( site, cp ) ';
    $q .= 'LEFT JOIN vlans_tmp v USING ( site, vlan ) ';
  } elsif($qtype eq 'status') {
    $q .= "FROM  out2cp o RIGHT JOIN porttable p USING ( cp, site ) "; 
    $q .= 'RIGHT JOIN status s USING ( host, portname ) ';
    $q .= 'LEFT JOIN mactable m USING ( host, portname ) ';
    $q .= 'LEFT JOIN arptable a USING ( mac ) ';
    $q .= 'LEFT JOIN hosttab h USING ( site, cp ) ';
    $q .= 'LEFT JOIN vlans_tmp v USING ( site, vlan ) ';
    $host_field = 's';
    $root_field = 'p';
  }

  #--- query conditions to be met ---

  my @where_fields = (
    'site', 'outlet', 'o.cp',  "${host_field}.host",
    'portname', 'mac', 'ip', 'macact'
  );

  for my $k (@where_fields) {
    my $raw_key = $k;
    $raw_key =~ s/^.\.//;
    if(exists $s->{$raw_key} && $s->{$raw_key}) {
      $q .= $f ? ' AND ' : 'WHERE ';
      if($k eq 'mac') {
        if(index($s->{mac}, '*') == -1) {
          $q .= sprintf("mac = '%s'", $s->{mac});
        } else {
          $q .= sprintf("mac::text ~* '^%s\$'", substitute_asterisk($s->{mac}));
        }
      } elsif($k eq 'ip') {
        if(index($s->{ip}, '*') == -1) {
          $q .= sprintf("ip = '%s'", $s->{ip});
        } else {
          $q .= sprintf("ip::text ~* '^%s\$'", substitute_asterisk($s->{ip}));
        }
      } elsif($k eq 'o.cp') {
        $q .= sprintf("( o.cp = '%s' OR p.cp = '%s' )", $s->{cp}, $s->{cp}); 
      } elsif($k eq 'macact') {
        $q .= q{active = 't'};
      } else {
        $q .= sprintf("%s = '%s'", $k, $s->{$raw_key});
      }
      $f = 1;
    }
  }

  #--- ordering ---

  $q .= ' ORDER BY ' . $order if $order;

  #--- ensure database connection ---

  my $dbh = dbconn('spam');
  if(!ref($dbh)) {
    return 'Database connection failed (spam)';
  }
  
  #--- perform query ---

  my $sth = $dbh->prepare($q);
  my $r = $sth->execute();
  if(!$r) {
    return sprintf('Database query failed (spam, %s)', $sth->errstr());
  }

  # There's no reliable way to know number of returned rows without
  # reading the whole query result. That's what we're doing here.
  
  my $i = 0;
  my @r_fnames = @{$sth->{NAME}};
  my @r_rows;
  while(my @a = $sth->fetchrow_array()) {
    $r_rows[$i++] = \@a; 
  }  

  #--- finish

  return (\@r_fnames, \@r_rows, $q);
}


#===========================================================================
# Routine for HTML formatting of SQL query response
# 
# Arguments: 1. Array ref to field names
#            2. Array ref to rows
#            3. Options (string of characters each meaning one option)
#                 e ... omit empty columns
#                 u ... append row referencing URL (needs add. params)
#                    3. self-url (printf format string with %s's)
#                    4. reference to an array with names of fields used for
#                       row reference
#                    5. text
#                    6. callback (\%row) => boolean; if evaluates
#                       as FALSE, then the appeding of selfref URL is not
#                       done
#                 o ... oid marking
#                 h ... hide column (this param. can be used more than once)
#                    3. column to be omitted
#                 g ... group by field
#                    3. field to use for grouping
#            N. Additional parameters depending on options.
#
# Returns:   undef or error message string
#===========================================================================

sub html_query_out
{
  my $r_fnames = shift;  # array of field names
  my $r_rows = shift;    # array of rows
  my $options = shift;   # options
  my $opt_omitempty;
  my ($opt_selfurl, $opt_selfcols, $opt_reftext, $opt_cback);
  my $opt_markoid;
  my $opt_groupby;       # field to group displayed rows by
  my @opt_hidecolumn;
  my @table;             # contents of the query retrieved from db
  my @widths;            # column widths (calculated)
  my $twidth = 0;        # total width
  my @headings;          # column names (as they are in db)
  my $div = 2;           # how many spaces divide columns
  my $rclass;            # row SPAN class (for alternating background in rows)
  my $col_oid;           # what column is oid
  my ($grp_last, $grp_current); # for row grouping ('g' option)
  my $grp_field;                # for row grouping
  
  #--- processing arguments
  
  while($options) {
    $options =~ s/^(.)//;
    my $opt = $1;
    if($opt eq 'e') {
      $opt_omitempty = 1;
    }
    if($opt eq 'u') {
      $opt_selfurl = shift;
      $opt_selfcols = shift;
      $opt_reftext = shift;
      $opt_cback = shift;
    }
    if($opt eq 'o') {
      $opt_markoid = shift;
    }
    if($opt eq 'h') {
      my $x = shift;
      push(@opt_hidecolumn, $x);
    }
    if($opt eq 'g') {
      $opt_groupby = shift;
      for(my $i = 0; $i < scalar(@$r_fnames); $i++) {
        if($r_fnames->[$i] eq $opt_groupby) {
          $grp_field = $i;
        }
      }
      #--- if we cannot find the groupby field
      #--- disable the option entirely
      unset $opt_groupby if !defined($grp_field);
    }
  }
  
  #--- ensure we get meaningful query

  return "No query response" if !ref($r_fnames);
  return "Empty query" if !scalar(@$r_rows);

  #--- table dimensions, plus check

  my ($rows, $cols) = (scalar(@$r_rows), scalar(@$r_fnames));
  if(!($rows > 0 && $cols >0)) {
    return "Wrong number of rows or columns (rows=$rows, cols=$cols)";
  }
  
  #--- retrieve query, get column widths

  for(my $r = 0; $r < $rows; $r++) {
    my @a;
    for(my $c = 0; $c < $cols; $c++) {
      $a[$c] = $r_rows->[$r][$c];
      $widths[$c] = length($a[$c]) if length($a[$c]) > $widths[$c];
    }
    $table[$r] = \@a;
  }

  #--- get column headings, adjust column width

  for(my $c = 0; $c < $cols; $c++) {
    if(!($opt_omitempty && $widths[$c] == 0)) {
      if(length($r_fnames->[$c]) > $widths[$c]) {
        $widths[$c] = length($r_fnames->[$c]);
      }
    }
    if($r_fnames->[$c] eq 'oid') { $col_oid = $c; }
  }
  if($opt_markoid && !defined($col_oid)) {
    undef $opt_markoid;
  }

  #--- output heading

  print "<PRE>\n";
  print '<SPAN STYLE="background : gray; color : white; font-weight : bold">';
  for(my $c = 0; $c < $cols; $c++) {
    next if ($opt_omitempty && $widths[$c] == 0);
    next if $r_fnames->[$c] eq 'oid';
    next if grep { $_ eq $r_fnames->[$c] } @opt_hidecolumn;
    my $s = html_fill_up($r_fnames->[$c], $widths[$c] + $div);
    print $s;
    $twidth += $widths[$c];
  }
  print ' ' x length($opt_reftext) if $opt_reftext;
  print "</SPAN>\n";
  $twidth += (($cols - 1) * $div) + length($opt_reftext);

  #--- output rows

  $rclass = 'a';
  for(my $r = 0; $r < $rows; $r++) {
    #--- group headings
    if($opt_groupby) {
      $grp_current = $table[$r][$grp_field];
      if(!$grp_last || ($grp_current ne $grp_last)) {
        my $s = html_fill_up($grp_current, $twidth - 1);
        $s = qq{<span class="hqo_grp"> $s};
        $s .= qq{</span>\n};
        print $s;
        $grp_last = $grp_current;
      }
    }
    #--- highlighting OID-selected rows, otherwise alternating "striping"
    if($opt_markoid && $table[$r][$col_oid] == $opt_markoid) {
      print qq{<SPAN CLASS="h">};
    } else {
      print "<SPAN CLASS=\"$rclass\">";
    }
    #--- iterate over columns
    for(my $c = 0; $c < $cols; $c++) {
      #--- skip empty columns
      next if ($opt_omitempty && $widths[$c] == 0);
      #--- never output 'oid' field
      next if $r_fnames->[$c] eq 'oid';
      #--- skip hidden columns
      next if grep { $_ eq $r_fnames->[$c] } @opt_hidecolumn;
      my $s = html_fill_up($table[$r][$c], $widths[$c] + $div);
      print $s;
    }

    if($opt_selfurl) {
      my %row;
      for(my $x = 0; $x < $cols; $x++) {
        $row{$r_fnames->[$x]} = $table[$r][$x];
      }
      if(!ref($opt_cback) || &$opt_cback(\%row)) {
        my @self_cols_val;
        for(@$opt_selfcols) {
          push(@self_cols_val, $table[$r][array_find($r_fnames,$_)]);
        }

        my $self_url = sprintf($opt_selfurl, @self_cols_val);
        print '<A HREF="', $self_url, '">', $opt_reftext, '</A>'
      } else {
        print ' ' x length($opt_reftext);
      }
    }
    print "</SPAN>\n";
    $rclass = ($rclass eq 'a' ? 'b' : 'a' );
  }

  #--- finish

  print "</PRE>\n";
  return undef;
}


#===========================================================================
# This function pulls a list of vlans and associated subnets for a given
# site from "ondb" database and writes it into temporary table "vlans_tmp"
# in "spam". Not a nice solution, sure.
#
# Arguments: 1. site code (required)
# Returns:   1. undef on success or error message
#===========================================================================

sub sql_load_vlans
{
  my ($site) = @_;
  my $dbh_ondb = dbconn('ondb'); 
  my $dbh_spam = dbconn('spam');
  my ($q, $r, %vlans);

  #--- ensure database connections

  if(!ref($dbh_ondb)) {
    return 'Database connection failed (spam)';
  }
  if(!ref($dbh_ondb)) {
    return 'Database connection failed (ondb)';
  }

  #--- [ondb] read list of vlans

  $q = 'SELECT vlanno, net_ip FROM subnet JOIN site USING ( site_i ) ';
  $q .= "WHERE code = ? and vlanno > 0";
  my $sth_ondb = $dbh_ondb->prepare($q);
  $r = $sth_ondb->execute($site);
  if(!$r) {
    return sprintf('Cannot query database (ondb, %s)', $sth_ondb->errstr());
  }

  #--- [spam] drop table vlans_tmp

  my $sth_spam = $dbh_spam->prepare('DROP TABLE vlans_tmp');
  $r = $sth_spam->execute();
  if(!$r) {
    my $err = $sth_spam->errstr();
    if($err !~ /table .* does not exist/) {
      return sprintf('Cannot drop table (spam, %s)', $sth_spam->errstr());
    }
  }

  #--- [spam] create table vlans_tmp

  $sth_spam = $dbh_spam->prepare('CREATE TEMP TABLE vlans_tmp ( site char(3), vlan int2, net_ip inet )');
  $r = $sth_spam->execute();
  if(!$r) {
    return sprintf('Cannot create temporary table (spam, %s)', $sth_spam->errstr());
  }
  
  #--- [spam] insert rows int the table

  for my $k (keys %vlans) {
    $q = 'INSERT INTO vlans_tmp ( site, vlan, net_ip ) VALUES ( ?, ?, ? )';
    $sth_spam->prepare($q);
    $r = $sth_spam->execute($site, $k, $vlans{$k});
    if(!$r) {
      return sprintf('Database insert failed (spam, %s)', $sth_spam->errstr());
    }
  }
}


#===========================================================================
# Search Tool formular and processing
#===========================================================================

sub form_find
{
  my ($q) = @_;
  my ($outlet, $cp, $host, $port, $loc, $r, $err1, $err2, $mac_array);
  my ($mode, $c, $qs);
  my $self = $q->url(-relative=>1);
  my ($e, $access, $can_ipmac);
  my %cookval = $q->cookie('spam');
  my $cookie = undef;
  
  #--- check user's authorization to access Search Tool
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'search');
  if(!$access) {
    auth_err($q, 'search', $e);
    return;
  }
  
  #--- check users's authorization to search by IP/MAC address
  
  $can_ipmac = 1;
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'searchipmac');
  if(!$access) {
    $can_ipmac = 0;
  }

  #------------------------------------------------------------------------
  #--- defs ---------------------------------------------------------------
  #------------------------------------------------------------------------

  my %sortby_menu = (
    'portname' => 'Site+Switch+Portname (asc)',
    'hostname' => 'Hostname (asc)',
    'chgwhen' => 'Chg_when (desc)'
  );
  my %sortby_sql = (
    'portname' => "site, host, (substring(portname from '[0-9]+')::int * 100) "
                  . "+ substring(portname from '[0-9]+\$')::int",
    'hostname' => 'hostname',
    'chgwhen' => 'chg_when DESC'
  );
  my $sortby_def = 'portname';
  my $site_def = '-any-';
  
  #--- processing cookies
  
  if($Form::sortby || $Form::site) {
    $cookval{findsort} = $Form::sortby;
    $cookval{findsite} = $Form::site;
    $cookie = $q->cookie(-name=>'spam', -expires=>'+3y', 
                         -value=>\%cookval, -path=>'/spam/');
  } elsif(defined(%cookval)) {
    $sortby_def = $cookval{findsort} if $cookval{findsort};
    $site_def = $cookval{findsite} if $cookval{findsite};
  }
  
  #------------------------------------------------------------------------
  #--- form ---------------------------------------------------------------
  #------------------------------------------------------------------------

  http_header($q, 'Search Tool', $cookie);
  html_header('Search Tool');
  if($err1) {
    print qq{<p style="font-size : large">Error occurred: },
          qq{<span style="color : red"><strong>$err1</strong>\n};
    if($err2) {
      print "<i>(", $err2, ")</i>";
    }    
    print "</span></p>\n";
  }
  print $q->startform(-action=>"${self}?form=find");
  print "<P>&nbsp;</P><P><TABLE ALIGN=CENTER>\n";

  my $outlet_sites = sql_sites('out2cp');
  my @outlet_sites_loc = @$outlet_sites;
  push(@outlet_sites_loc, '-any-');
  print '<TR><TD VALIGN=TOP>Site:';
  print '<TD VALIGN=TOP>',
        $q->popup_menu(-name=>'site', -values=>\@outlet_sites_loc, -default=>$site_def),
        "</TD>\n";

  print "<TR><TD VALIGN=TOP>Outlet:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'outlet', -size=>10, -maxlength=>10);
  print "<BR><SMALL>", $r->[4],"</SMALL>\n" if $r->[4];

  print "<TR><TD VALIGN=TOP>Consolidation point:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'cp', -size=>10, -maxlength=>10), "\n";

  print "<TR><TD VALIGN=TOP>Switch name:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'host', -size=>16, -maxlength=>16), "\n";

  print "<TR><TD VALIGN=TOP>Port name:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'port', -size=>16, -maxlength=>16), "\n";

  if($can_ipmac) {
    print "<TR><TD VALIGN=TOP>MAC address<SUP>1</SUP>:";
    print "<TD VALIGN=TOP>", $q->textfield(-name=>'mac', -size=>17, -maxlength=>17);

    print "<TR><TD VALIGN=TOP>IP address<SUP>1</SUP>:";
    print "<TD VALIGN=TOP>", $q->textfield(-name=>'ip', -size=>17, -maxlength=>17);
  }

  print '<TR><TD VALIGN=TOP>Sort by:</TD>';
  print '<TD VALIGN=TOP>', $q->popup_menu(
     -name=>'sortby', -values=>[ keys %sortby_menu ],
     -default=>$sortby_def, -labels=>\%sortby_menu
  ), "</TD></TR>\n";

  print "<TR><TD COLSPAN=2><SMALL><SUP>1</SUP>&nbsp;",
        "You can use * wildcard in these fields</SMALL></TD></TR>\n"
        if $can_ipmac;

  print "<TR><TD>&nbsp;<TD>&nbsp;<TR><TD VALIGN=TOP>&nbsp;<BR>&nbsp;";
  print "<TD VALIGN=TOP>", $q->submit("Submit"), "&nbsp;", $q->defaults("Reset"), "\n";


  print "</TABLE></P><BR CLEAR=ALL>\n";
  print $q->endform;

  #------------------------------------------------------------------------
  #--- form processing ----------------------------------------------------
  #------------------------------------------------------------------------

  my (%query_conds, $query_str, $query_result);

  $Form::site = undef if $Form::site eq '-any-';
  $query_conds{site} = $Form::site;
  $query_conds{outlet} = $Form::outlet;
  $query_conds{cp} = $Form::cp;
  $query_conds{host} = $Form::host;
  $query_conds{portname} = $Form::port;
  $query_conds{mac} = $Form::mac;
  $query_conds{ip} = $Form::ip;
  $query_conds{macact} = $Form::macact;
  
  my $empty_query = 1;
  for(qw(site outlet cp host portname mac ip)) {
    if($query_conds{$_}) {
      $empty_query = 0;
      last;
    }
  }
  return if $empty_query;
  undef $empty_query;

  my ($r_names, $r_rows);
  ($r_names, $r_rows, $query_str) = sql_query(\%query_conds, $sortby_sql{$Form::sortby});
  print '<P><TT>', sql_display($query_str), "</TT></P>\n" if $debug;

  my $nrows = scalar(@$r_rows);

  if($nrows == 0) {
    print "<H2>No matching entries found ($query_result)</H2>\n";
    return;
  } else {
    print "<H2><SPAN STYLE=\"color : blue\">$nrows</SPAN> matching entr",
          $nrows == 1 ? 'y' : 'ies'," found</H2>\n";
  }

  my $errcode = html_query_out($r_names, $r_rows, 'e');
  print $errcode, "<BR>\n";
}


#===========================================================================
# Switch/hub Detection Tool
#===========================================================================

sub form_swdetect
{
  my ($q) = @_;
  my ($query, $wh_host, $wh_limit);
  my (@rows, $names);
  my %cookval = $q->cookie('spam');
  my $def_filter;
    

  #--- check user's authorization to access SwDetect Tool
  
  my ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'searchipmac');
  if(!$access) {
    auth_err($q, 'searchipmac', $e);
    return;
  }

  #--- cookie
  
  #if($Form::filter) {
  #  $cookval{swdetfilt} = $Form::filter;
  #  $cookie = $q->cookie(-name=>'spam', -expires=>'+3y', 
  #                       -value=>\%cookval, -path=>'/spam/');
  #} elsif(defined(%cookval)) {
  #  $Form::filter = $cookval{swdetfilter};
  #}

  #--- query

  $wh_limit = $Form::limit > 2 ? $Form::limit : 2;
  if($Form::filter) {
    $wh_host = q{s.host ~ '^} . $Form::filter . q{' AND }; 
  }
  $query = <<EOHD;
SELECT
  host, portname, 
  ( SELECT count(mac) FROM mactable WHERE host = s.host and portname = s.portname AND active = 't') AS maccnt,
  vlan, cp, outlet, descr
FROM status s
  FULL JOIN porttable p USING (host, portname)
  LEFT JOIN out2cp o USING (site, cp)
  LEFT JOIN hosttab h USING (site, cp)
WHERE
  $wh_host
  ( SELECT count(mac) FROM mactable WHERE host = s.host and portname = s.portname AND active = 't') >= ?
ORDER BY
  site, host,
  (substring(portname from '[0-9]+')::int * 100) + substring(portname from '[0-9]+\$')::int
EOHD

  #------------------------------------------------------------------------
  #--- form ---------------------------------------------------------------
  #------------------------------------------------------------------------

  http_header($q, 'Switch Detect Tool', $cookie);
  html_header('Switch Detect Tool');

  print $q->startform(-action=>"${self}?form=swdetect");
  print '<table align=center>', "\n";
  print '<tr><td>Hostname:</td>', "\n";
  print '<td>', $q->textfield(-name=>'filter', -size=>16, -maxlength=>16), "</td></tr>\n";
  print '<tr><td>Limit:</td>', "\n";
  print '<td>', $q->textfield(-name=>'limit', -size=>3, -maxlength=>3), "</td></tr>\n";
  print '<tr><td></td><td>', $q->submit('Submit');
  print $q->defaults('Reset');
  print "</td></tr>\n";
  print '</table>', "\n";
  print $q->endform();

  eval {

  #--- perform query

    my $dbh = dbconn('spam');
    if(!ref($dbh)) { die "Database connection failed (spam)\n"; }
    my $sth = $dbh->prepare($query);
    my $r = $sth->execute($wh_limit);
    if(!$r) {
      die sprintf('Database query failed (spam, %s)', $sth->errstr());
    }
    @rows;
    while(my @a = $sth->fetchrow_array()) {
      push(@rows, \@a);
    }
    $names = $sth->{NAME};
    
  #--- processing
  };
  if($@) {
    chomp($@);
    print "<p>Error: $@</p>\n";
  } else {
    html_query_out($names, \@rows, 'ghu', 'host', 'host',
      'spam.cgi?form=find&host=%s&port=%s&macact=1', [ host, portname ], 'Detail'
    );
  }
}


#=== edit main menu ========================================================

sub form_mmenu
{
  my ($q) = @_;
  my $self = $q->url(-relative=>1);

  http_header($q, 'Database Manipulation');
  html_header('Database Manipulation');
  print "<P><BIG><A HREF=\"${self}?form=add\">Add new patch(es)</A><BR>\n";
  print "<A HREF=\"${self}?form=remove\">Remove patch(es)</A><BR>\n";
  print "</BIG></P>\n";
}


#===========================================================================
# Reset form
#
# Arguments: 1. CGI object reference
#===========================================================================

sub form_reset
{
  my ($q) = @_;

  $q->delete_all;
  foreach (keys %Form::) { undef $Form::{$_}; }
}


#===========================================================================
# This function outputs update summary, that is displayed after successful
# database update using "Add Patches" form.
#===========================================================================

sub html_update_summary
{
  my $us = shift;         # @update_summary from form_add
  
  print qq{<pre id="summary">\nUPDATE SUMMARY\n\n};
  print "n   host             port     cp       outlet   vl\n";
  print "==  ================ ======== ======== ======== ===\n";
  
  for(my $i = 0; $i < scalar(@$us); $i++) {
    my $u = $us->[$i];
    my ($e, $p, $vl) = sql_find_port($u->[0], $u->[1]);
    next if $e;
    printf("%d.  %-16s %-8s %-8s %-8s %-3d\n", $i+1, $u->[0], $u->[1], $u->[2], $u->[3], $vl);
  }
  print "</pre>\n";
}


#===========================================================================
#===========================================================================

sub form_host_add 
{
  my ($q) = @_;            # main CGI form object
  my $rows = 1;            # number of rows, defaults to 1
  my $errmsg;              # error message string
  my @state_array;         # error code/state for each line
  my $empty_form = 1;      # empty from flag (true = empty)
  my $inhibit_update;      # perform no database update even with
                           # | valid data in the form
  my $can_group = 0;       # can user change group
  my $update_done;
  my ($e, $access);

  #--- check user's authorization to edit hosttable
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'hosttabedit');
  if(!$access) {
    auth_err($q, 'hosttabedit', $e);
    return;
  }
  
  #--- check user's authorization to manipulate owner group
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'hosttabgrp');
  if($access) { $can_group = 1; }
  
  #--- adding/removing rows  -----------------------------------------------

  if($Form::rows) { $rows = $Form::rows; }
  $q->delete('rows');
  if($rows < 1) { $rows = 1; }
  if($rows > 99) { $rows = 99; }

  #--- form processing -----------------------------------------------------

  for(my $i = 0; $i < $rows; $i++) {
    my $s;
    my $si = sprintf('%02d', $i);
    #--- ignore empty rows
    next if ! ( $q->param("host${si}") || $q->param("cp${si}"));
    $empty_form = 0;
    #--- sanitize inputs
    for my $k ("host${si}", "cp${si}") {
      $s = $q->param($k);
      $s =~ s/^\s+//; $s =~ s/\s+$//; # drop leading/trailing whitespaces
      $q->param(-name=>$k, -value=>$s);
    }
  }
  
  #--- perform database update ---------------------------------------------

  if(!$empty_form && !$inhibit_update) {
    my @sql;

    eval { #----------------------------------------------------------------

      #--- connect to database

      my $dbh = dbconn('spam');
      die "Cannot connect to database" unless ref($dbh);

      #--- begin transaction

      my $r = $dbh->begin_work();
      die "Cannot begin database transaction\n" unless $r;

      #--- loop over all lines

      for(my $i = 0; $i < $rows; $i++) {
        my $si = sprintf('%02d', $i);
        if(!$q->param("host${si}") || !$q->param("cp${si}")) {
          push(@{$state_array[$i]}, ["Missing data", []]);
          die "Missing data";
        }
        $sql[$i] = 'INSERT INTO hosttab ( site, grpid, cp, hostname, prodstat, ';
        $sql[$i] .= 'creat_who, chg_when ) VALUES ( ';
        $sql[$i] .= "'" . $q->param("site${si}") . "', ";
        $sql[$i] .= "'" . $q->param("group${si}"). "', ";
        $sql[$i] .= "'" . $q->param("cp${si}") . "', ";
        $sql[$i] .= "'" . $q->param("host${si}") . "', ";
        $sql[$i] .= "'" . $q->param("prodstat${si}") . "', ";
        $sql[$i] .= "'" . $ENV{REMOTE_USER} . "', NULL )";
      }   

      #--- send insert to database
      for(my $i = 0; $i < $rows; $i++) {
        my $sth = $dbh->prepare($sql[$i]);
        my $r = $sth->execute();
        if(!$r) {
          my $err = $sth->errstr();
          push(@{$state_array[$i]}, [ $sth->errstr(), []]);
          $dbh->rollback();
          die "Could not insert new entry into database\n";
        }
      }

      $dbh->commit();
      $update_done = 1;

    }; #-------------------------------------------------------------------/

    if($@) {
      $errmsg = $@; chomp($errmsg);
    }
  }
 
  #-------------------------------------------------------------------------
  #--- form ----------------------------------------------------------------
  #-------------------------------------------------------------------------
  
  http_header($q, 'Add new hosts', undef, [], [ 'jquery.js', 'spam-form_add.js' ]);
  html_header('Add new hosts');

  #--- error message (if there's any)

  if($errmsg) {
    print qq{<p id="errmsg" style="color : red"><big>$errmsg</big></p>\n};
  } elsif($update_done == 1) {
    print qq{<p id="statusmsg" style="color : green">}, 
          qq{<big>Database updated successfully</big></p>\n};
    $q->delete_all;
    $update_done = 0;
    $rows = 1;
  }

  #--- groups handling
  
  my $group_values;
  my $group_labels;
  my $group_default;
  if($can_group) {
    my $group = sql_get_user_groups();
    if(ref($group)) {
      my @a = sort { lc($group->{$a}) cmp lc($group->{$b}) } keys %$group;
      $groups_values = \@a;
      $groups_labels = $group;
      $group_default = $user_group;
    } else {
      $can_group = 0;
    }
  }

  #--- production states handling

  my $prodstat_values;
  my $prodstat_labels;
  my $prodstat_default = 1;
  my $prodstat = sql_get_table_hash('spam', undef, 'prodstat');
  if(ref($prodstat)) {
    for my $k (@$prodstat) {
      my $v = $k->{prodstat_i};
      my $l = $k->{descr};
      push(@$prodstat_values, $v);
      $prodstat_labels->{$v} = $l;
    }
  }

  #--- generate the form
  
  print $q->startform, "\n";
  print $q->hidden(-name=>'rows', -default=>$rows), "\n";

  #--- table header
  
  print <<EOHD;
<table>
  <tr>
    <th>&nbsp;</th>
    <th>site</th>
EOHD

  print qq{    <th>group</th>\n} if $can_group;
  print <<EOHD; 
    <th>cp</th>
    <th>host</th>
    <th>status</th>
  </tr>
EOHD

  #--- table rows 
  
  for(my $i = 0; $i < $rows; $i++) {
    my $x = $i + 1;
    my $si = sprintf('%02d', $i);
    print '  <tr>';
    print "    <td>$x.</td>\n";
    print '    <td>', $q->popup_menu(-name=>"site", -values=>['vin','rcn']), "</td>\n";
    if($can_group) {
      print '    <td>', $q->popup_menu(-name=>"group${si}", -values=>$groups_values,
        -labels=>$groups_labels, -default=>$group_default), "</td>\n";
    } else {
      print $q->hidden(-name=>"group${si}", -default=>$user_group);
    }
    print '    <td>', $q->textfield(-name=>"cp${si}", -size=>16, -maxlength=>16), "</td>\n";
    print '    <td>', $q->textfield(-name=>"host${si}", -size=>16, -maxlength=>16), "</td>\n";
    print '    <td>', $q->popup_menu(-name=>"prodstat${si}", -values=>$prodstat_values,
      -labels=>$prodstat_labels, -default=>$prodstat_default), "</td>\n";
    #--- add/remove buttons
    print '    <td>';
    print qq[<button name="remove${si}">&minus;</button>] if $rows > 1;
    print qq[<button name="add${si}">+</button>] if ($i+1) == $rows;
    print "</td>\n";
    print "  </tr>\n";
    if(scalar(@{$state_array[$i]}) > 0) {
      my $j = 1;
      print qq{  <tr class="errmsg" id="errmsg$si">\n};
      print qq{    <td></td>\n};
      print qq{    <td></td>\n};
      print qq{    <td colspan=4>};
      for my $l (@{$state_array[$i]}) {
        my $errmsg = $l->[0];
        print $j++, ': ', $errmsg, '<br>';
      }
      print qq{</td>\n};
      print qq{  </tr>\n};
    }
  }
  print "<table>\n\n";
  
  print qq{<div style="margin-top : 1em">\n};
  print qq{<button type="submit" name="submit">Submit</button>\n};
  print qq{<button type="reset" name="reset">Clear</button>\n};
  print qq{</div>\n\n};

  print $q->endform, "\n\n";
}


#===========================================================================
#=== add menu ==============================================================
#===========================================================================

sub form_add
{
  my ($q) = @_;        # 1. CGI object
  my $rows = 1;        # number of rows in form (default is 1)
  my $inhibit_update;  # don't update database even with valid form data
  my @state_array;     # array holding individual error messages for rows
  my $errmsg;          # error message in case of failure
  my $form_valid;      # valid data in form row, update possible
  my $form_empty;      # aux flag inidicating empty form
  my $update_done;     # update successful flag
  my @update_summary;  # update summary information
  my ($e, $access);
  my %cookval = $q->cookie('spam');
  my $cookie = undef;
    
  #--- function for creating URL to Remove Tool with values
  # arguments (1) row number (preformatted); (2) colliding object
  # (1-switchport, 2-cp)
  
  my $remove_tool_url = sub {
    my ($si, $m) = @_;
    my $self = $q->self_url(-relative=>1, -query=>0);
    my $site = $q->param('site');
    my $url;
    if($m == 1) {
      my $host = $q->param("host${si}");
      my $port = $q->param("port${si}");
      $url = $self . "?form=remove&site=$site&host=$host&port=$port";
    } elsif($m == 2) {
      my $cp = $q->param("cp${si}");
      $url = $self . "?form=remove&site=$site&cp=$cp";
    }
    return $url;
  };

  #--- function for replacing messages in state_array
  # allows replacement of particular message in state array
  
  my $replace_message = sub {
    my ($i, $search, $message) = @_;
    for my $k (@{$state_array[$i]}) {
      if(grep(/$search/,@{$k->[1]})) { $k->[0] = $message; return 1; }
    }
    return undef;
  };

  #--- function for "humanizing" database error messages
  # returns (1) error message and (2) id of html element, that is 
  # relevant to the error message (or undef, if none is)
  
  my $db_error_msg = sub {
    my ($err, $si) = @_;
    if($err =~ /^ERROR.*duplicate key.*porttable_pkey/) {
      my $url = &$remove_tool_url($si, 1);
      return (qq{Switch port already in use ( <a target="_blank" href="$url">remove conflicting record</a> )}, ["port${si}"]);
    } else {
      return ($err,[]);
    }
  };
              
  #--- check user's authorization to add/remove patches
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'patch');
  if(!$access) {
    auth_err($q, 'patch', $e);
    return;
  }

  #=== form processing ====================================================

  #--- check for check-only ([check] button being clicked)

  if($Form::check) { $inhibit_update = 1; }

  #--- get number of rows
  
  if($Form::rows) { $rows = $Form::rows; }

  #--- form processing ----------------------------------------------------

  $form_valid = 1;
  $form_empty = 1;
  for(my $i = 0; $i < $rows; $i++) {
    undef $state_array[$i];
    my $si = sprintf("%02d", $i);

    #--- ignore empty rows ---

    next if ! ( $q->param("host${si}") || $q->param("port${si}") ||
      $q->param("cp${si}") || $q->param("outlet${si}") );
    $form_empty = 0;

    #--- normalize outlet ---

    if($q->param("outlet${si}")) {
      my $out = normalize_outlet($q->param("outlet${si}"));
      $q->param(-name=>"outlet${si}", -value=>$out);
    }

    #--- discover cp (forward!) ---

    my $cp;
    if(!$q->param("cp${si}") && $q->param("outlet${si}")) {
      $cp = find_cp_by_outlet($q->param("outlet${si}"), $q->param("site"));
      if($cp != -1 && $cp) {
        $q->param(-name=>"cp${si}", -value=>$cp);
      }
    } elsif($q->param("cp${si}")) {
      $cp = $q->param("cp${si}");
    }

    #--- try to find outlet ---

    my $outlet;
    if(!$q->param("outlet${si}")) {
      $outlet = find_outlet_by_cp($q->param("cp${si}"), $q->param("site"));
      if($outlet) {
        $q->param(-name=>"outlet${si}", -value=>$outlet);
      }
    }

    #--- try to guess hostname ---

    if(!$q->param("host${si}") && $q->param("cp${si}")) {
      my $host = find_host_by_cp($q->param("cp${si}"), $q->param("site"));
      if($host) {
        $q->param(-name=>"host${si}", -value=>$host);
      }
    }

    #--- validate portname ---
    # port must be found in STATUS table, otherwise no go

    if($q->param("port${si}") && $q->param("host${si}")) {
      my ($r, $p) = sql_find_port($q->param("host${si}"), $q->param("port${si}"));
      if(!$r) {
        $q->param(-name=>"port${si}", -value=>$p);
      } else {
        my $hlt = [];
        if($r =~ /^Port/) {
          $hlt = [ "port${si}" ];
        } elsif($r =~ /^Switch/) {
          $hlt = [ "host${si}" ];
        }
        push(@{$state_array[$i]}, ["$r", $hlt ]);
        $form_valid = 0;
      }
    }

    #--- find cp ---
    # if outlet is specified, but cp was not found

    if(($cp == -1 || !$cp) && $q->param("outlet${si}")) {
      push(@{$state_array[$i]}, ["Cannot find consolidation point", ["cp${si}"]]);
      $form_valid = 0;
      next;
    }

    #--- check bad port ---

    if(find_badport($q->param("host${si}"), $q->param("port${si}")) > 0) {
      push(@{$state_array[$i]}, ["Switch port is BAD. Repatch!", ["port${si}"]]);
      $form_valid = 0;
      next;
    }

    #--- ensure cp uniqueness ---
    # we handle cp = 'undef' as a singular value, that does not
    # need to be unique; it is intended to make port seem patched
    # to SPAM, but not to reference any cp (usually for directly
    # interconnected ports, such as switch-switch links etc.)

    if(porttable_cp_num($cp, $q->param("site")) != 0 && $cp ne 'undef') {
      my $url = &$remove_tool_url($si, 2);
      my ($hlt, $msg) = ([ "cp${si}" ], qq{Consolidation point already in use (<a target="_blank" href="$url">remove conflicting record</a> )});
      if($q->param("outlet${si}")) {
        $msg = qq{Outlet/cp already in use (<a target="_blank" href="$url">remove conflicting record</a> )};
        push(@$hlt, "outlet${si}");
      }
      push(@{$state_array[$i]}, [$msg, $hlt]);
      $form_valid = 0;
      next;
    }

    #--- check for incomplete rows ---

    if(!$inhibit_update) {
      if(not ($q->param("host${si}") && $q->param("port${si}") &&
              ( $q->param("cp${si}") || $q->param("outlet${si}")))) {
        push(@{$state_array[$i]},['Incomplete information', []]) if !$state_array[$i];
        $form_valid = 0;
        next;
      }
    }

    #--- syntax checking: port ---
    # if state_array already contains message relating to port field
    # replace it if the syntax itself is bad; this prevents having
    # both "port does not exist" and "invalid port spec" messages at
    # the same time, which is confusing.
    
    if(!validate_port($q->param("port${si}")) && !$inhibit_update) {
      if(!&$replace_message($i, "port${si}", 'Invalid port specification')) {
        push(@{$state_array[$i]}, ['Invalid port specification', ["port${si}"]]);
      }
      $form_valid = 0;
      next;
    }
    
    #--- syntax checking: cp ---
    
    if($q->param("cp${si}") && ! validate_cp($q->param("cp${si}"))) {
      push(@{$state_array[$i]}, ["Invalid cp specification", []]);
      $form_valid = 0;
      next;
    }
  }
  $form_valid = 0 if $form_empty;
  
  #=== create update/insert queries and perform them ======================

  if($form_valid && !$inhibit_update) {
    eval {
      my $dbh = dbconn('spam');
      die 'Cannot connect to database' unless ref($dbh);
      my $r = $dbh->begin_work();
      die 'Cannot begin database transaction' unless $r;
      for(my $i = 0; $i < $rows; $i++) {
        my $si = sprintf("%02d", $i);
        next if not $q->param("host${si}");
        my $query_i = 'INSERT INTO porttable ( host, portname, cp, site, chg_who, chg_where, chg_when ) VALUES ( ';
        my $query_u  = "UPDATE status SET lastchg = '" . strftime("%c", localtime()) . "' WHERE ";
        my $logentry;
        {
          my $host_c = lc($q->param("host${si}"));
          my $port_c = $q->param("port${si}");
          my $cp_c = $q->param("cp${si}");
          my $outlet_c = $q->param("outlet${si}");
          my $site_c = $q->param("site");
          $query_i .= "'" . $host_c . "', ";           # host
          $query_u .= "host = '$host_c' ";
          $query_i .= "'" . $port_c . "', ";           # portname
          $query_u .= "AND portname = '$port_c'";
          $query_i .= "'" . $cp_c . "', ";             # cp
          $query_i .= "'" . $site_c . "', ";           # site
          $query_i .= "'" . $ENV{REMOTE_USER} . "', "; # chg_who
          $query_i .= "'" . $ENV{REMOTE_ADDR} . "', "; # chg_where
          $query_i .= "timestamp 'now' )";             # chg_when
          $logentry = "SWPORTS ADD: host = $host_c, port = $port_c, cp = $cp_c, outlet = $outlet_c";
          $update_summary[$i] = [ $host_c, $port_c, $cp_c, $outlet_c ];
        }
        modlog($logentry);
        modlog("SWPORTS ADD: client = $ENV{REMOTE_ADDR}, user = $ENV{REMOTE_USER}");
        my $sth = $dbh->prepare($query_i);
        $r = $sth->execute();
        if(!$r) {
          my $err =  $sth->errstr();
          push(@{$state_array[$i]}, [ &$db_error_msg($err, $si)]);
          $dbh->rollback();
          modlog("SWPORTS ADD: result = database error during insert ($err)");
          modlog("---------------------------------------------------------------");
          modlog_finish;
          die "Could not insert new entry into database\n";
        } else {
          my $sth = $dbh->prepare($query_u);
          $r = $sth->execute();
          if(!$r) {
            my $err = $sth->errstr();
            push(@{$state_array[$i]}, [ $err, []]);
            $dbh->rollback();
            modlog("SWPORTS ADD: result = database error during update ($err)");
            modlog("---------------------------------------------------------------");
            modlog_finish;
            die "Could not update entry in database\n";
          } else {
            modlog("SWPORTS ADD: result = OK");
          }
        }
      }
      $dbh->commit();
      #--------------------------------------------
      $update_done = 1;
      modlog("---------------------------------------------------------------");
      modlog_finish;
    };
    if($@) { $errmsg = $@; chomp($errmsg); }
  }

  #--- processing cookies
  
  $cookval{addpatchsite} = $Form::site if $Form::site;
  $cookie = $q->cookie(-name=>'spam', -expires=>'+3y', -value=>\%cookval, -path=>'/spam/');

  #=== generate HTML page =================================================

  my $outlet_sites = sql_sites('out2cp');

  #--- page header
    
  http_header($q, 'Add new patches', $cookie, [], [ 'jquery.js', 'spam-form_add.js' ]);
  html_header('Add new patch(es)');

  #--- error message or update summary
  
  if($errmsg) {
    print qq{<p id="errmsg" STYLE="color : red"><BIG>$errmsg</BIG></P>\n};
  } elsif($update_done == 1) {
    print qq{<p id="statusmsg" STYLE="color : green"><BIG>Database updated successfully</BIG></P>\n};
    html_update_summary(\@update_summary);
    $q->delete_all;
    $update_done = 0;
    $rows = 1;
  }

  #--- form start

  print $q->startform, "\n";
  print $q->hidden(-name=>'rows', -default=>$rows), "\n";

  #--- table header
  
  print <<EOHD;
<table>
  <tr>
    <th>&nbsp;</th>
    <th>site</th>
    <th>host</th>
    <th>port</th>
    <th>cp</th>
    <th>outlet</th>
  </tr>
EOHD
 
  #--- table rows

  for(my $i = 0; $i < $rows; $i++) {
    my $class;
    my $si = sprintf('%02d', $i);
    my @tag;  # error tags
    for my $l (@{$state_array[$i]}) {
      my $id = $l->[1];
      @tag = (@tag, @$id);
    }
    print "  <tr>\n";
    print '    <td>', $i + 1, ".</td>\n";
    print '    <td>';
    if($i == 0) {
      print $q->popup_menu(-name=>"site", -values=>$outlet_sites, 
                           -default=>($cookval{addpatchsite} ? $cookval{addpatchsite}:'sto'));
    } else {
      print "</td>\n";
    }
                                      
    $class = grep(/^host/, @tag) ? 'err' : '';
    print '    <td>', $q->textfield(-name=>"host${si}", -size=>16, -maxlength=>16, -class=>$class), "</td>\n";
    $class = grep(/^port/, @tag) ? 'err' : '';
    print '    <td>', $q->textfield(-name=>"port${si}", -size=>8, -maxlength=>16, -class=>$class), "</td>\n";
    $class = grep(/^cp/, @tag) ? 'err' : '';
    print '    <td>', $q->textfield(-name=>"cp${si}", -size=>16, -maxlength=>16, -class=>$class), "</td>\n";
    $class = grep(/^outlet/, @tag) ? 'err' : '';
    print '    <td>', $q->textfield(-name=>"outlet${si}", -size=>16, -maxlength=>16, -class=>$class), "</td>\n";
    #--- add/remove buttons
    print '    <td>';
    print qq[<button name="remove${si}">&minus;</button>] if $rows > 1;
    #print '&nbsp;' if ($rows > 1) && ($i+1) == $rows;
    print qq[<button name="add${si}">+</button>] if ($i+1) == $rows;
    print "</td>\n";
    #--- error messages
    print "  </tr>\n";
    if(scalar(@{$state_array[$i]}) > 0) {
      my $j = 1;
      print qq{  <tr class="errmsg" id="errmsg$si">\n};
      print qq{    <td></td>\n};
      print qq{    <td></td>\n};
      print qq{    <td colspan=4>};
      for my $l (@{$state_array[$i]}) {
        my $errmsg = $l->[0];
        print $j++, ': ', $errmsg, '<br>';
      }
      print qq{</td>\n};
      print qq{  </tr>\n};
    }
  }

  #--- end table
  
  print "</table>\n\n";
  
  #--- buttons
  
  print qq{<div style="margin-top : 1em">\n};
  print qq{<button type="submit" name="submit">Submit</button>\n};
  print qq{<button type="submit" name="check" value="1">Fill In</button>\n};
  print qq{<button type="reset" name="reset">Clear</button>\n};
  print qq{</div>\n\n};
  
  #--- end form
  
  print $q->endform, "\n";                             
}


#===========================================================================
#=== form remove ===========================================================
#===========================================================================

sub form_remove
{
  my ($q) = @_;
  my ($outlet, $cp, $host, $port, $loc, $r, $errmsg);
  my $delete_ok;                        # deletion successfull
  my $phase;                            # phase: undef|find|full
  my $submit_lbl = "Submit";
  my $qs;
  my $query_result;
  my ($e, $access);


  #--- check user's authorization to add/remove patches
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'patch');
  if(!$access) {
    auth_err($q, 'patch', $e);
    return;
  }

  #------------------------------------------------------------------------
  #--- form processing ----------------------------------------------------
  #------------------------------------------------------------------------

  #--- determine phase ---

  if($Form::cp && $Form::host && $Form::port) {
    $phase = "full";
  } elsif($Form::outlet || $Form::cp || $Form::host || $Form::port) {
    $phase = "find";
  }  

  #--- find ---  

  if($phase eq "find") {
    my %query_conds;
    $query_conds{outlet} = $Form::outlet;
    $query_conds{cp} = $Form::cp;
    $query_conds{host} = $Form::host;
    $query_conds{portname} = $Form::port;
    $query_conds{site} = $Form::site;
    my ($r_names, $r_rows);
    ($r_names, $r_rows, $qs) = sql_query(\%query_conds);
    if(!ref($r_names)) {
      $errmsg = "Database error ($r_names)";
      undef $phase;
    } elsif(scalar(@$r_rows) == 0) {
      $errmsg = "No matches";
      undef $phase;
    } else {
      @query_result = @{$r_rows->[0]};
      $q->param('outlet', $query_result[4]);
      $q->param('cp', $query_result[3]);
      $q->param('host', $query_result[1]);
      $q->param('port', $query_result[2]);
      $submit_lbl = "Delete";
    }
  }
  
  #--- perform delete ---

  if($phase eq "full") {
    my $ret;
    my $dbh = dbconn('spam');
    if(!ref($dbh)) {
      $errmsg = "Cannot connect to database";
    } else {
      my $query = "DELETE FROM porttable WHERE ";
      my $logentry;
      $query .= "site ='" . $Form::site . "' ";
      $query .= "AND cp = '" . $Form::cp . "' ";
      $query .= "AND host = '" . $Form::host . "' ";
      $query .= "AND portname = '" . $Form::port . "'";
      if($Form::outlet) {
        $logentry = "SWPORTS DEL: site = $Form::site, host = $Form::host, port = $Form::port, cp = $Form::cp, outlet = $Form::outlet";
      } else {
        $logentry = "SWPORTS DEL: site = $Form::site, host = $Form::host, port = $Form::port, cp = $Form::cp";
      }
      modlog($logentry);
      modlog("SWPORTS DEL: client = $ENV{REMOTE_ADDR}, user = $ENV{REMOTE_USER}");
      my $sth = $dbh->prepare($query);
      $ret = $sth->execute();
      if(!ret) {
        $errmsg = 'Cannot delete from database (' . $sth->errstr() . ')';
      } else {
        $q->delete_all;
        foreach (keys %Form::) { undef $Form::{$_}; }
        $delete_ok = 1;
      }
      modlog("---------------------------------------------------------------");
      modlog_finish;
    }
  }
  
  #------------------------------------------------------------------------
  #--- form ---------------------------------------------------------------
  #------------------------------------------------------------------------

  http_header($q, 'Remove patch');
  html_header('Remove patch');
  print $q->startform, "\n";
  print "<P STYLE=\"color : red\"><BIG>$errmsg</BIG></P>\n" if $errmsg;
  print "<P STYLE=\"color : green\"><BIG>Entry successfully deleted</BIG></P>\n" if $delete_ok;
  print "<P>&nbsp;</P><TABLE ALIGN=CENTER>\n";

  my $outlet_sites = sql_sites('out2cp');
  print "<TR><TD VALIGN=TOP>Site";
  print "<TD VALIGN=TOP>", $q->popup_menu(-name=>"site${si}", -values=>$outlet_sites, -default=>'vin'), "</TD>\n";

  print "<TR><TD VALIGN=TOP>Outlet:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'outlet', -size=>10, -maxlength=>10);
  print "<BR><SMALL>", $query_result[4], "</SMALL>\n" if $query_result[4];

  print "<TR><TD VALIGN=TOP>Consolidation point:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'cp', -size=>10, -maxlength=>10), "\n";

  print "<TR><TD VALIGN=TOP>Switch name:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'host', -size=>16, -maxlength=>16), "\n";

  print "<TR><TD VALIGN=TOP>Port name:";
  print "<TD VALIGN=TOP>", $q->textfield(-name=>'port', -size=>16, -maxlength=>16), "\n";

  print "<TR><TD VALIGN=TOP>&nbsp;<BR>&nbsp;";
  print "<TD VALIGN=TOP>", $q->submit(-name=>'submit', -value=>$submit_lbl), "&nbsp;", $q->defaults("Reset"), "\n";

  print "</TABLE></P><BR CLEAR=ALL>\n";

  print $q->endform, "\n";
}


#===========================================================================
#=== hosttab update/remove form ============================================
#===========================================================================

sub form_host_update
{
  my ($q) = @_;
  my $dbh = dbconn('spam');
  my $query;
  my $ret;
  my $errmsg;
  my @row;
  my %col;
  my $self_url = $q->self_url;
  my $inhibit_form = 0;
  my $sql;
  my ($e, $access);
  my $can_group;

  #--- check user's authorization to edit hosttable, ie. enter
  #--- this form at all
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'hosttabedit');
  if(!$access) {
    auth_err($q, 'hosttabedit', $e);
    return;
  }
  
  #--- check user's authorization to manipulate owner group
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'hosttabgrp');
  if($access) { $can_group = 1; }

  #--- callback

  my $callback = sub {
    my $h = shift;
    ($h->{grpid} eq $user_group) || $can_group;
  };

  #--- initialize

  http_header($q, 'Remove/update host');
  html_header('Remove/update host');
  print "\n";

  #--- check for [reset] button being clicked -----------------------------

  if($Form::reset) {
    form_reset($q);
    $inhibit_form = 1;
    $self_url = $q->self_url;
  }

  #--- check for [delete] button being clicked ----------------------------

  if($Form::delete) {
    $sql = 'DELETE FROM hosttab ';
    $sql .= sprintf("WHERE site = '%s' AND cp = '%s' AND hostname = '%s'",
      $Form::site, $Form::cp, $Form::hostname);
  }

  #--- check for [update] button being clicked ----------------------------

  if($Form::update) {
    $sql = 'UPDATE hosttab ';
    $sql .= "SET site = '%s', grpid = '%s', cp = '%s', hostname = '%s', ";
    $sql .= "prodstat = %d, ";
    $sql .= "chg_when = CURRENT_TIMESTAMP, chg_who = '$ENV{REMOTE_USER}' ";
    $sql .= "WHERE site = '%s' AND cp = '%s' AND hostname = '%s'";

    $sql = sprintf(
             $sql, $Form::site, $Form::grpid, $Form::cp, $Form::hostname,
             $Form::prodstat, $q->url_param('site'), $q->url_param('cp'),
             $q->url_param('hostname')
           );
  }

  #--- is user authorized to update this information?
  
  if(!$can_group && $Form::update) {
    if($Form::grpid ne $user_group) {
      $errmsg = 'Not authorized to update this entry';
      $sql = '';
    }
  }
  
  #--- perform database update/delete -------------------------------------

  if($sql) {
    if(!ref($dbh)) {
      $errmsg = "Cannot connect to database";
    } else {
      my $sth = $dbh->prepare($sql);
      my $r = $sth->execute();
      if(!$r) {
        $errmsg = 'Database update failed (' . $sth->errstr() . ')';
      } else {
        print qq{P STYLE="color : green"><BIG>Database updated</BIG></P>\n};
        $inhibit_form = 1;
      }
    }
  }

  #--- groups handling

  my $group_values;
  my $group_labels;
  my $group_default;
  if($can_group) {
    my $group = sql_get_user_groups();
    if(ref($group)) {
      my @a = sort { lc($group->{$a}) cmp lc($group->{$b}) } keys %$group;
      $groups_values = \@a;
      $groups_labels = $group;
      $group_default = $user_group;
    } else {
      $can_group = 0;
    }
  }

  #--- production states handling

  my $prodstat_values;
  my $prodstat_labels;
  my $prodstat_default = 1;
  my $prodstat = sql_get_table_hash('spam', undef, 'prodstat');
  if(ref($prodstat)) {
    for my $k (@$prodstat) {
      my $v = $k->{prodstat_i};
      my $l = $k->{descr};
      push(@$prodstat_values, $v);
      $prodstat_labels->{$v} = $l;
    }
  }

  #--- form

  print "<P STYLE=\"color : red\"><BIG>$errmsg</BIG></P>\n" if $errmsg;
  print $q->startform, "\n\n";
  if($q->url_param('cp') && !$inhibit_form) {
  
    if(!$q->url_param('grpid')) { $q->param('grpid', $group_default); }
    print "<TABLE>\n";

    print '  <TR><TD>Site:</TD><TD>';
    print $q->popup_menu(-name=>'site', -values=>['vin','rcn']);
    print "</TD></TR>\n";
    print "  <TR><TD>Cp:</TD><TD>", $q->textfield(-name=>'cp', -size=>10, -maxlength=>10), "</TD></TR>\n";

    print "  <TR><TD>Group:</TD><TD>";
    if($can_group) {
      print $q->popup_menu(-name=>'grpid', -values=>$groups_values,
        -labels=>$groups_labels);
    } else {
      print $q->hidden(-name=>'grpid'), "\n";
      print $groups_labels->{ $q->url_param('grpid') };
    }
    print "</TD></TR>\n";
    
    print "  <TR><TD>Hostname:</TD><TD>", $q->textfield(-name=>'hostname', -size=>16, -maxlength=>16), "</TD></TR>\n";

    print "  <TR><TD>Status:</TD><TD>";
    print $q->popup_menu(-name=>'prodstat', -values=>$prodstat_values,
      -labels=>$prodstat_labels);
    print "</TD></TR>\n";

    print "  <TR></TR>\n";
    print "  <TR><TD>&nbsp;</TD><TD>", $q->submit(-name=>'update', -value=>'Update'), '&nbsp;';
    print $q->submit(-name=>'delete', -value=>'Delete'), "&nbsp;";
    print $q->submit(-name=>'reset', -value=>'Reset'), "</TD></TR>\n";
    print "</TABLE>\n\n";
    print $q->endform, "\n\n";

    print "<P>&nbsp;</P>\n";
  }

  #--- listing

  eval {
    if(!ref($dbh)) { die "Cannot connect to database\n"; }
    
    #--- perform database query
    
    $query =  q{SELECT site, cp, hostname, lower(p.descr) AS status, grpid, };
    $query .= q{prodstat, creat_who, };
    $query .= q{substring(date_trunc('minute', creat_when)::varchar from 1 for 16) as creat_when, };
    $query .= q{chg_who, };
    $query .= q{substring(date_trunc('minute', chg_when)::varchar from 1 for 16) as chg_when };
    $query .= q{FROM hosttab h LEFT JOIN prodstat p ON h.prodstat = p.prodstat_i };
    $query .= q{ORDER BY site, cp};
    
    my $sth = $dbh->prepare($query);
    $ret = $sth->execute();
    if(!$ret) {
      die 'Query database (' . $sth->errstr() . ")\n";
    }

    my $i = 0;
    my @r_fnames = @{$sth->{NAME}};
    my @r_rows;
    while(my @a = $sth->fetchrow_array()) {
      $r_rows[$i++] = \@a; 
    }  

    print "<PRE>\n";
    $self_url =~ s/\?.*$//;
    html_query_out(\@r_fnames, \@r_rows, 'uh', $self_url .
      '?form=hostupd;site=%s;grpid=%s;cp=%s;hostname=%s;prodstat=%s',
      ['site','grpid','cp','hostname','prodstat'], 'Edit/remove', $callback,
      'prodstat'
    );
  };
  if($@) {
    print "<BIG>Error: $@</BIG>\n";
  }

  #--- finish
}


#===========================================================================
#=== form_ppmap ============================================================
#===========================================================================

sub form_ppmap 
{
  my ($q) = @_;
  my $dbh = dbconn('spam');
  my $sites = sql_sites('ppmap');
  my ($e, $access);
  my %cookval = $q->cookie('spam');
  my $cookie = undef;
  my $site_default = $cookval{ppmapsite};

  #--- check user's authorization to Patch Panel Map tool
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'ppmap');
  if(!$access) {
    auth_err($q, 'ppmap', $e);
    return;
  }

  #--- cookies processing
  
  if($Form::site) {
    $cookval{ppmapsite} = $Form::site;
    $cookie = $q->cookie(-name=>'spam', -expires=>'+3y', -value=>\%cookval, -path=>'/spam/');
  }

  #--- initialize

  http_header($q, 'Patch Panel Map Tool', $cookie);
  html_header('Patch Panel Map Tool');
  print "\n";
  if(!ref($sites)) { $sites = [ 'vin' ]; }

  #--- check for [reset] button being clicked -----------------------------

  if($Form::reset) {
    form_reset($q);
    $inhibit_form = 1;
    $self_url = $q->self_url;
  }

  #--- form

  print $q->startform, "\n\n";
  print "<TABLE ALIGN=CENTER>\n";

  print " <TR><TD>Site:</TD>";
  print "<TD>", $q->popup_menu(-name=>'site', -values=>sql_sites('ppmap'), -default=>$site_default), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Name<SUP>1</SUP>:</TD>";
  print "<TD>", $q->textfield(-name=>'name', -size=>16, -maxlength=>16), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Column:</TD>";
  print "<TD>", $q->textfield(-name=>'col', -size=>1, -maxlength=>1), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Row:</TD>";
  print "<TD>", $q->textfield(-name=>'row', -size=>2, -maxlength=>2), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Position:</TD>";
  print "<TD>", $q->textfield(-name=>'pos', -size=>1, -maxlength=>1), "</TD>";
  print "</TR>\n";

  print " <TR><TD COLSPAN=2><SMALL><SUP>1</SUP>&nbsp;Search by regular expression</SMALL></TD></TR>\n";
  print " <TR><TD>&nbsp;</TD><TD></TD></TR>\n";
  print " <TR><TD>&nbsp;</TD><TD>";
  print $q->submit(-name=>'search', -value=>'Search'), "&nbsp;";
  print $q->submit(-name=>'reset', -value=>'Reset'), "</TD></TR>\n";

  print "</TABLE>\n";
  print $q->endform, "\n\n";

  #--- processing ---

  if(!$Form::search) { return; }
  eval {
    if(!ref($dbh)) { die "Cannot connect to database\n"; }

    #--- assemble query string

    my $query = 'SELECT site, chr(col + 64) as col, row, pos, name FROM ppmap ';
    $query .= "WHERE site = '" . $Form::site . "'";
    if($Form::col ne '') {
      my $c = uc($Form::col);
      if($c !~ /[A-Z]/) { die "Invalid column specification\n"; }
      my $c = (ord(uc($Form::col)) - ord('A')) + 1;
      $query .= ' AND col = ' . $c;
    }
    if($Form::row ne "") {
      if($Form::row < 1) { die "Invalid row specification\n"; }
      $query .= ' AND row = ' . $Form::row;
    }
    if($Form::pos ne "") {
      if($Form::pos < 1 || $Form::pos > 7) { die "Invalid position specification\n"; }
      $query .= ' AND pos = ' . $Form::pos;
    }
    if($Form::name ne "") {
      my $s = $Form::name;
      if($s !~ /[\*\^\$\?]/) {
        $s = ".*$s.*";
      }
      $query .= " AND name ~* '$s'";
    }
    $query .= ' ORDER BY col, row, pos';

    #--- perform query
    my $sth = $dbh->prepare($query);
    my $r = $sth->execute();
    if(!$r) {
      die 'Database query failed (spam, ' . $sth->errstr() . ")\n";
    }

    my $i = 0;
    my @r_fnames = @{$sth->{NAME}};
    my @r_rows;
    while(my @a = $sth->fetchrow_array()) {
      $r_rows[$i++] = \@a; 
    }  
    
    html_query_out(\@r_fnames, \@r_rows, 'e');
  };
  if($@) {
    print "<BIG>Error: $@</BIG>\n";
  }
}


#===========================================================================
#=== form_ppmap v2 =========================================================
#===========================================================================

# FIXME STUFF:
# - list of sites/rooms is fixed in the HTML code below

sub form_ppmap2
{
  my ($q) = @_;
  my ($e, $access);

  #--- check user's authorization to Patch Panel Map tool
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'ppmap');
  if(!$access) {
    auth_err($q, 'ppmap', $e);
    return;
  }

  #--- initialize
  
  http_header($q, 'Patch Panel Map Tool', undef, ['ppmap.css',
    'css/custom-ppmap/jquery-ui-1.7.2.custom.css'], ['jquery.js','jquery-ui.js',
    'jquery.cookie.js','ppmap.js']);
  html_header('Patch Panel Map Tool');
  print "\n";

  #--- rest of the page
  
  print <<EOHD;
<p>THIS PAGE IS IN DEVELOPMENT!!! USE AT YOUR OWN RISK.<BR>
Works best in Firefox 3.5, Safari 4, Opera 9, Chrome 3.0, IE 9 or newer.
Original version <a href="https://l5nets02/spam/spam.cgi?form=ppmap">here</a>.</p>

<div class="form">

  <div class="inline">
    <div>site</div>
    <div>
      <select id="site" name="site">
      <option value="rcnSWR">Jažlovice Switch Room</option>
      <option value="brrSWR">Brno Switch Room</option>
      </select>
    </div>
  </div>

  <div class="inline">
    <div>outlet</div>
    <div>
      <input id="search" type="text" name="search"  size="16" maxlength="16" />
    </div>
  </div>

  <div class="inline">
    <input id="submit" type="submit" name="submit" value="Submit" />
    <input id="reset" type="reset" name="reset" value="Reset" />
  </div>

  <div style="margin-top : 0.5em">
    <div>display mode</div>
    <div>
      <input type="radio" name="dispmode" value="normal" checked>Normal</input>
      <input type="radio" name="dispmode" value="switch">Switch activity</input>
    </div>
  </div>

  <p class="fnote">
  You can use
  <a href="regexp-qref.html" onclick="return !window.open(this.href,'','');">regular expressions</a>
  for selecting outlet.
  </p>
</div>

<div class="msgdisp">
  <span id="count" class="count"></span>
  <span id="coords" class="coords"></span>
  <span id="label" class="label"></span>
</div>

<div id="status" class="status">
<p><img src="spinner.gif">
Loading data from server</P>
</div>


<div id="tabs" style="clear : left">

  <ul>
    <li><a href="#tabs-1">Graphical Map</a></li>
    <li><a href="#tabs-2">List</a></li>
  </ul>

  <div id="tabs-1">
  <canvas id="ppmap" width="1024" height="532"></canvas>
  </div>

  <div id="tabs-2">
  <pre>No outlet filter selected</pre>
  </div>

</div>
                                        
EOHD
}


#===========================================================================

sub form_permedit
{
  my ($q) = @_;
  my ($e, $access);
  my $dbh = dbconn('spam');
  my $errcol = 'red';
  my $highlight;

  #--- check user's authorization to Permanent Outlet tool
  
  ($e, $access) = user_access_evaluate($ENV{REMOTE_USER}, 'permedit');
  if(!$access) {
    auth_err($q, 'permedit', $e);
    return;
  }

  #--- initialize

  http_header($q, 'Permanent Outlets');
  html_header('Permanent Outlets');
  print "\n";

  eval {

  #------------------------------------------------------------------------
  #--- check for [delete] button being clicked ----------------------------
  #------------------------------------------------------------------------
  
  if($Form::delete) {
    my ($outlet, $cp);
    my $found = 0;
      
  #--- basic processing of input
  
    if($Form::outlet) { $outlet = normalize_outlet($Form::outlet); }
    if($Form::cp) { $cp = normalize_cp($Form::cp); }

  #--- if 'cp' is specified, we can go about deleting the entry
  
    if($cp) {
      if(!ref($dbh)) { die "Cannot connect to dabase\n"; }
      my $query = "DELETE FROM permout WHERE site = ? AND cp = ?";
      my $sth = $dbh->prepare($query);
      my $r = $sth->execute($Form::site, $cp);
      if(!$r) {
        die 'Database delete failed (' . $sth->errstr() . ")\n";
      }
      if($r == 0) { 
        die "No entries deleted because none were found.\n";
      }
    } elsif($outlet) {

  #--- if 'outlet' is specified, we need first to find cp
  
      $cp = find_cp_by_outlet($outlet, $Form::site);
      if($cp) {
        $q->param(-name=>'cp', -value=>$cp);
        $found = 1;
        $errcol = 'green';
        die "Click DELETE button again to remove this entry.\n";
      }
    } else {

  #--- if neither 'cp' nor 'outlet' is defined, then return error
  
      die "Either outlet or cp fields must be specified. No delete performed.\n";
    }
    form_reset($q);
  }

  #------------------------------------------------------------------------
  #--- check for [update] button being clicked ----------------------------
  #------------------------------------------------------------------------
  
  if($Form::update) {
    if($Form::outlet && !$Form::cp) {
      my $outlet = normalize_outlet($Form::outlet);
      $q->param(-name=>'outlet', -value=>$outlet);
      my $e = find_cp_by_outlet($outlet, $Form::site);
      if(!$e) {
        die "Cannot find cp for outlet " . $Form::outlet . "\n";
      }
      $q->param(-name=>'cp', -value=>$e);
      $Form::cp = $e;
    }
    if(!$Form::owner || !$Form::cp) {
      die "One or more required fields not filled in.\n";
    }

    #--- perform update
    
    my $q_update_where = sprintf(q{cp = '%s'}, $Form::cp);
    my $q_update_set .= sprintf(q{owner = '%s', }, $Form::owner);
    if($Form::descr) {
      $q_update_set .= sprintf(q{descr = '%s', }, $Form::descr);
    } else {
      $q_update_set .= 'descr = NULL, ';
    }
    if($Form::valfrom) {
      $q_update_set .= sprintf(q{valfrom = '%s', }, $Form::valfrom);
    } else {
      $q_update_set .= 'valfrom = NULL, ';
    }
    if($Form::valuntil) {
      $q_update_set .= sprintf(q{valuntil = '%s', }, $Form::valuntil);
    } else {
      $q_update_set .= 'valuntil = NULL, ';
    }
    $q_update_set .= sprintf(q{chg_who = '%s', }, $ENV{REMOTE_USER});
    $q_update_set .= 'chg_when = current_timestamp';
    $q_update = "UPDATE permout SET $q_update_set WHERE $q_update_where";
    my $sth = $dbh->prepare($q_update);
    my $r = $sth->execute();
    if(!$r) {
      die "Cannot update this entry (" . $sth->errstr() . ")\n";
    }
    
    #--- find OID of updated entry

    my $sth = $dbh->prepare('SELECT oid FROM permout WHERE site = ? AND cp = ?');
    my $r = $sth->execute($Form::site, $Form::cp);
    ($highlight) = $sth->fetchrow_array() if $r;
    
    form_reset($q);
  }

  #------------------------------------------------------------------------
  #--- check for [add] button being clicked -------------------------------
  #------------------------------------------------------------------------
  
  if($Form::add) {

  #--- if 'cp' is unspecified, we need to find it
  
    if($Form::outlet && !$Form::cp) {
      my $outlet = normalize_outlet($Form::outlet);
      $q->param(-name=>'outlet', -value=>$outlet);
      my $e = find_cp_by_outlet($outlet, $Form::site);
      if(!$e) {
        die "Cannot find cp for outlet " . $Form::outlet . "\n";
      }
      $q->param(-name=>'cp', -value=>$e);
      $Form::cp = $e;
    }
    if(!$Form::owner) {
      die "One or more required fields not filled in.\n";
    }
    
  #--- perform insert
  
    my $q_insert_cols = 'site';
    my $q_insert_vals = qq{'$Form::site'};
    $q_insert_cols .= ', cp';
    $q_insert_vals .= qq{, '$Form::cp'};
    $q_insert_cols .= ', valfrom' if $Form::valfrom;
    $q_insert_vals .= qq{, '$Form::valfrom'} if $Form::valfrom;
    $q_insert_cols .= ', valuntil' if $Form::valuntil;
    $q_insert_vals .= qq{, '$Form::valuntil'} if $Form::valuntil;
    $q_insert_cols .= ', owner';
    $q_insert_vals .= qq{, '$Form::owner'};
    $q_insert_cols .= ', descr' if $Form::descr;
    $q_insert_vals .= qq{, '$Form::descr'} if $Form::descr;
    $q_insert_cols .= ', creat_who';
    $q_insert_vals .= qq(, '$ENV{REMOTE_USER}');
    my $q_insert = qq{INSERT INTO permout ( $q_insert_cols ) VALUES ( $q_insert_vals )};
    my $sth = $dbh->prepare($q_insert);
    my $r = $sth->execute();
    if(!$r) {
      die "Cannot insert this entry (" . $sth->errstr() . ")\n";
    }
    
  #--- get OID of the inserted row
  
    my $sth = $dbh->prepare('SELECT oid FROM permout WHERE site = ? AND cp = ?');
    my $r = $sth->execute($Form::site, $Form::cp);
    ($highlight) = $sth->fetchrow_array() if $r;
    form_reset($q);
  }

  #------------------------------------------------------------------------
  #--- check for [reset] button being clicked -----------------------------
  #------------------------------------------------------------------------

  if($Form::reset) {
    form_reset($q);
  }

  #--- end of eval

  };
  if($@) {
    my $err = $@;
    chomp($err);
    print '<BIG STYLE="color : ', $errcol, '">', $err, "</BIG><P>&nbsp;</P>\n";
  }  

  #--- if there are URL parameters site+cp, fill in the rest from db
  
  my $url_site = $q->url_param('site');
  my $url_cp = $q->url_param('cp');
  if($url_site && $url_cp) {
    my $q_cols = 'permout.oid, outlet, owner, descr, valfrom, valuntil';
    my $q_from = 'permout JOIN out2cp USING ( site, cp )';
    my $q_where = qq{site = '$url_site' AND cp = '$url_cp'};
    my $q_select = "SELECT $q_cols FROM $q_from WHERE $q_where";
    if(!ref($dbh)) { die "Cannot connect to database\n"; }
    my $sth = $dbh->prepare($q_select);
    my $r = $sth->execute();
    if(!$r) { die "Database query failed (" . $sth->errstr() . ")\n"; }
    my @row = $sth->fetchrow_array();
    $highlight = $row[0];
    $q->param('outlet', $row[1]);
    $q->param('owner', $row[2]);
    $q->param('descr', $row[3]);
    $q->param('valfrom', $row[4]);
    $q->param('valuntil', $row[5]);
  }
  
  #--- display form

  my $su = $q->self_url;  
  $su =~ s/\?.*$//;
  print $q->startform(-action=>$su . '?form=permedit'), "\n\n<TABLE>\n";
  undef $su;

  print " <TR><TD>Site:</TD>";
  print "<TD>", $q->popup_menu(-name=>'site', -values=>sql_sites('out2cp'), -default=>'vin'), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Outlet:</TD>";
  print "<TD>", $q->textfield(-name=>'outlet', -size=>10, -maxlength=>10), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Cp:</TD>";
  print "<TD>", $q->textfield(-name=>'cp', -size=>10, -maxlength=>10), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Owner:</TD>";
  print "<TD>", $q->textfield(-name=>'owner', -size=>8, -maxlength=>8), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Description:</TD>";
  print "<TD>", $q->textfield(-name=>'descr', -size=>32, -maxlength=>64), "</TD>";
  print "</TR>\n";

  print " <TR><TD>Valid from:</TD>";
  print "<TD>", $q->textfield(-name=>'valfrom', -size=>10, -maxlength=>10),"</TD>";
  print "</TR>\n";

  print " <TR><TD>Valid until:</TD>";
  print "<TD>", $q->textfield(-name=>'valuntil', -size=>10, -maxlength=>10),"</TD>";
  print "</TR>\n";
  
  print " <TR><TD>&nbsp;</TD><TD></TD></TR>\n";
  print " <TR><TD>&nbsp;</TD><TD>";
  print $q->submit(-name=>'add', -value=>'Add'), "&nbsp;";
  print $q->submit(-name=>'update', -value=>'Update'), "&nbsp;";
  print $q->submit(-name=>'delete', -value=>'Delete'), "&nbsp;";
  print $q->submit(-name=>'reset', -value=>'Reset'), "</TD></TR>\n";

  print "</TABLE>\n", $q->endform, "\n\n<P>&nbsp;</P>\n\n";
  
  #--- retrieve and display listing from db
  
  eval {
    if(!ref($dbh)) { die "Cannot connect to database\n"; }
    my $q_cols = 'permout.oid, site, cp, outlet, valfrom::date, valuntil::date, owner, descr, creat_who, creat_when::date, chg_who, chg_when::date';
    my $query = "SELECT $q_cols FROM permout JOIN out2cp USING ( site, cp ) ";
    $query .= 'ORDER BY site, outlet';
    my $sth = $dbh->prepare($query);
    my $r = $sth->execute();
    if(!$r) {
      die "Database query failed (" . $sth->errstr() . ")\n";
    }

    my $i = 0;
    my $f_fnames = $sth->{NAME};
    my @f_rows;
    while(my @a = $sth->fetchrow_array()) {
      $f_rows[$i++] = \@a; 
    }  
    
    my $self_url = $q->self_url;
    $self_url =~ s/\?.*$//;
    if($highlight) {
      html_query_out($f_fnames, \@f_rows, 'eou', $highlight, $self_url . '?form=permedit;site=%s;cp=%s',
        ['site','cp'], 'Edit', undef
      );
    } else {
      my $ex = html_query_out($f_fnames, \@f_rows, 'eu', $self_url . '?form=permedit;site=%s;cp=%s',
        ['site','cp'], 'Edit', undef
      );
    }
  };
  if($@) {
    print qq{<P><SPAN CLASS="err">Error: $@</SPAN></P>\n};
  }
}


#===========================================================================
#=== main menu =============================================================
#===========================================================================

sub form_menu
{
  my $q = shift;
  my $self = $q->url(-relative=>1);

  http_header($q, 'Main Menu');
  html_header('Main Menu');
print <<EOHD;
<UL>
  <LI><A HREF="./">Switch List</A>
  <LI><A HREF="${self}?form=find">Search Tool</A>
  <LI><A HREF="${self}?form=menu">Database Manipulation</A>
  <UL>
    <LI><A HREF="${self}?form=add">Add patch(es)</A>
    <LI><A HREF="${self}?form=remove">Remove patch(es)</A>
    <LI><A HREF="${self}?form=hostadd">Add host(s)</A>
    <LI><A HREF="${self}?form=hostupd">Remove/update host(s)</A>
    <LI><A HREF="${self}?form=ppmap">Patch Panel Map</A>
    <LI><A HREF="${self}?form=permedit">Permanent Outlets</A>
  </UL>
</UL>
EOHD
}

#=== main =================================================================

my $q = new CGI;
$q->import_names('Form');

#--- find group associated with user

($e, $user_group) = sql_find_user_group($ENV{REMOTE_USER});

#--- check if user has debugging switched on

($e, $debug) = user_access_evaluate($ENV{REMOTE_USER}, 'debug');

$_ = $q->url_param("form");
MODESEL: {
  /^$/         && do { form_menu($q);        last MODESEL; };
  /^find$/     && do { form_find($q);        last MODESEL; };
  /^ppmap$/    && do { form_ppmap($q);       last MODESEL; };
  /^ppmap2$/   && do { form_ppmap2($q);      last MODESEL; };
  /^menu$/     && do { form_mmenu($q);       last MODESEL; };
  /^add$/      && do { form_add($q);         last MODESEL; };
  /^remove$/   && do { form_remove($q);      last MODESEL; };
  /^hostadd$/  && do { form_host_add($q);    last MODESEL; };
  /^hostupd$/  && do { form_host_update($q); last MODESEL; };
  /^permedit$/ && do { form_permedit($q);    last MODESEL; };
  /^swdetect$/ && do { form_swdetect($q);    last MODESEL; };
}

print $q->end_html;
$q->delete_all;
foreach (keys %Form::) { undef $Form::{$_}; }
undef $q;
