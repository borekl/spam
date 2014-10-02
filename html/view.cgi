#!/usr/bin/perl -I../

#==========================================================================
# view.cgi - a component of Switch Ports Activity Monitor
#==========================================================================

use CGI;
use SPAMv2;
use strict;
use integer;
use utf8;

#=== global variables =====================================================

my %db;                          # data pulled from database
my %views;                       # database queries
my %cache_time;                  # cache timeouts
my %formats;                     # output format strings
my %vfields;                     # views fields
my @known_hosts;                 # known hosts UGLY HACK
my $user_group = undef;          # current user's group
my %swclass;                     # switch groups


#=== settings =============================================================

$cache_time{hwinfo} = 600;       # cache timeout for hwinfo
$cache_time{switch} = 300;       # cache timeout for porttable
$cache_time{swlist} = 300;       # cache timeout for switch list
$cache_time{swlist1} = 300;      # cache timeout for switch list
$cache_time{hosts} = 300;        # cache timeout for hosttab
$cache_time{sites} = 3600;       # cache timeout for ondb:sites

$formats{switch} = '%12po %4du %4ra %5fl %3sd %3vl %8cp %8ou %9in %24de %12ho %8gr';
$formats{hosts} = '%16ho %8gr %8cp %8hn %6po %3vl %24de* %9hA %11hB %9hC %11hD';

$views{hwinfo} = 'SELECT n, partnum, sn FROM hwinfo WHERE host = ?';
$views{sites} = 'SELECT code, description FROM site';
$views{swusage} = 'SELECT s.portname, status, cp FROM status s LEFT JOIN porttable USING ( host, portname ) WHERE host = ?';
$views{switch} = <<EOHD;
SELECT
  portname, status, vlan, descr, duplex, rate, flags,
  cp, outlet, p.chg_who, p.chg_when, adminstatus, errdis,
  extract(epoch from (lastchk - lastchg)) AS inact,
  hostname, grpid, prodstat,
  EXISTS ( SELECT 1 FROM permout WHERE o.site = site AND o.cp = cp ) AS dont_age,
  ( SELECT count(mac) FROM mactable WHERE host = s.host and portname = s.portname AND active = 't') as maccnt
FROM status s
  FULL JOIN porttable p USING (host, portname)
  LEFT JOIN out2cp o USING (site, cp)
  LEFT JOIN hosttab h USING (site, cp)
WHERE s.host = ?
EOHD

$views{swlist} = <<EOHD;
SELECT
  host, location, ports_total, ports_active, ports_patched,
  ports_illact, ports_errdis, ports_inact, vtp_domain, vtp_mode,
  extract('epoch' from current_timestamp - chg_when) > 2592000 AS stale
FROM swstat
EOHD

$views{swlist1} = <<EOHD;
SELECT
  host, location, ports_total, ports_active, ports_patched,
  ports_illact, ports_errdis, ports_inact, vtp_domain, vtp_mode,
  boot_time, age(boot_time), chg_when, age(chg_when),
  ports_used
FROM swstat
WHERE host = ?
EOHD


# it is vital that 'hosts' view is ordered by 'hostname' field

$views{hosts} = <<EOHD;
SELECT
  site, cp, hostname, host, grpid, prodstat, portname, status,
  creat_who AS h_creat_who, creat_when AS h_creat_when,
  h.chg_who AS h_chg_who, h.chg_when AS h_chg_when, s.descr, s.vlan
FROM hosttab h
  LEFT JOIN porttable p USING (site, cp)
  LEFT JOIN status s USING (host, portname)
ORDER BY
  grpid ASC, hostname ASC
EOHD

#--- FIXME: list of "known" hosts

@known_hosts = qw(vins11c vins20c vins21c vins22c vins30c vins31c vins40c vins50c vins51c vins60c vins70c vdcs02c vdcs03c vdcs04c vdcs05c);

#--- switch classess

%swclass = ( 'all' => 'All', 'vin' => 'Vinice Floors', 'vdc' => 'Vinice DC',
             'str' => 'Středokluky', 'rcn' => 'Říčany', 'chr' => 'Chrudim', 'brr' => 'Brno',
             'bsc' => 'BSC', 'sho' => 'Shops', 'sto' => 'Stodůlky', 'err' => '!' );


#==========================================================================
# BEGIN block
#==========================================================================

BEGIN
{
  $| = 1;
  dbinit('spam', 'spam', 'swcgi', 'InvernessCorona', '172.20.113.118');
  dbinit('ondb', 'ondb', 'swcgi', 'InvernessCorona', '172.20.113.118');
}


#==========================================================================
# END block
#==========================================================================

END
{
  dbdone('spam');
}


#==========================================================================
# This function takes string 's' and length 'l' and either pads the string
# with spaces if it's shorter, or trims it if it's longer. The 'r' argument
# makes the padding go to the left, so the result is right aligned.
#==========================================================================

sub pad_or_cut
{
  my $s = shift;     # source string
  my $l = shift;     # length to pad or cut to
  my $r = shift;     # right align if true
  
  if(length($s) < $l) {
    if($r) {
      $s = (' ' x ($l - length($s))) . $s;
    } else {  
      $s .= ' ' x ($l - length($s));
    }
  } elsif(length($s) > $l) {
    $s = substr($s, 0, $l);
  }
  return $s;
}


#==========================================================================
# Wrap string with SPAN element, optinally with given CSS class.
#==========================================================================

sub html_span
{
  my $s = shift;
  my $class = shift;
  
  if($class) { return qq{<span class="$class">$s</span>} };
  return "<span>$s</span>";
}


