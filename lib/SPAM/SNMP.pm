package SPAM::SNMP;

# set of functions to perform SNMP access using external utilities from Net-SNMP

require Exporter;
use lib 'lib';
use SPAM::Misc qw(file_lineread hash_create_index);
use SPAM::Entity;
use SPAM::EntityTree;
use SPAM::Config;
use Feature::Compat::Try;

use warnings;
use strict;
use integer;
use experimental 'signatures';

our (@ISA, @EXPORT);

@ISA = qw(Exporter);
@EXPORT = qw(
  snmp_get_arptable
  snmp_get_object
);

#-------------------------------------------------------------------------------
# read SNMP command's output line by line; the primary purpose of this code is
# to merge multi-line values into single lines for further parsing
sub snmp_lineread ($cmd, $cb)
{
  # iterate over lines while merging multi-line values into single lines
  my $acc;

  my $r = file_lineread($cmd, '-|', sub {
    my $l = shift;

    if($l =~ /^\S+::/) {
      $cb->($acc) if $acc;
      $acc = $l;
    } else {
      $acc .= $l;
    }
    return undef;
  });

  # failed read
  return $r if $r;

  # successful read
  $cb->($acc) if $acc;
  return undef;
}

#-------------------------------------------------------------------------------
# parse SNMP values as returned by Net-SNMP
sub snmp_value_parse ($value)
{
  my %re;

  # remove leading/trailing whitespace
  s/^\s+//, s/\s+$// for $value;

  # integer
  if($value =~ /^INTEGER:\s+(\d+)$/) {
    $re{'type'} = 'INTEGER';
    $re{'value'} = $1 + 0;
  }

  # integer-enum
  elsif($value =~ /^INTEGER:\s+(\w+)\((\d+)\)$/) {
    $re{'type'} = 'INTEGER';
    $re{'value'} = $2;
    $re{'enum'} = $1;
  }

  # string
  elsif($value =~ /^STRING:\s+(.*)$/) {
    $re{'type'} = 'STRING';
    $re{'value'} = $1;
  }
  elsif($value =~ /^STRING:$/) {
    $re{'type'} = 'STRING';
    $re{'value'} = undef;
  }

  # gauge
  elsif($value =~ /^Gauge(32|64): (\d+)$/) {
    $re{'type'} = 'Gauge';
    $re{'bitsize'} = $1;
    $re{'value'} = $2 + 0;
  }

  # counter
  elsif($value =~ /^Counter(32|64): (\d+)$/) {
    $re{'type'} = 'Counter';
    $re{'bitsize'} = $1;
    $re{'value'} = $2 + 0;
  }

  # timeticks
  elsif($value =~ /Timeticks:\s+\((\d+)\)\s+(.*)\.\d{2}$/) {
    $re{'type'} = 'Timeticks';
    $re{'value'} = $1;
    $re{'fmt'} = $2;
  }

  # hex string
  elsif($value =~ /^Hex-STRING:\s+(.*)$/) {
    $re{'type'} = 'Hex-STRING';
    my @v = split(/\s/, $1);
    if(scalar(@v) == 6) {
      $re{'value'} = lc(join(':', @v));
    } else {
      $re{'value'} = lc($1);
    }
    $re{'bitstring'} = join('', map { sprintf '%08b', hex $_ } @v);
  }

  # MIB reference
  elsif($value =~ /^([\w-]+)::(\w+)$/) {
    $re{'type'} = 'Ref';
    $re{'mib'} = $1;
    $re{'value'} = $2;
  }

  # OID
  elsif($value =~ /
    ^OID:
    \s+
    ([\w-]+)            # 1. MIB name
    ::
    (\w+)               # 2. column name
    (\[ [\d\[\]]+ \])   # 3. index
    $
  /x) {
    my @value = grep { length } split(/[\[\]]+/, $3);
    $re{'type'} = 'OID';
    $re{'mib'} = $1;
    $re{'column'} = $2;
    $re{'value'} = @value == 1 ? $value[0] : \@value;
  }

  # generic type:value
  elsif($value =~ /^(\w+): (.*)$/) {
    $re{'type'} = 'generic';
    $re{'gentype'} = $1;
    $re{'value'} = $2;
  }

  # uncrecognized output
  else {
    $re{'type'} = 'unknown';
    $re{'value'} = $value;
  }

  # finish
  return \%re;
}

