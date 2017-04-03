#!/usr/bin/perl

#===========================================================================
# Switch Ports Activity Monitor -- SNMP support library
# """""""""""""""""""""""""""""
# 2000 Borek Lupomesky <Borek.Lupomesky@oskarmobil.cz>
#===========================================================================


package SPAM_SNMP;
require Exporter;
use SPAMv2 qw(load_config file_lineread hash_create_index);
use Data::Dumper;

use warnings;
use strict;
use integer;

our (@ISA, @EXPORT);

@ISA = qw(Exporter);
@EXPORT = qw(
  snmp_entity_to_hwinfo
  snmp_get_arptable
  snmp_get_object
  snmp_get_active_vlans
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

  #--- MIB and object to use for arptable processing; note, that only the
  #--- first MIB object with flag 'arptable' will be used

  my ($mib_name, $object);
  MIBLOOP: for my $mib (@{$cfg->{'mibs'}}) {
    $mib_name = $mib->{'mib'};
    for my $object_iter (@{$mib->{'objects'}}) {
      if(grep { $_ eq 'arptable' } @{$object_iter->{'flags'}}) {
        $object = $object_iter;
        last MIBLOOP;
      }
    }
  }

  #-------------------------------------------------------------------------
  #--- read the relevant MIB sections --------------------------------------
  #-------------------------------------------------------------------------

  for my $arp_source (@$arpdef) {
    my $r;

  #--- SNMP community, either default or per-server

    my $cmty = $arp_source->[1] // $def_cmty;
    $tree{$arp_source->[0]} = {};

  #--- read the MIB tree

    $r = snmp_get_object(
      'snmpwalk',
      $arp_source->[0],
      $cmty,
      $mib_name,
      $object->{'table'},
      $object->{'columns'}
    );

  #--- handle the result

    if(!ref($r)) {
      die sprintf("failed to get arptable from %s (%s)", $arp_source->[0], $r);
    } else {
      my $t = $tree{$arp_source->[0]};
      %$t = ( %$t, %$r );
    }

  #--- display message through callback

    if($cb) {
      $cb->($arp_source->[0]);
    }
  }

  #-------------------------------------------------------------------------
  #--- transform the data into the format used by spam.pl
  #-------------------------------------------------------------------------

  for my $host (keys %tree) {
    for my $if (keys %{$tree{$host}}) {
      for my $ip (keys %{$tree{$host}{$if}}) {
        if(
          $tree{$host}{$if}{$ip}{'ipNetToMediaType'}{'enum'} eq 'dynamic'
        ) {
          my $mac = $tree{$host}{$if}{$ip}{'ipNetToMediaPhysAddress'}{'value'};
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
# worked in the old way.
#==========================================================================

sub snmp_entity_to_hwinfo
{
  my ($h) = @_;
  my $ent = $h->{'ENTITY-MIB'};
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
      && $c_physname
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
# Function for parsing SNMP values as returned by snmp-utils.
#==========================================================================

sub snmp_value_parse
{
  my $value = shift;
  my %re;

  #--- remove leading/trailing whitespace

  s/^\s+//, s/\s+$// for $value;

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
  elsif($value =~ /^STRING:$/) {
    $re{'type'} = 'STRING';
    $re{'value'} = undef;
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
# Function for (optional) mangling of values retrieved from SNMP. This is
# configured throug a mapping in config under key "mib-types": which is a
# hash of "MIB object" to "type", where type is what is passed into this
# function. This allows us to perform additional conversion stop, for
# example convert Hex-STRING to IP address.
#==========================================================================

sub snmp_value_transform
{
  #--- arguments

  my (
    $rval,      # 1. right-value as created by snmp_value_parse)
    $type       # 2. type tag, configured in config
  ) = @_;

  #--- inet4

  if($type eq 'inet4') {
    $rval->{'value_orig'} = $rval->{'value'};
    if($rval->{'type'} eq 'Hex-STRING') {
      my @v = split /\s/, $rval->{'value'};
      if(scalar(@v) == 4) {
        my $new_val = join('.', map { hex; } @v);
        if($new_val eq '0.0.0.0') { $new_val = undef; }
        $rval->{'value'} = $new_val;
      }
    } else {
      $rval->{'value'} = undef;
    }
  }
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

  my $cfg = load_config();
  my $delay = 1;
  my %re;
  my $fh;
  my ($var1, $tm1) = ('', 0);

  #--- make $columns an arrayref

  if($columns && !ref($columns)) {
    $columns = [ $columns ];
  }

  #--- initiate debugging

  if($ENV{'SPAM_DEBUG'}) {
    open($fh, '>>', "debug.snmp_object.$$.log");
    if($fh) {
      # FIXME:$mibs may be arrayref, this should be handled here
      printf $fh "--> SNMP OBJECT %s::%s\n", $mibs, $object;
    }
  }

  #--- initial callback call

  if($cback) {
    my $rv = $cback->(undef, 0);
    $delay = $rv if ($rv // 0) > 0;
  }

  #--- get set of MIB tree entry points

  my @tree_entries = ($object);
  if($columns && ref($columns)) {
    @tree_entries = @$columns;
  }
  printf $fh "--> ENTRY POINTS: %s\n", join(',', @tree_entries) if $fh;

  #--- entry points loop ----------------------------------------------------

  for my $entry (@tree_entries) {
    my $cnt = 0;

  #--- read loop ------------------------------------------------------------

    printf $fh "--> SNMP COMMAND: %s\n",
      snmp_command($cmd, $host, $community, $mibs, $entry)
      if $fh;
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

  #--- parse the right side (value)

      my $rval = snmp_value_parse($val);
      if($ENV{'SPAM_DEBUG'}) {
        $rval->{'src'} = $l;
      }

  #--- drop the "No Such Instance/Object" result

      if(
        $rval->{'value'}
        && $rval->{'value'} =~ /^No Such (Instance|Object)/
      ) {
        return;
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
        my $idx = $var;
        # following regex parses the object/column name and removes starting
        # and final square brackets
        $idx =~ s/^([^\[]*)\[(.*)\]$/$2/;
        $var = $1;
        @i = split(/\]\[/, $idx);
        for (@i) {
          s/^["'](.*)["']$/$1/; # drop double quotes around index value
          s/^STRING:\s*//;      # drop type prefix from strings
        }
      }

  #--- value transform

      if(exists $cfg->{'mib-types'}{$var}) {
        snmp_value_transform($rval, $cfg->{'mib-types'}{$var});
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
        hash_create_index(\%re, { $var => $rval }, @i);
      }

  #--- debugging info

      if($fh) {
        my $rval_txt = join(',', map { $_ // '' } %$rval);
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
  return scalar(keys %re) ? \%re : 'No instances found';
}


#==========================================================================
# Function that tries to collate list of active VLANs, ie. VLANs in actual
# use on a switch as opposed to just configured VLANs. Currently, we are
# using two sources:
#
#  * vmVlan from vlanMembershipTable
#  * cafSessionAuthVlan from cafSessionTable
#==========================================================================

sub snmp_get_active_vlans
{
  #--- arguments

  my ($s) = @_;

  #--- other variables

  my %vlans;

  #--- dynamic VLANs configured by user authentication

  if(
    exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}
    && exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionTable'}
  ) {
    my $cafSessionTable = $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionTable'};
    for my $if (keys %$cafSessionTable) {
      for my $sid (keys %{$cafSessionTable->{$if}}) {
        if(exists $cafSessionTable->{$if}{$sid}{'cafSessionAuthVlan'}) {
          my $v = $cafSessionTable->{$if}{$sid}{'cafSessionAuthVlan'}{'value'};
          $vlans{$v} = undef if $v > 0 && $v < 1000;
        }
      }
    }
  }

  #--- static VLANs

  if(
    exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}
    && exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}
  ) {
    my $vmMembershipTable
    = $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'};
    for my $if (keys %$vmMembershipTable) {
      my $v = $vmMembershipTable->{$if}{'vmVlan'}{'value'};
      $vlans{$v} = undef if $v > 0 && $v < 1000;
    }
  }

  #--- finish

  return sort { $a <=> $b } keys %vlans;
}


1;