#==========================================================================
# This function encapsulates the formating of all possible fields in
# outputs.
# 
# %po port      %vl vlan          %de description   %cx changed who
# %du duplex    %cp cp            %ho host          %nw network
# %ra rate      %ou outlet        %gr group         %dn dnsname
# %fl flags     %in inactivity    %cw changed when  %ip ip address
# %ma mac       %mf manufacturer  %hn hostname
# %hA hosttab.creat_who
# %hB hosttab.creat_when
# %hC hosttab.chg_who
# %hD hosttab.chg_when
#==========================================================================

sub field_formatter
{
  my $type = shift;
  my $len = shift;
  my $flag = shift;
  my $fv = shift;      # field-value hash, undefined means header label
  my $aux;
  
  SWITCH: {
    #--- po port
    if($type eq 'po') {
      if(!defined($fv)) { return pad_or_cut('port', $len); }
      $aux = $fv->{portname};
      $aux =~ s/^Ethernet/Eth/;
      $aux = pad_or_cut($aux, $len);
      if($fv->{errdis}) {
        $aux = html_span($aux, 'porterrdis');
      } elsif(defined($fv->{adminstatus}) && !$fv->{adminstatus}) {
        $aux = html_span($aux, 'portdis');
      } elsif($fv->{status}) {
        if($fv->{_host} && !$fv->{cp} && !$fv->{pf_cdp} && grep { $_ eq $fv->{_host} } @known_hosts) {
          $aux = html_span($aux, 'portup-illegal');
        } else {
          $aux = html_span($aux, 'portup');
        }
      } else {
        if(!$fv->{cp} && grep { $_ eq $fv->{_host} } @known_hosts) {
          $aux = html_span($aux, 'portdown-unpatched');
        } else {
          $aux = html_span($aux, 'portdown');
        }
      }
      return $aux;
      last SWITCH;
    }
    #--- du duplex
    if($type eq 'du') {
      if(!defined($fv)) { return pad_or_cut('duplex', $len); }
      if($fv->{status}) {
        if($fv->{duplex} == 2) {
          return html_span(pad_or_cut('full', $len), 'dplxfull');
        } elsif($fv->{duplex} == 1) {
          return html_span(pad_or_cut('half', $len), 'dplxhalf');
        }
      }
      return pad_or_cut('', $len);
      last SWITCH;
    }
    #--- ra rate
    if($type eq 'ra') {
      if(!defined($fv)) { return pad_or_cut('rate', $len); }
      $aux = $fv->{rate};
      if($aux eq '1000') { $aux = '1G'; }
      elsif($aux > '1000') { $aux = '10G'; }
      else { $aux .= 'M'; }
      if(!$fv->{status}) { $aux = ''; }
      return pad_or_cut($aux, $len, 1);
      last SWITCH;
    }
    #--- fl flags
    if($type eq 'fl') {
      if(!defined($fv)) { return pad_or_cut('flags', $len); }
      $aux = '<SPAN CLASS="flag-none">';
      # CDP
      $aux .= ($fv->{pf_cdp} ? html_span('C', 'flag-cdp') : '-');
      # portfast
      $aux .= ($fv->{pf_pfast} ? html_span('F', 'flag-pfast') : '-');
      # STP root
      $aux .= ($fv->{pf_stpr} ? html_span('R', 'flag-str') : '-');
      # trunk
      $aux .= ($fv->{pf_trd1q} && $fv->{status} ? html_span('q', 'flag-trunk') : '');
      $aux .= ($fv->{pf_trisl} && $fv->{status} ? html_span('i', 'flag-trunk') : '');
      $aux .= ($fv->{pf_trunk} && $fv->{status} ? html_span('?', 'flag-trunk') : '');
      $aux .= '-' if !$fv->{pf_tr} || !$fv->{status};
      # dot1x port-control
      $aux .= ($fv->{pf_dot1x_pc} == 1 ? html_span('x', 'flag-1xunauth') : '');
      $aux .= ($fv->{pf_dot1x_pc} == 3 ? html_span('x', 'flag-1xauth') : '');
      if($fv->{pf_dot1x_pc} == 2) {
        if($fv->{pf_dot1x_st} == 1) { # dot1x authorized
          $aux .= html_span('X', 'flag-1xauto1');
        } elsif($fv->{pf_dot1x_st} == 2) { #dot1x unauthorized
          if($fv->{pf_mab} == 4) { # MAB successful
            $aux .= html_span('X', 'flag-1xmab');
          } else {
            $aux .= html_span('X', 'flag-1xauto2');
          }
        } else {
          $aux .= html_span('X', 'flag-1xauto0');
        }
      }
      if(!$fv->{pf_dot1x_pc}) { $aux .= '-'; }
      #
      $aux .= '</span>';
      return $aux;
      last SWITCH;
    }
    #--- switch/hub detect
    if($type eq 'sd') {
      my $c;
      if(!defined($fv)) { return pad_or_cut('macs', $len); }
      $aux = $fv->{maccnt};
      if($aux == 0) { $aux = ''; }
      my $aux2 = pad_or_cut($aux, $len, 1);
      if($aux == 1) { $c = 'swdet-1'; }
      if($aux > 1) {
        $c = 'swdet-n'; 
        if($fv->{pf_pfast}) { $c = 'swdet-pf'; }
      }
      if($c) { $aux2 = qq{<span class="$c">$aux2</span>}; }
      return $aux2;
      last SWITCH;
    }
    #--- ma mac
    if($type eq 'ma') { last SWITCH; }
    #--- vl vlan
    if($type eq 'vl') {
      if(!defined($fv)) { return pad_or_cut('vlan', $len); }
      $aux = pad_or_cut($fv->{vlan}, $len, 1);
      if(!$fv->{cp}) { $aux = html_span($aux, 'gray') };
      return $aux;
      last SWITCH; 
    }
    #--- cp cp
    if($type eq 'cp') {
      if(!defined($fv)) { return pad_or_cut('cp', $len); }
      return pad_or_cut($fv->{cp}, $len);
      last SWITCH;
    }
    #--- ou outlet
    if($type eq 'ou') {
      if(!defined($fv)) { return pad_or_cut('outlet', $len); }
      return pad_or_cut($fv->{outlet}, $len);
      last SWITCH;
    }
    #--- in inactivity
    if($type eq 'in') {
      if(!defined($fv)) { return pad_or_cut('inactivity', $len); }
      if($fv->{status}) {
        $aux = pad_or_cut('', $len);
      } else {
        $aux = period($fv->{inact} >= 0 ? $fv->{inact} : 0);
        $aux = pad_or_cut($aux, $len, 1);
        if($fv->{dont_age}) {
          $aux = html_span($aux, 'dont-age');
        } elsif(!$fv->{cp}) {
          $aux = html_span($aux, 'gray');
        } elsif($fv->{inact} > 2592000) {
          $aux = html_span($aux, 'inactive3');
        } elsif($fv->{inact} > 86400) {
          $aux = html_span($aux, 'inactive2');
        } else {
          $aux = pad_or_cut('', $len);
        }
      }
      return $aux;
      last SWITCH;
    }
    #--- mf manufacturer
    if($type eq 'mf') { last SWITCH; }
    #--- de description
    if($type eq 'de') {
      if(!defined($fv)) { return pad_or_cut('description', $len); }
      $aux = pad_or_cut($fv->{descr}, $len);
      if($flag eq '*' && $fv->{descr})  {
        my $aux2 = $fv->{hostname};
        if($aux2 =~ /^[flsw]\d[a-z]{4}\d{2}.*/i) {
          $aux2 =~ s/^(.{8}).*/$1/;
        }
        if($aux2 =~ /^(sd|wh|ld|ff)\d{2}[a-z]{2}\d{2}.*/i) {
          $aux2 =~ s/^(.{8}).*/$1/;
        }
        if($aux !~ /$aux2/i) {
          $aux = html_span($aux, 'desc-mism');
        }
      }
      return $aux;
      last SWITCH;
    }
    #--- ho host
    if($type eq 'ho') {
      if(!defined($fv)) { return pad_or_cut('hostname', $len); }
      $aux = pad_or_cut($fv->{hostname}, $len);
      if($fv->{prodstat} == 1) {
        $aux = html_span($aux, 'prodstat-prod');
      } elsif($fv->{prodstat} == 2) {
        $aux = html_span($aux, 'prodstat-dev');
      } elsif($fv->{prodstat} == 3) {
        $aux = html_span($aux, 'prodstat-tst');
      } else {
        $aux = html_span($aux, 'prodstat-unk');
      }
      return $aux;
      last SWITCH;
    }
    #--- gr group
    if($type eq 'gr') {
      if(!defined($fv)) { return pad_or_cut('group', $len); }
      $aux = $fv->{grpid};
      return pad_or_cut($aux, $len);
      last SWITCH;
    }
    #--- hn hostname (switch
    if($type eq 'hn') {
      if(!defined($fv)) { return pad_or_cut('switch', $len); }
      $aux = $fv->{host};
      return pad_or_cut($aux, $len);
      last SWITCH;
    }
    #--- h1 hosttab creat_who
    if($type eq 'hA') {
      if(!defined($fv)) { return pad_or_cut('creat_who', $len); }
      $aux = $fv->{'h_creat_who'};
      return pad_or_cut($aux, $len);
      last SWITCH;
    }
    #--- h2 hosttab creat_when
    if($type eq 'hB') {
      if(!defined($fv)) { return pad_or_cut('creat_when', $len); }
      $aux = $fv->{'h_creat_when'};
      return pad_or_cut($aux, $len);
      last SWITCH;
    }
    #--- h3 hosttab chg_who
    if($type eq 'hC') {
      if(!defined($fv)) { return pad_or_cut('chg_who', $len); }
      $aux = $fv->{'h_chg_who'};
      return pad_or_cut($aux, $len);
      last SWITCH;
    }
    #--- h4 hosttab chg_when
    if($type eq 'hD') {
      if(!defined($fv)) { return pad_or_cut('chg_when', $len); }
      $aux = $fv->{'h_chg_when'};
      return pad_or_cut($aux, $len);
      last SWITCH;
    }
    #--- cw changed when
    if($type eq 'cw') { last SWITCH; }
    #--- cx changed by whom
    if($type eq 'cx') { last SWITCH; }
    #--- nw network
    if($type eq 'nw') { last SWITCH; }
    #--- dn dnsname
    if($type eq 'dn') { last SWITCH; }
    #--- ip ip address
    if($type eq 'ip') { last SWITCH; }
  }
}


