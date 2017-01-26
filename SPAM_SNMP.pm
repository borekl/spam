#!/usr/bin/perl

#===========================================================================
# Switch Ports Activity Monitor -- SNMP support library
# """""""""""""""""""""""""""""
# 2000 Borek Lupomesky <Borek.Lupomesky@oskarmobil.cz>
#===========================================================================


package SPAM_SNMP;
require Exporter;
use SPAMv2 qw(load_config file_lineread);
use Data::Dumper;

use integer;

@ISA = qw(Exporter);
@EXPORT = qw(
  snmp_entity_to_hwinfo
  snmp_system_info
  snmp_get_arptable
  snmp_get_tree
  snmp_get_object
);


#==========================================================================
# Assemble SNMP command from supplied arguments.
#==========================================================================

sub snmp_command
{
  #--- argument and variables

  my ($command, $host, $community, $mibs, $root) = @_;
  my $cfg = load_config();

  #--- return if no config

  return undef if !ref($cfg);

  #--- return if non-existent command

  return undef if !exists($cfg->{'snmp'}{$command});
  my $cmd = join(' ',
    ( $cfg->{'snmp'}{$command}{'exec'},
    $cfg->{'snmp'}{$command}{'options'} )
  );

  #--- regularize MIBs list to always be an arrayref
  #--- note: at least one MIB must be passed in!

  if($mibs && !ref($mibs)) { $mibs = [ $mibs ]; }

  #--- stringify MIB list

  my $miblist = join(':', @$mibs);

  #--- tokens replacements

  $cmd =~ s/%c/$community/;
  $cmd =~ s/%h/$host/;
  $cmd =~ s/%r/$root/;
  $cmd =~ s/%m/+$miblist/;

  #--- finish

  return $cmd;
}


#==========================================================================
# Read SNMP command's output line by line.
#==========================================================================

sub snmp_lineread
{
  #--- argument and variables

  my @args = splice(@_, 0, 5);
  my $fn = shift;

  #--- prepare command

  my $cmd = snmp_command(@args);
  if(!$cmd) { return 'Failed to prepare SNMP command'; }

  #--- perform the read and finish

  return file_lineread($cmd, '-|', $fn);
}


#===========================================================================
# Get SNMPv2-MIB system tree; this contains some essential info about the
# SNMP host incl. platform, uptime, location etc.
#
# Arguments: 1. host
#            2. community
# Returns:   1. SNMP tree (hashref) or error string
#            2. platform string from sysObjectID
#            3. system uptime converted into UNIX epoch format
#===========================================================================

sub snmp_system_info
{
  my ($host, $community) = @_;
  my $cfg = load_config();

  #--- the SNMPv2-MIB::system tree

  my $r = snmp_get_tree(
    'snmpwalk',
    $host,
    $community,
    $cfg->{'snmp'}{'system'}{'mib'},
    $cfg->{'snmp'}{'system'}{'entries'}[0],
  );

  #--- process the output

  if(!ref($r)) {
    return $r;
  } else {

  #--- strip the MIB from the left-side

    my $sysobjid = $r->{'sysObjectID'}{0}{'value'};
    $sysobjid =~ s/^.*:://;

  #--- convert uptime time-ticks to UNIX epoch value

    my $sysuptime = $r->{'sysUpTimeInstance'}{'value'};
    $sysuptime = time() - int($sysuptime / 100);
    return ($r, $sysobjid, $sysuptime);
  }
}


#===========================================================================
# Retrieve ARP entries from list of routers. It returns mac->ip address hash
# reference. The optional callback is there to facilitate caller-side
# progress info display; arguments are: 1. number of arp servers, 2. number
# of currently processed entry, 3. name of currently processed server.
#===========================================================================