#-------------------------------------------------------------------------------
# Function for (optional) mangling of values retrieved from SNMP. This is
# configured through a mapping in config under key "mib-types": which is a hash
# of "MIB object" to "type", where type is what is passed into this function.
# This allows us to perform additional conversion step, for example convert
# Hex-STRING to IP address.
sub snmp_value_transform ($rval, $type)
{
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

#-------------------------------------------------------------------------------
# Get SNMP object and store it into a hashref. First five arguments are the same
# as for snmp_lineread(), sixth argument is optional callback that receives line
# count as argument (for displaying progress indication) The callback can
# optionally return number of seconds that determine the period it should be
# called at.
sub snmp_get_object
{
  #--- arguments (same as to snmp_lineread)

  # arguments 0..5 are those of snmp_lineread(); argument 5 is list of columns
  # to retrieve, this can be undef to get all existing columns; the last
  # argument is optional and is an callback intended for displaying progress
  # status that is invoked with (VARIABLE, CNT) where variable is SNMP variable
  # currently being processed and CNT is entry counter that's zeroed for each
  # new variable.  This callback is invoked only when: a) the variable being
  # read is different from previous one (ie.  reading of one variable finished),
  # or specified amount of time passed between now and the last time the
  # callback was called.  Default delay is 1 second, but it can be specified on
  # callback invocation: the returned value will be used for the rest of the
  # invocations.  Granularity is only 1 second (the implementation uses time()
  # function).

  my (
    $cmd,       # 1 / scal / SNMP command
    $host,      # 2 / scal / SNMP host (agent)
    $context,   # 3 / scal / SNMP context
    $mibs,      # 4 / aref / list of MIBs to load
    $object,    # 5 / scal / SNMP object to retrieve
    $columns,   # 6 / aref / columns (undef = all columns)
    $cback      # 7 / sub  / callback
  ) = @_;

  # other variables
  my $cfg = SPAM::Config->instance->config;
  my $delay = 1;
  my %re;
  my $fh;
  my ($var1, $tm1) = ('', 0);

  # make $columns an arrayref
  if($columns && !ref($columns)) {
    $columns = [ $columns ];
  }

  # initiate debugging
  if($ENV{'SPAM_DEBUG'}) {
    open($fh, '>>', "debug.snmp_object.$$.log");
    if($fh) {
      printf $fh
        "--> SNMP_GET_OBJECT ARGS: 1:%s 2:%s 3:%s 4:%s 5:%s 6:%s\n",
        $cmd,  $host, $context // 'undef',
        ref $mibs ? join(',', @$mibs) : $mibs,
        $object,
        @$columns ? join(',', @$columns) : 'NO_COLUMNS';
    }
  }

  # initial callback call
  if($cback) {
    my $rv = $cback->(undef, 0);
    $delay = $rv if ($rv // 0) > 0;
  }

  # get set of MIB tree entry points
  my @tree_entries = ($object);
  @tree_entries = @$columns if @$columns;
  printf $fh "--> ENTRY POINTS: %s\n", join(',', @tree_entries) if $fh;

  # entry points loop
  for my $entry (@tree_entries) {
    my $cnt = 0;

    # read loop
    my ($cmd, $profile) = SPAM::Config->instance->get_snmp_command(
      command   => $cmd,
      host      => $host,
      context   => $context,
      mibs      => $mibs,
      oid       => $entry
    );

    printf $fh "--> SNMP COMMAND (profile=%s): %s\n", $profile, $cmd if $fh;

    my $read_state = 'first';

    my $r = snmp_lineread($cmd, sub {
      my $l = shift;
      my $tm2;

      # split into variable and value
      my ($var, $val) = split(/ = /, $l);

      # parse the right side (value)
      my $rval = snmp_value_parse($val);
      if($ENV{'SPAM_DEBUG'}) {
        $rval->{'src'} = $l;
      }

      # drop the "No Such Instance/Object" result
      if(
        $rval->{'value'}
        && $rval->{'value'} =~ /^No Such (Instance|Object)/
      ) {
        return;
      }

      # parse the left side (variable, indexes)
      $var =~ s/^.*:://;  # drop the MIB name

      # get indexes // left side as output by SNMP utils with -OX option appears
      # in one of the three forms (with corresponding sections of code below):
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

      # value transform
      if(exists $cfg->{'mib-types'}{$var}) {
        snmp_value_transform($rval, $cfg->{'mib-types'}{$var});
      }

      # store the values // following code builds hash that stores the values
      # ($rval in the code); the structure created is:
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

      # debugging info
      if($fh) {
        my $rval_txt = join(',', map { $_ // '' } %$rval);
        printf $fh "%s.%s = %s\n", $var, join('.', @i), $rval_txt;
      }

      # line counter
      $cnt++;

      # callback
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

      # finish callback
      return undef;
    });

    # abort on error
    if($r) {
      close($fh);
      return $r;
    }

  # finish looping over the MIB tree entries
  }

  # finish
  close($fh) if $fh;
  return scalar(keys %re) ? \%re : 'No instances found';
}

#-------------------------------------------------------------------------------

1;