#==========================================================================
#==========================================================================

sub html_row
{
  my $fv = shift;
  my $format = shift;
  my $result = '';
  
  my @fields = split(/\s+/, $formats{$format});
  for my $k (@fields) {
    $k =~ /^%(\d+)([A-Za-z]+)(.*)$/;
    my ($flen, $fcode, $fflg) = ($1, $2, $3);
    next if !$flen;
    $result .= ' ' . field_formatter($fcode, $flen, $fflg, $fv) . ' ';
  }
  return $result;
}

sub get_format_len
{
  my $format = shift;
  my $tlen = 0;
  
  my @fields = split(/\s+/, $formats{$format});
  for my $k (@fields) {
    $k =~ /^%(\d+)[a-z]+.*$/;
    $tlen += $1 + 2;
  }
  return $tlen;
}


#==========================================================================
# Function for loading tables from database with caching.
# 
# Arguments: 1. argument to SQL query
#            2. view (which SQL query to execute)
#            3. 1 - load into array instead of hash
#            4. database binding (default is 'spam')
#            5. force reload
#==========================================================================

sub sql_load_cached
{
  my $host = shift;
  my $view = shift;
  my $load_into_array = shift;
  my $db_bind = shift;
  my $reload = shift;

  if(!$db_bind) { $db_bind = 'spam'; }
  
  #--- check cache
  
  if(exists $db{$host}{$view}{_tm} && !$reload) {
    my $then = $db{$host}{$view}{_tm};
    my $now = time();
    my $ct = $cache_time{$view};
    if(($then + $ct) > $now) {
      return $db{$host}{$view};
    }
  }
  delete $db{$host}{$view};
  
  #--- ensure database connection

  my $dbh = dbconn($db_bind);
  if(!ref($dbh)) { return "Cannot connect to database ($dbh)"; }

  #--- load data

  my $sth = $dbh->prepare($views{$view});
  if($host eq '_nohost') {
    $sth->execute() || return 'Cannot query database (' . $sth->errstr . ')';  
  } else {
    $sth->execute($host) || return 'Cannot query database (' . $sth->errstr . ')';  
  }
  my $i = 0;
  while(my @a = $sth->fetchrow_array()) {
    my $key = $a[0];
    if($load_into_array) {
      $db{$host}{$view}{_array}[$i] = \@a;
    } else {
      $a[0] = $i;
      $db{$host}{$view}{$key} = \@a;
    }
    $i++;
  }
  if($sth->err) {
    delete $db{$host}{$view};
    return $sth->errstr;
  }
  $db{$host}{$view}{_n} = $i;
  $db{$host}{$view}{_host} = $host;
  $db{$host}{$view}{_tm} = time();
  return $db{$host}{$view};
}