sub snmp_get_arptable
{
  #--- arguments

  my (
    $arpdef,     # 1. arp servers list in form [ host, community ]
    $def_cmty,   # 2. default SNMP community
    $cb          # 3. callback (optional)
  ) = @_;

  #--- other variables

  my %tree;
  my %arptable;
  my $cfg = load_config();

  #-------------------------------------------------------------------------
  #--- read the relevant MIB sections --------------------------------------
  #-------------------------------------------------------------------------

  for my $arp_source (@$arpdef) {
    my $r;

  #--- SNMP community, either default or per-server

    my $cmty = $arp_source->[1] // $def_cmty;
    $tree{$arp_source->[0]} = {};

  #--- read the MIB tree

    for my $tree_root (@{$cfg->{'snmp'}{'arptable'}{'entries'}}) {
      $r = snmp_get_tree(
        'snmpwalk',
        $arp_source->[0],
        $cmty,
        $cfg->{'snmp'}{'arptable'}{'mib'},
        $tree_root
      );

  #--- handle the result

      if(!ref($r)) {
        die sprintf("failed to get arptable from %s (%s)", $arp_source->[0], $r);
      } else {
        my $t = $tree{$arp_source->[0]};
        %$t = ( %$t, %$r );
      }
    }

  #--- display message through callback

    if($cb) {
      $cb->($arp_source->[0]);
    }
  }

  #-------------------------------------------------------------------------
  #--- transform the data int the format used by spam.pl
  #-------------------------------------------------------------------------

  for my $host (keys %tree) {
    for my $if (keys %{$tree{$host}{'ipNetToMediaPhysAddress'}}) {
      for my $ip (keys %{$tree{$host}{'ipNetToMediaPhysAddress'}{$if}}) {
        if(
          $tree{$host}{'ipNetToMediaType'}{$if}{$ip}{'enum'} eq 'dynamic'
        ) {
          my $mac = $tree{$host}{'ipNetToMediaPhysAddress'}{$if}{$ip}{'value'};
          $mac = join(':', map {
            if(length($_) < 2) { $_ = '0' . $_; } else { $_; }
          } split(/:/, $mac));
          $arptable{$mac} = $ip;
        }
      }
    }
  }

  #--- finish

  return \%arptable;
}


#==========================================================================
# This function retrieves hwinfo (processed select information from
# entPhysicalTable) and stores it into $swdata{hwinfo}. This function is 
# a stopgap designed to be fully compatible with previous function that
# that worked in the old way.
#==========================================================================

sub snmp_entity_to_hwinfo
{
  my ($h) = @_;
  my $ent = $h->{'mibs-new'}{'ENTITY-MIB'};
  my %hw;
  my $cidx = 1000;     # incremental index for non-module components

  #--- iterate ver entPhysicalTable 

  for my $idx (sort { $a <=> $b } keys %{$ent->{'entPhysicalTable'}}) {
    my $pt = $ent->{'entPhysicalTable'}{$idx};
    my $class = $pt->{'entPhysicalClass'}{'enum'};
    my $physname = $pt->{'entPhysicalName'}{'value'};
    my $container = $pt->{'entPhysicalContainedIn'}{'value'};
    my $c_physname
       = $ent->{'entPhysicalTable'}{$container}{'entPhysicalName'}{'value'};

    #--- power supply, chassis

    if($class eq 'chassis' || $class eq 'powerSupply') {
      $physname =~ /^(?:Chassis (\d) ).*$/;
      my $chassis = $1;
      if(!$chassis) { $chassis = 0; }

      $hw{$chassis}{$cidx}{'type'} = $class;
      if($class eq 'powerSupply') {
        $hw{$chassis}{$cidx}{'type'} = 'ps';
      }
      $hw{$chassis}{$cidx}{'descr'}
      = $pt->{'entPhysicalDescr'}{'value'};
      $hw{$chassis}{$cidx}{'model'}
      = $pt->{'entPhysicalModelName'}{'value'};
      $hw{$chassis}{$cidx}{'sn'}
      = $pt->{'entPhysicalSerialNum'}{'value'};
      $hw{$chassis}{$cidx}{'hwrev'}
      = $pt->{'entPhysicalHardwareRev'}{'value'};
      $cidx++;
    }

    #--- module (linecard)

    if(
      $class eq 'module'
      && $c_physname =~ /^(?:Chassis (\d) |)Physical Slot (\d)+$/
    ) {
      my $slot = $2;
      my $chassis = $1;
      if(!$chassis) { $chassis = 0; }

      $hw{$chassis}{$slot}{'type'} = 'linecard';
      $hw{$chassis}{$slot}{'model'}
      = $pt->{'entPhysicalModelName'}{'value'};
      $hw{$chassis}{$slot}{'sn'}
      = $pt->{'entPhysicalSerialNum'}{'value'};
      $hw{$chassis}{$slot}{'hwrev'}
      = $pt->{'entPhysicalHardwareRev'}{'value'};
      $hw{$chassis}{$slot}{'fwrev'}
      = $pt->{'entPhysicalFirmwareRev'}{'value'};
      $hw{$chassis}{$slot}{'swrev'}
      = $pt->{'entPhysicalSoftwareRev'}{'value'};
      $hw{$chassis}{$slot}{'descr'}
      = $pt->{'entPhysicalDescr'}{'value'};
    }
  }

  #--- finish

  return \%hw;
}