#==========================================================================
# Parses SQL selects and discovers what fields they contain. Results of
# this function are cached in global variable $vfields.
#==========================================================================

sub sql_get_fields
{
  my $view = shift;
  my %result;
  my $i = 0;

  if(exists $vfields{$view}) { return $vfields{$view}; }
  $views{$view} =~ /SELECT\s+(.*)\s+FROM/is;
  my $fields = $1;
  my @fields = split(/\s*,\s*/, $fields);
  for my $k (@fields) {
    if($k =~ /\sas\s+([a-z_]+)$/i) { 
      $result{$1} = $i++;
    } else {
      $k =~ /\s?([a-z_]+)$/i;
      $result{$1} = $i++;
    }
  }
  $vfields{$view} = \%result;
  return \%result;
}


#==========================================================================
# For given $key in $data using $view creates field -> value hash
#==========================================================================

sub field_value_hash
{
  my $data = shift;
  my $key = shift;
  my $view = shift;
  my %result;
  
  my $gf = sql_get_fields($view);
  for my $k (keys %$gf) {
    if(exists $data->{_array}) {
      $result{$k} = $data->{_array}[$key][$gf->{$k}];
    } else {
      if($gf->{$k} == 0) {
        $result{$k} = $key;
      } else {
        $result{$k} = $data->{$key}[$gf->{$k}];
      }
    }
  }
  if($data->{_host}) { $result{_host} = $data->{_host}; }
  return \%result;
}


#==========================================================================
#==========================================================================

sub port_flag_unpack
{
  my $fv = shift;
  my $n;
  
  return if !exists $fv->{flags};
  $n = $fv->{flags};
  if($n & 1) { $fv->{pf_cdp} = 1; }
  if($n & 2) { $fv->{pf_pfast} = 1; }
  if($n & 4) { $fv->{pf_stpr} = 1; }
  if($n & 8) { $fv->{pf_trd1q} = 1; }
  if($n & 16) { $fv->{pf_trisl} = 1; }
  if($n & 32) { $fv->{pf_trunk} = 1; }
  if($n & (8+16+32)) { $fv->{pf_tr} = 1; }
  if($n & 128) { $fv->{pf_dot1x_pc} = 1; }
  if($n & 256) { $fv->{pf_dot1x_pc} = 2; }
  if($n & 64) { $fv->{pf_dot1x_pc} = 3; }
  if($n & 512) { $fv->{pf_dot1x_st} = 1; }
  if($n & 1024) { $fv->{pf_dot1x_st} = 2; }
  if($n & 2048) { $fv->{pf_mab} = 4; }
  return;
}


#==========================================================================
#==========================================================================

sub format_shop_location
{
  my $l = shift;
  my $ret = $l;
    
  if($l =~ /^(.*);(.*);(.*);Shop ([A-Z].*);(.*);(.*);(.*)$/) {
    my ($sh_site, $sh_coord_lat, $sh_coord_long, $sh_id, $sh_loc, $sh_street, $sh_venue)
      = ($1, $2, $3, $4, $5, $6, $7);
    my $url = 'http://www.mapy.cz/#x=@y=@z=@mm=@sa=@st=s@ssq=' . $sh_coord_lat . '%20' . $sh_coord_long;
    if($sh_venue eq 'x') { $sh_venue = undef; }
    $sh_loc =~ s/\s+\d+$//;
    $ret = "$sh_id $sh_loc";
    $ret .= " $sh_venue, " if $sh_venue;
    $ret .= ', ' if !$sh_venue;
    $ret .= "$sh_street";
    $ret = qq{<a target="_main" class="shoplnk" href="$url">$ret</a>} if $url;
  }
  return $ret;
}


#==========================================================================
#==========================================================================

sub format_generic_location
{
  my $l = shift;
  my $ret = $l;

  if($l =~ /^(.*);(.*);(.*);(.*);(.*);(.*);(.*)$/) {
    my ($sh_site, $sh_coord_lat, $sh_coord_long, $sh_id, $sh_loc, $sh_street, $sh_venue)
      = ($1, $2, $3, $4, $5, $6, $7);
    if($sh_venue eq 'x') { 
      $ret = "$sh_id, $sh_loc, $sh_street";
    } else {
      $ret = "$sh_id, $sh_loc, $sh_street, $sh_venue";
    }
  }
  
  return $ret;
}



#==========================================================================
# Switch List
#==========================================================================

sub html_view_swlist
{
  my $result;
  my $e;
  my @grps;
  my $err_grp = 0;
  
  #--- switch groups to be processed
  # 'err' is special pseudo-group of switches, where error condition
  # was detected (at the moment, only 'stale' condition); 'err' is only
  # display to users with 'debug' token.
    
  @grps = qw(all vin vdc rcn str sto chr brr sho bsc);
  push(@grps, 'err') if user_access_evaluate($ENV{REMOTE_USER}, 'debug');

  #--- start HTML
  
  $result = html_header('Switch List');
  
  #--- load swstat table
  
  $e = sql_load_cached('_nohost', 'swlist');
  if(!ref($e)) { return $e; }
  my $swlist = $e;

  #--- are there any switches in 'err' pseudo-group?
  
  eval {
  if(grep(/^err$/, @grps)) {
    for my $k (keys %$swlist) {
      next if $k =~ /^_/;
      my $fv = field_value_hash($swlist, $k, 'swlist');
      if($fv->{stale}) {
        $err_grp = 1;
        last;
      }
    }
  }
  };
  print $@;
  if(!$err_grp) {
    foreach my $i (0 .. $#grps) {
      if($grps[$i] eq 'err') {
        delete $grps[$i];
        last;
      }
    }
  }
  
  #--- group menu

  $result .= qq{\n<div class="swlist_grpsel">\n};
  for my $k (@grps) {
    my $label = $swclass{$k};
    if($label eq '!') { $label = '<span class="swlist_stale">!</span>'; }
    $result .= qq[<span class="swlist_grpsel0" id="mentry_$k" onClick="grp_sel('$k');">$label</span>\n];
  }
  $result .= "</div>\n";
  
  #--- iterate over switch classes
  
  for my $swc (@grps) {

  #--- containing DIV element; by default only "all" group is visible
  
    if($swc eq 'all') {
      $result .= qq{\n<div id="tabdiv_$swc">\n\n};
    } else {
      $result .= qq{\n<div id="tabdiv_$swc" style="display : none">\n\n};
    }
    
  #--- table head
  
    $result .= <<EOHD;
<table cellpadding=5 cellspacing=0 align=center>
  
<tr class="h">
  <th rowspan=2>device</th>
  <th rowspan=2>VTP<BR>domain</th>
  <th rowspan=2>location</th>
  <th colspan=5 style="letter-spacing : .5em">ports</th>
</tr>
<tr class="h">
   <th>total</th><th>patched</th><th>active</th><th>unreg</th><th>errdis</th>
</tr>
EOHD
  
  #--- make sorted list of switches, filter out those not in current
  #--- switch group ("class")

    my @keys;
    for my $k (sort keys %$swlist) {
      next if $k =~ /^_/;
      next if ($swc eq 'vin' && $k !~ /^vin/);
      next if ($swc eq 'vdc' && $k !~ /^vdc/);
      next if ($swc eq 'rcn' && $k !~ /^(ric|rcn)/);
      next if ($swc eq 'str' && $k !~ /^str/);
      next if ($swc eq 'sto' && $k !~ /^sto/);
      next if ($swc eq 'chr' && $k !~ /^chr/);
      next if ($swc eq 'brr' && $k !~ /^brr/);
      next if ($swc eq 'bsc' && $k !~ /^bsc/);
      my $fv = field_value_hash($swlist, $k, 'swlist');
      next if ($swc eq 'err' && !$fv->{stale});
      my $loc = $fv->{location};
      next if ($swc eq 'sho' && $loc !~ /Shop/i);
      push(@keys, $k);
    }
  
  #--- output
  
    my $cl = 'a';
    my %sum;
    for my $k (sort @keys) {
      no integer;
      my $fv = field_value_hash($swlist, $k, 'swlist');
      $result .= qq{<tr class="$cl">\n};
      my ($aux, $aux2);
      #--- host
      $aux = $fv->{host};
      $aux2 = $fv->{stale};
      if($aux2) {
        $result .= qq{  <td><A href="view.cgi?view=switch&host=$aux">$aux</a>&nbsp;<span class="swlist_stale">!</span></td>\n};
      } else {
        $result .= qq{  <td><a href="view.cgi?view=switch&host=$aux">$aux</a></td>\n};
      }
      #--- VTP domain
      $aux = str_maxlen($fv->{vtp_domain}, 10);
      if($fv->{vtp_mode} == 2) {
        $result .= qq{  <td><b>$aux</b></td>\n};
      } else {
        $result .= qq{  <td>$aux</td>\n};
      }  
      #--- location
      if($swc eq 'sho' || $swc eq 'all') {
        $aux = format_shop_location($fv->{location});
      } else {
        $aux = format_generic_location($fv->{location});
      }
      $result .= qq{  <td>$aux</td>\n};
      #--- ports total
      $aux = $fv->{ports_total};
      $sum{total} += $aux;
      $result .= qq{  <td align=right>$aux</td>\n};
      #--- ports patched
      $aux = $fv->{ports_patched};
      $sum{patched} += $aux;
      if($fv->{ports_total}) {
        $aux2 = sprintf("%0.0f", ($aux / $fv->{ports_total}) * 100);
        $aux2 = html_span("$aux2%", 'percent');
      } else {
        $aux2 = '';
      }
      $result .= qq{  <td align=right>$aux $aux2</td>\n};
      #--- ports active
      $aux = $fv->{ports_active};
      $sum{active} += $aux;
      if($fv->{ports_total}) {
        $aux2 = sprintf("%0.0f", ($aux / $fv->{ports_total}) * 100);
        $aux2 = html_span("$aux2%", 'percent');
      } else {
        $aux2 = '';
      }
      $result .= qq{  <td align=right>$aux $aux2</td>\n};
      #--- ports unregistered
      $aux = $fv->{ports_illact};
      $aux = html_span($aux, 'unreg') if $aux > 0;
      $result .= qq{  <td align=right>$aux</td>\n};
      #--- ports errdisabled
      $aux = $fv->{ports_errdis};
      $aux = html_span($aux, 'errdis') if $aux > 0;
      $result .= qq{  <td align=right>$aux</td>\n};

      $result .= "</tr>\n";
      $cl = ($cl eq 'a' ? 'b' : 'a');
    }

  #--- summary

    $result .= <<EOHD;
<tr class="summary">
  <td colspan=3 style="letter-spacing : 0.2em">Summary</td>
  <td align=right>$sum{total}</td>
  <td align=right>$sum{patched}</td>
  <td align=right>$sum{active}</td>
  <td colspan=2>&nbsp;</td> 
</tr>
EOHD
  
  #--- finish

    $result .= <<EOHD;
<tr class="legend">
  <td>
    total<br>
    patched<br>
    active<br>
    unreg<br>
    errdis
  </td>
  <td colspan=6>
    ports physically available on switch<br>
    ports connected to outlet<br>
    ports with link active<br>
    active ports that were not entered into database<br>
    ports disabled because of excessive errors
  </td>
</tr>
</table>
EOHD

  #--- division close
  
    $result .= "\n</DIV>\n\n";
  }
  
  #---
  
  return \$result;
}