#==========================================================================
# Function for parsing SNMP values as returned snmp-utils.
#==========================================================================

sub snmp_value_parse
{
  my $value = shift;
  my %re;

  #--- integer

  if($value =~ /^INTEGER:\s+(\d+)$/) {
    $re{'type'} = 'INTEGER';
    $re{'value'} = $1 + 0;
  }

  #--- integer-enum

  elsif($value =~ /^INTEGER:\s+(\w+)\((\d+)\)$/) {
    $re{'type'} = 'INTEGER';
    $re{'value'} = $2;
    $re{'enum'} = $1;
  }

  #--- string

  elsif($value =~ /^STRING:\s+(.*)$/) {
    $re{'type'} = 'STRING';
    $re{'value'} = $1;
  }

  #--- gauge

  elsif($value =~ /^Gauge(32|64): (\d+)$/) {
    $re{'type'} = 'Gauge';
    $re{'bitsize'} = $1;
    $re{'value'} = $2 + 0;
  }

  #--- counter

  elsif($value =~ /^Counter(32|64): (\d+)$/) {
    $re{'type'} = 'Counter';
    $re{'bitsize'} = $1;
    $re{'value'} = $2 + 0;
  }

  #--- timeticks

  elsif($value =~ /Timeticks:\s+\((\d+)\)\s+(.*)\.\d{2}$/) {
    $re{'type'} = 'Timeticks';
    $re{'value'} = $1;
    $re{'fmt'} = $2;
  }

  #--- hex string

  elsif($value =~ /^Hex-STRING:\s+(.*)$/) {
    $re{'type'} = 'Hex-STRING';
    my @v = split(/\s/, $1);
    if(scalar(@v) == 6) {
      $re{'value'} = lc(join(':', @v));
    } else {
      $re{'value'} = lc($1);
    }
  }

  #--- MIB reference

  elsif($value =~ /^([\w-]+)::(\w+)$/) {
    $re{'type'} = 'Ref';
    $re{'mib'} = $1;
    $re{'value'} = $2;
  }

  #--- generic type:value

  elsif($value =~ /^(\w+): (.*)$/) {
    $re{'type'} = 'generic';
    $re{'gentype'} = $1;
    $re{'value'} = $2;
  }

  #--- uncrecognized output

  else {
    $re{'type'} = 'unknown';
    $re{'value'} = $value;
  }

  #--- finish

  return \%re;
}


#==========================================================================
# Get SNMP sub-tree and store it into a hashref. First five arguments are
# the same as for snmp_lineread(), sixth argument is optional callback
# that receives line count as argument (for displaying progress indication)
# The callback can optionally return number of seconds that determine the
# period it should be called at.
#==========================================================================