#==========================================================================
# Generates standard switch view (in a manner similar to that of spam.pl).
#
# Argument: 1. host
# Returns:  1. error message or string scalar reference with the complete
#              HTML page (the inside of BODY)
#==========================================================================

sub html_view_switch
{
  my $host = shift;
  my $result;
  my $e;
  my $cmp_flag = 0;
  
  $result = html_header("Port list for <EM>$host</EM>", 'LEFT');
  
  #--- load modules info

  $e = sql_load_cached($host, 'hwinfo');
  if(!ref($e)) { return $e }
  my $modstat = $e;
  if($modstat->{_n} == 0) { $cmp_flag = 1; }
  
  #--- load status, porttable, out2cp and permout info

  $e = sql_load_cached($host, 'switch');
  if(!ref($e)) { return $e }
  my $switch = $e;

  #--- load swstat table
  
  $e = sql_load_cached($host, 'swlist1');
  if(!ref($e)) { return $e; }
  my $swstat = $e;
  
  #--- extra information
  
  $result .= "<PRE>\n";
  { 
    my $p_total = $swstat->{$host}[2];
    my $p_active = $swstat->{$host}[3];
    my $p_unreg = $swstat->{$host}[5];
    my $p_used = $swstat->{$host}[14];
    my $age = $swstat->{$host}[11];
    my $lastcheck = $swstat->{$host}[12];
    my $lastcheckage = $swstat->{$host}[13];
    my $known = grep(/$host/, @known_hosts);
    $lastcheck =~ s/\..*$//;
    if($lastcheckage =~ /^-/) { $lastcheckage = undef; }
    $age =~ s/ (\d\d):(\d\d):(\d\d)$//;
    $lastcheckage =~ s/\.\d+$//;
    $result .= sprintf("Location:     %s\n", format_generic_location($swstat->{$host}[1]));
    $result .= sprintf("Total ports:  %d\n", $p_total);
    $result .= sprintf("Active ports: %d (%d %%)\n", $p_active, $p_active * 100 / $p_total);
    $result .= sprintf("Used ports:   %d (%d %%)\n", $p_used, $p_used * 100 / $p_total) if $known;
    $result .= sprintf("Unused ports: %d (%d %%)\n", $p_total - $p_used, ($p_total - $p_used) * 100 / $p_total) if $known;
    $result .= sprintf("Unreg. ports: %d\n", $p_unreg) if $p_unreg;
    $result .= sprintf("Boot time:    %s (%s ago)\n", $swstat->{$host}[10], $age);
    $result .= sprintf("Last check:   %s", $lastcheck);
    $result .= sprintf(" (%s ago)", $lastcheckage) if $lastcheckage;
    $result .= "\n";
  }
  $result .= "\n";
  
  #--- output
  
  my $f = 'a';
  my $mod;
  $result .= html_span(html_row(undef, 'switch'), 'hdr') . "\n";
  my @swkeys;
  for my $k (keys %$switch) {
    next if $k =~ /^_/;
    push(@swkeys, $k);
  }
  for my $k (sort { compare_ports($a, $b, $cmp_flag) } @swkeys) {
    
    #--- module processing
    
    if($modstat->{_n}) {
      $k =~ /(\d+)\/\d+$/;
      my $n = $1;
      if($mod != $n) {
        if(exists $modstat->{$n}) {
          my $aux = sprintf(" %d. %s (%s)", $n, $modstat->{$n}[1], $modstat->{$n}[2]);
          $aux = pad_or_cut($aux, get_format_len('switch'));
          $aux = html_span($aux, 'modhdr');
          $result .= $aux . "\n";
        }
        $mod = $n;
      }
    }
    
    #--- skip if module doesn't exist
    # Cisco seems to return ports from removed modules as if they still
    # existed and there's no way to tell them apart from real ports.
    # (Observed with Cisco Catalyst 6500 switch).
    
    next if $mod && !exists $modstat->{$mod};
    
    #--- regular rows
    
    my $fv = field_value_hash($switch, $k, 'switch');
    port_flag_unpack($fv);
    my $row = html_row($fv, 'switch');
    $row = html_span($row, $f);
    $f = ($f eq 'a' ? 'b' : 'a');
    $result .= "$row\n";
  }
  
  $result .= <<EOHD;


<u>Flags legend</u>                                                <u>Hostname status legend</u>

<b>col chr description</b>                                         <b>colour  status</b>
 1   <SPAN CLASS="flag-cdp">C</SPAN>  Port receives CDP packets                           <span class="prodstat-prod">green</span>   production
 2   <SPAN CLASS="flag-pfast">F</SPAN>  Spanning tree fast start enabled                    <span class="prodstat-dev">blue</span>    development
 3   <SPAN CLASS="flag-str">R</SPAN>  Port is spanning tree root port                     <span class="prodstat-tst">gray</span>    testing
 4   <SPAN CLASS="flag-trunk">q</SPAN>  Port is in 802.1q trunking mode                     <span class="prodstat-unk">red</span>     unknown status
     <SPAN CLASS="flag-trunk">i</SPAN>  Port is in ISL trunking mode
     <SPAN CLASS="flag-trunk">?</SPAN>  Port is in unknown/other trunking mode
 5   <span class="flag-1xauto0">X</span>  Port is in dot1x auto mode
     <span class="flag-1xauto1">X</span>  Port is in dot1x auto mode, authorized
     <span class="flag-1xauto2">X</span>  Port is in dot1x auto mode, unauthorized
     <span class="flag-1xmab">X</span>  Port is in dot1x auto mode, MAC bypass active
     <span class="flag-1xauth">x</span>  Port is in dot1x force-authorized mode
     <span class="flag-1xunauth">x</span>  Port is in dot1x force-unauthorized mode
</PRE>

EOHD
  
  #--- return;
  
  return \$result;
}


#==========================================================================
#==========================================================================

sub html_view_hosts
{
  my $grpid = shift;
  my $e;
  my $hosttab;
  my $result;
  my $n;
  my $grphdr;
  
  #--- check user's authorization
  
  if(!user_access_evaluate($ENV{REMOTE_USER}, 'hosttabview')) {
    return auth_err('hosttabview', 0);
  }
  
  #--- arguments handling
  
  if(!$grpid) { 
    if($user_group) { $grpid = $user_group; }
  } else {
    if($grpid eq 'all') { $grpid = ''; }
  }
  
  #--- load data
  
  $e = sql_load_cached('_nohost', 'hosts', 1);
  if(!ref($e)) { return $e; }
  my $hosttab = $e;

  #--- output

  if($grpid) {
    $result = html_header("Hosts list for group <EM>$grpid</EM>", 'LEFT');
  } else {
    $result = html_header('Hosts list', 'LEFT'); 
  }
  $result .= "<PRE>\n";
  $n = scalar(@{$hosttab->{_array}});
  $result .= html_span(html_row(undef, 'hosts'), 'hdr') . "\n";
  my $cl = 'a';
  for(my $i = 0; $i < $n; $i++) {
    my $fv = field_value_hash($hosttab, $i, 'hosts');
    if($grphdr ne $fv->{grpid} && !$grpid) {
      my $aux;
      $grphdr = $fv->{grpid};
      if(!$grphdr) {
        $aux = ' no group assigned';
      } else {
        $aux = sprintf(" %s", $grphdr);
      }
      $aux = pad_or_cut($aux, get_format_len('hosts'));
      $aux = html_span($aux, 'modhdr');
      $result .= "$aux\n";
    }
    if(($grpid && $fv->{grpid} eq $grpid) || !$grpid) {
      $result .= html_span(html_row($fv, 'hosts'), $cl);
      $cl = $cl eq 'a' ? 'b' : 'a';
      $result .= "\n";
    }
  }
  $result .= <<EOHD;
  
<U>Hostname status legend</U>

<B>colour  status</B>
<SPAN CLASS="prodstat-prod">green</SPAN>   production
<SPAN CLASS="prodstat-dev">blue</SPAN>    development
<SPAN CLASS="prodstat-tst">gray</SPAN>    testing
<SPAN CLASS="prodstat-unk">red</SPAN>     unknown status
</PRE>
EOHD
  
  return \$result;
}



#===========================================================================
# Report for checking that redundantly connected hosts are connected
# to different switches. This function RELIES on view "hosts" being
# sorted by hostname.
#===========================================================================