sub snmp_get_tree
{
  #--- arguments (same as to snmp_lineread)

  # arguments 0..5 are those of snmp_lineread(); the last argument is
  # optional and is an callback intended for displaying progress status that
  # is invoked with (VARIABLE, CNT) where variable is SNMP variable
  # currently being processed and CNT is entry counter that's zeroed for
  # each new variable.  This callback is invoked only when: a) the variable
  # being read is different from previous one (ie.  reading of one variable
  # finished), or specified amount of time passed between now and the last
  # time the callback was called.  Default delay is 1 second, but it can be
  # specified on callback invocation: the returned value will be used for
  # the rest of the invocations.  Granularity is only 1 second (the
  # implementation uses time() function).

  my @args = splice(@_, 0, 5);
  my $cback = shift;

  #--- other variables

  my %re;
  my $cnt = 0;
  my $tm1 = time();
  my $var1;
  my $delay = 1;
  my $fh;

  #--- initiate debugging

  if($ENV{'SPAM_DEBUG'}) {
    open($fh, '>>', "debug.snmp_tree.$$.log");
    if($fh) {
      printf $fh "--> SNMP TREE %s::%s", $args[3], $args[4];
      if($args[2] =~ /\@(\d+)$/) {
        printf $fh " (%d)", $1;
      }
      print $fh "\n";
      printf $fh "--> %s\n", snmp_command(@args);
    }
  }

  #--- initial callback call

  if($cback) {
    my $rv = $cback->(undef, $cnt);
    $delay = $rv if $rv > 0;
  }

  #--- main loop ------------------------------------------------------------

  my $r = snmp_lineread(@args, sub {
    my $l = shift;
    my $tm2;

  #--- FIXME: skip lines that don't contain '='

  # This is ugly hack to work around the way snmp-utils display long binary
  # strings (type "Hex-STRING"): these are displayed on multiple lines, which
  # causes problems with current way of parsing the output. So this should
  # be reimplemented to accomodate this, but meanwhile we just slurp the hex
  # values on the first line and discard the rest.
  
    return if $l !~ /=/;
  
  #--- split into variable and value

    my ($var, $val) = split(/ = /, $l);

  #--- drop the "No Such Instance" result

    return if $val =~ /^No Such Instance/;

  #--- parse the right side (value)

    my $rval = snmp_value_parse($val);
    if($ENV{'SPAM_DEBUG'}) {
      $rval->{'src'} = $l;
    }

  #--- parse the left side (variable, indexes)

    $var =~ s/^.*:://;  # drop the MIB name

  #--- get indexes

  # left side as output by SNMP utils with -OX option appears in one of the
  # three forms (with corresponding sections of code below):
  #   1. snmpVariable.0
  #   2. snmpVariable
  #   2. snmpVariable[idx1][idx2]...[idxN]

    my @i;
    if($var =~ s/\.0$//) {
      @i = (0);
    } elsif($var =~ /^\w+$/) {
      @i = ();
    } else {
      $idx = $var;
      $idx =~ s/^([^\[]*)\[(.*)\]$/$2/;
      $var = $1;
      @i = split(/\]\[/, $idx);
      for (@i) { 
        s/^"(.*)"$/$1/;      # drop double quotes around index value
        s/^STRING:\s*//;     # drop type prefix from strings
      }
    }

  #--- store the values

  # following code builds hash so that [0][1][2] becomes $h->{0}{1}{2};
  # the hash creation is additive, so preexisting hashes are reused, not
  # overwritten

    if(!ref($re{$var})) { $re{$var} = {}; }
    my $h = $re{$var};
    if(@i) {
      for my $k (@i[0 .. $#i-1]) {
        $h->{$k} = {} if !ref($h->{$k});
        $h = $h->{$k};
      }
      $h->{$i[-1]} = $rval;
    } else {
      $re{$var} = $rval;
    }
  
  #--- debugging info
  
    if($fh) {
      my $rval_txt = join(',', %$rval);
      printf $fh "%s.%s = %s\n", $var, join('.', @i), $rval_txt;
    }

  #--- line counter

    $cnt++;

  #--- callback

    $tm2 = time();
    if($var1 ne $var) {
      $cnt = 0;
      $tm1 = $tm2;
      $var1 = $var;
      $cback->($var, $cnt) if $cback;
    } elsif(($tm2 - $tm1) >= $delay) {
      $cback->($var, $cnt) if $cback;
      $tm1 = $tm2;
    }

  #--- finish callback

    return undef;
  });

  #--- finish ---------------------------------------------------------------

  close($fh) if $fh;
  return $r ? $r : \%re;
}


#==========================================================================
# Get SNMP object and store it into a hashref. First five arguments are
# the same as for snmp_lineread(), sixth argument is optional callback
# that receives line count as argument (for displaying progress indication)
# The callback can optionally return number of seconds that determine the
# period it should be called at.
#==========================================================================

sub snmp_get_object
{
  #--- arguments (same as to snmp_lineread)

  # arguments 0..5 are those of snmp_lineread(); argument 5 is list of
  # columns to retrieve, this can be undef to get all existing columns; the
  # last argument is optional and is an callback intended for displaying
  # progress status that is invoked with (VARIABLE, CNT) where variable is
  # SNMP variable currently being processed and CNT is entry counter that's
  # zeroed for each new variable.  This callback is invoked only when: a)
  # the variable being read is different from previous one (ie.  reading of
  # one variable finished), or specified amount of time passed between now
  # and the last time the callback was called.  Default delay is 1 second,
  # but it can be specified on callback invocation: the returned value will
  # be used for the rest of the invocations.  Granularity is only 1 second
  # (the implementation uses time() function).

  my (
    $cmd,       # 1 / scal / SNMP command
    $host,      # 2 / scal / SNMP host (agent)
    $community, # 3 / scal / SNMP community
    $mibs,      # 4 / aref / list of MIBs to load
    $object,    # 5 / scal / SNMP object to retrieve
    $columns,   # 6 / aref / columns (undef = all columns)
    $cback      # 7 / sub  / callback
  ) = @_;

  #--- other variables

  my $delay = 1;
  my %re;

  #--- make $columns an arrayref

  if($columns && !ref($columns)) {
    $columns = [ $columns ];
  }

  #--- initiate debugging

  if($ENV{'SPAM_DEBUG'}) {
    open($fh, '>>', "debug.snmp_object.$$.log");
    if($fh) {
      # FIXME:$mibs may be arrayref, this should be handled here
      printf $fh "--> SNMP OBJECT %s::%s", $mibs, $object;
      if($args[2] =~ /\@(\d+)$/) {
        printf $fh " (%d)", $1;
      }
      print $fh "\n";
    }
  }

  #--- initial callback call

  if($cback) {
    my $rv = $cback->(undef, $cnt);
    $delay = $rv if $rv > 0;
  }

  #--- get set of MIB tree entry points

  my @tree_entries = ($object);
  if($columns && ref($columns)) {
    @tree_entries = @$columns;
  }
  printf $fh "--> ENTRY POINTS: %s\n", join(',', @tree_entries);

  #--- entry points loop ----------------------------------------------------

  for my $entry (@tree_entries) {
    my $cnt = 0;

  #--- read loop ------------------------------------------------------------

    my $r = snmp_lineread($cmd, $host, $community, $mibs, $entry, sub {
      my $l = shift;
      my $tm2;

  #--- FIXME: skip lines that don't contain '='

  # This is ugly hack to work around the way snmp-utils display long binary
  # strings (type "Hex-STRING"): these are displayed on multiple lines, which
  # causes problems with current way of parsing the output. So this should
  # be reimplemented to accomodate this, but meanwhile we just slurp the hex
  # values on the first line and discard the rest.

      return if $l !~ /=/;

  #--- split into variable and value

      my ($var, $val) = split(/ = /, $l);

  #--- drop the "No Such Instance" result

      return if $val =~ /^No Such Instance/;

  #--- parse the right side (value)

      my $rval = snmp_value_parse($val);
      if($ENV{'SPAM_DEBUG'}) {
        $rval->{'src'} = $l;
      }

  #--- parse the left side (variable, indexes)

      $var =~ s/^.*:://;  # drop the MIB name

  #--- get indexes

  # left side as output by SNMP utils with -OX option appears in one of the
  # three forms (with corresponding sections of code below):
  #
  #   1. snmpVariable.0
  #   2. snmpVariable
  #   3. snmpVariable[idx1][idx2]...[idxN]
  #
  # this code converts these forms into an array of the index values

      my @i;
      my $scalar = 0;

      # case 1: SNMP scalar value denoted by .0
      if($var =~ s/\.0$//) {
        $scalar = 1;
      }

      # case 2: (not sure what is this called in SNMP terminology)
      elsif($var =~ /^\w+$/) {
        @i = ();
      }

      # case 3: one or more indices
      else {
        $idx = $var;
        # following regex parses the object/column name and removes starting
        # and final square brackets
        $idx =~ s/^([^\[]*)\[(.*)\]$/$2/;
        $var = $1;
        @i = split(/\]\[/, $idx);
        for (@i) {
          s/^"(.*)"$/$1/;      # drop double quotes around index value
          s/^STRING:\s*//;     # drop type prefix from strings
        }
      }

  #--- store the values

  # following code builds hash that stores the values ($rval in the code);
  # the structure created is:
  #
  # 1. $re -> 0     ->                          value
  # 2. $re -> undef ->                          value
  # 3. $re -> idx1  -> ... -> idxN -> column -> value

      # SNMP scalar value
      if($scalar) {
        $re{0} = $rval;
      }

      # unindexed SNMP scalar (scalar without the .0)
      elsif(scalar(@i) == 0) {
        $re{undef} = $rval;
      }

      # SNMP tables, @i holds the indices, $var is column name
      else {
        my $h = \%re;
        for my $j (@i) {
          $h->{$j} = {} if !exists $h->{$j};
          $h = $h->{$j};
        }
        $h->{$var} = $rval;
      }

  #--- debugging info

      if($fh) {
        my $rval_txt = join(',', %$rval);
        printf $fh "%s.%s = %s\n", $var, join('.', @i), $rval_txt;
      }

  #--- line counter

      $cnt++;

  #--- callback

      $tm2 = time();
      if($var1 ne $var) {
        $cnt = 0;
        $tm1 = $tm2;
        $var1 = $var;
        $cback->($var, $cnt) if $cback;
      } elsif(($tm2 - $tm1) >= $delay) {
        $cback->($var, $cnt) if $cback;
        $tm1 = $tm2;
      }

  #--- finish callback

      return undef;
    });

  #--- abort on error

    if($r) {
      close($fh);
      return $r;
    }

  #--- finish looping over the MIB tree entries

  }

  #--- finish ---------------------------------------------------------------

  close($fh) if $fh;
  return \%re;
}


1;