sub html_view_redundancy
{
  my $grpid = shift;
  my $result;
  my $e;
  my @rhosts;       # redundant hosts
  
  #--- check user's authorization
  
  if(!user_access_evaluate($ENV{REMOTE_USER}, 'hosttabview')) {
    return auth_err('hosttabview', 0);
  }

  #--- arguments handling
  
  if(!$grpid) { 
    if($user_group) { $grpid = $user_group; }
  } else {
    if($grpid eq 'all') { $grpid = ''; }
  }

  #--- load data
  
  $e = sql_load_cached('_nohost', 'hosts', 1);
  if(!ref($e)) { return $e; }
  my $hosttab = $e;

  #--- header

  if($grpid) {
    $result = html_header("Host redundancy check for group <EM>$grpid</EM>", 'LEFT');
  } else {
    $result = html_header('Host redundancy check', 'LEFT'); 
  }

  #--- iterate over hosts
  
  my $ha = $hosttab->{_array};
  my $n = scalar(@$ha);
  my $host_prev;  
  
  for(my $i = 0; $i < $n; $i++) {
    next if ($ha->[$i][4] ne $grpid) && ($grpid);
    my $host_curr = $ha->[$i][2];    # current hostname
    my $host_root;                   # unsuffixed hostname

    #--- previous host ends with 'a' -> possible first interface hostname

    if($host_prev =~ /(.*)a$/) {
      $host_root = $1;
    }

    #--- previous host ends with 'a' and current ends with 'b'
    #--- means we're seeing two interfaces of the same host
    
    if($host_root && $host_curr =~ /${host_root}b$/) {
      push(@rhosts, [ $host_root, 1, $i - 1 ]);
      $host_prev = undef;


    #--- previous host is the same as current one
    #--- means dual-homed server

    } elsif($host_prev eq $host_curr) {
      push(@rhosts, [ $host_curr, 0, $i - 1 ]);
      $host_prev = undef;

    #--- no redundancy found
    
    } else {
      $host_prev = $host_curr;
    }
  }  

  #--- output results
  
  $result .= "<PRE>\n";
  $result .= html_span(html_row(undef, 'hosts'), 'hdr') . "\n\n";

  for my $k (@rhosts) {
    my $fv1 = field_value_hash($hosttab, $k->[2], 'hosts');
    my $fv2 = field_value_hash($hosttab, $k->[2] + 1, 'hosts');

    #--- [3] host, [13] vlan    
    my $sw1 = $ha->[$k->[2]][3];
    my $sw2 = $ha->[$k->[2] + 1][3];
    my $vl1 = $ha->[$k->[2]][13];
    my $vl2 = $ha->[$k->[2] + 1][13];
    my ($msg, $msg_class);
    my $l;

    if(!$sw1 || !$sw2) {
      $msg = 'UNKNOWN'; $msg_class = 'redunkn';
    } elsif((lc($sw1) eq lc($sw2)) || ($vl1 != $vl2)) {
      $msg = 'FAIL'; $msg_class = 'redfail';
    } else {
      $msg = 'OK'; $msg_class = 'redok';
    }
    $l = length($k->[0]) + length($msg) + 1;

    $msg = html_span($msg, $msg_class);
    my $host_top = html_span($k->[0], 'redhost');
    $result .= html_span(" $host_top $msg" . (' ' x (get_format_len('hosts') - $l - 1)), 'redbkg') . "\n";
    $result .= html_row($fv1, 'hosts') . "\n";
    $result .= html_row($fv2, 'hosts') . "\n\n";
  }
  $result .= "</PRE>\n";
  
  return \$result;
}


#===========================================================================
# HTML heading
#===========================================================================

sub html_header
{
  my ($title, $align) = @_;
  my $user = $user_group;
  my $r;
  
  if(!$align) { $align = 'center'; }
  if(!$user) { $user = '?'; }
  $r = sprintf(qq{<p class="loginf">Logged as: <span class="loginfhlt">%s</span> / <span class="loginfhlt">%s</span></p>\n}, $ENV{REMOTE_USER}, $user);
  $r .= "<h1 align=$align>${title}</h1>\n" if $title;
  return $r;
}

#============================================================================
# HTML "HEAD" section and HTTP header
#============================================================================


sub html_start
{
  my $js = shift;       # link js code
  
print <<EOHD;
Content-type: text/html; charset=utf-8

<!doctype html>

<html>

<head>
  <title>view.cgi</title>
  <link rel=stylesheet type="text/css" href="default.css">
  <link rel=stylesheet type="text/css" href="flags.css">
EOHD
  if($js) {
    for(@$js) {
      print qq{  <script type="text/javascript" src="$_"></script>\n};
    }
  }
  print "</head>\n\n";
  print "<body>\n\n";
}


#===========================================================================
# Authentication/authorization violation message
#===========================================================================

sub auth_err
{
  my ($access, $err) = @_;
  my $r;
  
  $r = html_header('Access denied');
  if($err) {
    $r .= "<p>An error occured during authorization: $err</p>\n";
  } else {
    $r .= "<p>Access token <b>$access</b> requested, but denied for user ";
    $r .= "<b>$ENV{REMOTE_USER}</b>\n";
  }
}


#==========================================================================
#                   _
#   _ __ ___   __ _(_)_ __
#  | '_ ` _ \ / _` | | '_ \
#  | | | | | | (_| | | | | |
#  |_| |_| |_|\__,_|_|_| |_|
#
#==========================================================================


my $q = new CGI;
my $host = $q->url_param('host');
my $view = $q->url_param('view');
my $e;

($e, $user_group) = sql_find_user_group($ENV{REMOTE_USER});

MAINSW: {

  #--- swlist

  $view eq 'swlist' && do {
    html_start(['jquery.js','jquery.cookie.js','swlistmnu.js']);
    my $s = html_view_swlist();
    if(!ref($s)) {
      print "<P>Error occured ($s)</P>\n";
    } else {
     print $$s;
    }
    last MAINSW;
  };

  #--- switch

  $view eq 'switch' && do {
    html_start();
    my $s = html_view_switch($host);
    if(!ref($s)) {
      print "<P>Error occured ($s)</P>\n";
    } else {
     print $$s;
    }
    last MAINSW;
  };

  #--- hosts
  
  $view eq 'hosts' && do {
    html_start();
    my $grpid = $q->url_param('grpid');
    my $s = html_view_hosts($grpid);
    if(!ref($s)) {
      print "<P>Error occured ($s)</P>\n";
    } else {
     print $$s;
    }
    last MAINSW;
  };

  #--- host redundancy check

  $view eq 'redundancy' && do  {
    html_start();
    my $grpid = $q->url_param('grpid');
    my $s = html_view_redundancy($grpid);
    if(!ref($s)) {
      print "<P>Error occured ($s)</P>\n";
    } else {
     print $$s;
    }
    last MAINSW;
  };
  
  do {
    print "<P>Arguments missing</P>\n";
  };
}


print "</body>\n";
print "</html>\n";
