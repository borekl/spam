#!/usr/bin/perl

#===========================================================================
# Switch Ports Activity Monitor -- SNMP support library
# """""""""""""""""""""""""""""
# 2000-2021 Borek Lupomesky <Borek.Lupomesky@oskarmobil.cz>
#===========================================================================


package SPAM::SNMP;
require Exporter;
use lib 'lib';
use SPAM::Misc qw(file_lineread hash_create_index hash_iterator hash_index_access);
use SPAM::Entity;
use SPAM::EntityTree;
use SPAM::Config;
use Data::Dumper;
use Carp;
use Feature::Compat::Try;

use warnings;
use strict;
use integer;

our (@ISA, @EXPORT);

@ISA = qw(Exporter);
@EXPORT = qw(
  snmp_get_arptable
  snmp_get_object
  sql_save_snmp_object
);


#==========================================================================
# Read SNMP command's output line by line. The primary purpose of this code
# is to merge multi-line values into single lines for further parsing.
#==========================================================================

sub snmp_lineread
{
  #--- arguments

  my ($cmd, $callback) = @_;

  #--- iterate over lines while merging multi-line values into single lines

  my $acc;

  my $r = file_lineread($cmd, '-|', sub {
    my $l = shift;

    if($l =~ /^\S+::/) {
      $callback->($acc) if $acc;
      $acc = $l;
    } else {
      $acc .= $l;
    }
    return undef;
  });

  #--- failed read

  return $r if $r;

  #--- successful read

  $callback->($acc) if $acc;
  return undef;
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
  my $cfg = SPAM::Config->instance;

  #--- MIB and object to use for arptable processing; note, that only the
  #--- first MIB object with flag 'arptable' will be used

  my $object = $cfg->find_object(sub {
    return 1 if $_[0]->has_flag('arptable');
  });

  #-------------------------------------------------------------------------
  #--- read the relevant MIB sections --------------------------------------
  #-------------------------------------------------------------------------

  for my $arp_source (@$arpdef) {
    my $r;

  #--- read the MIB tree

    $r = snmp_get_object(
      'snmpwalk',
      $arp_source->[0],
      undef,
      $object->mib_name,
      $object->name,
      $object->columns
    );

  #--- handle the result

    if(!ref($r)) {
      die sprintf("failed to get arptable from %s (%s)", $arp_source->[0], $r);
    } else {
      # FIXME: What the hell is this trying to achieve???
      $tree{$arp_source->[0]} = {};
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
    $re{'bitstring'} = join('', map { sprintf '%08b', hex $_ } @v);
  }

  #--- MIB reference

  elsif($value =~ /^([\w-]+)::(\w+)$/) {
    $re{'type'} = 'Ref';
    $re{'mib'} = $1;
    $re{'value'} = $2;
  }

  #--- OID

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
    $context,   # 3 / scal / SNMP context
    $mibs,      # 4 / aref / list of MIBs to load
    $object,    # 5 / scal / SNMP object to retrieve
    $columns,   # 6 / aref / columns (undef = all columns)
    $cback      # 7 / sub  / callback
  ) = @_;

  #--- other variables

  my $cfg = SPAM::Config->instance->config;
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
      printf $fh
        "--> SNMP_GET_OBJECT ARGS: 1:%s 2:%s 3:%s 4:%s 5:%s 6:%s\n",
        $cmd,  $host, $context // 'undef',
        ref $mibs ? join(',', @$mibs) : $mibs,
        $object,
        @$columns ? join(',', @$columns) : 'NO_COLUMNS';
    }
  }

  #--- initial callback call

  if($cback) {
    my $rv = $cback->(undef, 0);
    $delay = $rv if ($rv // 0) > 0;
  }

  #--- get set of MIB tree entry points

  my @tree_entries = ($object);
  @tree_entries = @$columns if @$columns;
  printf $fh "--> ENTRY POINTS: %s\n", join(',', @tree_entries) if $fh;

  #--- entry points loop ----------------------------------------------------

  for my $entry (@tree_entries) {
    my $cnt = 0;

  #--- read loop ------------------------------------------------------------

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


#===========================================================================
# This function saves SNMP table into database.
#===========================================================================

sub sql_save_snmp_object
{
  #--- arguments

  my (
    $host,         # 1. host instance
    $snmp_object   # 2. SNMP object to be saved
  ) = @_;

  #--- other variables

  my $cfg = SPAM::Config->instance;
  my $dbh = $cfg->get_dbi_handle('spam');
  my %stats = ( insert => 0, update => 0, delete => 0 );
  my $err;                 # error message
  my $debug_fh;            # debug file handle
  my $ref_time = time();   # reference 'now' point of time
  my $tx = SPAM::DbTransaction->new;

  #--- open debug file

  if($ENV{'SPAM_DEBUG'}) {
    open($debug_fh, '>>', "debug.save_snmp_object.$$.log");
    if($debug_fh) {
      printf $debug_fh
        "==> sql_save_snmp_object(%s,%s)\n", $host->name, $snmp_object->name;
      printf $debug_fh
        "--> REFERENCE TIME: %s\n", scalar(localtime($ref_time));
    }
  }

  #=========================================================================
  #=== try block start =====================================================
  #=========================================================================

  try {

    # ensure database connection
    die 'Cannot connect to database (spam)' unless ref $dbh;

    # find the MIB object we're saving
    my $obj = $cfg->find_object($snmp_object->name);
    my @object_index = @{$snmp_object->index};
    printf $debug_fh "--> OBJECT INDEX: %s\n", join(', ', @object_index)
      if $debug_fh;

    # find the object in the host instance
    my $object = $host->get_snmp_object($snmp_object->name);
    die "Object $snmp_object does not exist" unless $object;

    # load the current state to %old
    my %old;
    my $old_row_count = 0;
    my $table = 'snmp_' . $snmp_object->name;

    my @fields = (
      '*',
      "$ref_time - extract(epoch from date_trunc('second', chg_when)) AS chg_age"
    );

    my $query = sprintf(
      'SELECT %s FROM %s WHERE host = ?',
      join(', ', @fields),
      $table
    );

    my $sth = $dbh->prepare($query);
    my $r = $sth->execute($host->name);
    die "Database query failed\n" .  $sth->errstr() . "\n" unless $r;
    while(my $h = $sth->fetchrow_hashref()) {
      hash_create_index(
        \%old, $h,
        map { $h->{lc($_)}; } @object_index
      );
      $old_row_count++;
    }

    # debugging output
    if($debug_fh && $old_row_count) {
      printf $debug_fh "--> LOADED %d CURRENT ROWS, DUMP FOLLOWS\n",
        $old_row_count;
      print $debug_fh Dumper(\%old), "\n";
      print $debug_fh "--> CURRENT ROWS DUMP END\n";
    }

  #--- collect update plan; there are three conceptual steps:
  #--- 1. entries that do not exist in %old (= loaded from database) will be
  #---    inserted as new
  #--- 2. entries that do exist in %old will be updated in place
  #--- 3. entries that do exist in %old but not in $object (= retrieved via
  #---    SNMP) will be deleted

    $tx->add(
      sprintf(
        'UPDATE snmp_%s SET fresh = false WHERE host = ?',
        $snmp_object->name
      ),
      $host->name
    );

  #--- iterate over the SNMP-loaded data

    hash_iterator(
      $object,
      scalar(@object_index),
      sub {
        my $leaf = shift;
        my @idx = @_;
        my $val_old = hash_index_access(\%old, @idx);
        my (@fields, @values, $query, @cond);

  #--- UPDATE - note, that we are not actually checking, if the data
  #--- changed; just existence of the same (host, @index) will cause all
  #--- columns to be overwritten with new values and 'chg_when' field
  #--- updated

        if($val_old) {
          $stats{'update'}++;
          $tx->add(
            sprintf(
              'UPDATE snmp_%s SET %s WHERE %s',
              $snmp_object->name,
              join(',', (
                'chg_when = current_timestamp',
                'fresh = true',
                map { "$_ = ?" } @{$snmp_object->columns}
              )),
              join(' AND ', map { "$_ = ?" } ('host', @object_index))
            ),
            ( map {
              $leaf->{$_}{'enum'} // $leaf->{$_}{'value'} // undef
            } @{$snmp_object->columns} ),
            $host->name, @idx,
          );

  #--- set the age of the entry to zero, so it's not selected for deletion

          $val_old->{'chg_age'} = 0;
        }

  #--- INSERT

        else {
          $stats{'insert'}++;
          $tx->add(
            sprintf(
              'INSERT INTO snmp_%s ( %s ) VALUES ( %s )',
              $snmp_object->name,
              join(',',
                ('host', 'fresh', @object_index, @{$snmp_object->columns})
              ),
              join(',',
                ('?') x (2 + @object_index + @{$snmp_object->columns})
              ),
            ),
            $host->name, 't', @idx,
            map {
              $leaf->{$_}{'enum'} // $leaf->{$_}{'value'} // undef
            } @{$snmp_object->columns}
          );
        }
      }
    );

  #--- DELETE

    my $dbmaxage = $snmp_object->dbmaxage // undef;
    if(defined $dbmaxage) {
      hash_iterator(
        \%old,
        scalar(@object_index),
        sub {
          my $leaf = shift;
          my @idx = splice @_, 0;

          if($leaf->{'chg_age'} > $dbmaxage) {
            $stats{'delete'}++;
            $tx->add(
              sprintf(
                'DELETE FROM snmp_%s WHERE %s',
                $snmp_object->name,
                join(' AND ', map { "$_ = ?" } ('host', @{$snmp_object->index}))
              ),
              $host->name, @idx
            );
          }
        }
      );
    }

  #--- debug output

    if($debug_fh) {
      printf $debug_fh
        "--> UPDATE PLAN INFO (%d rows, %d inserts, %d updates, %d deletes)\n",
        $tx->count, @stats{'insert','update', 'delete'};
    }

  #--- perform database transaction

    if($tx->count) {
      my $e = $tx->commit;
      die $e if $e;
    }

  }

  #=========================================================================
  #=== catch block =========================================================
  #=========================================================================

  catch ($err) {
    printf $debug_fh "--> ERROR: %s", $err if $debug_fh;
  }

  # finish
  close($debug_fh) if $debug_fh;
  return $err // \%stats;
}



1;
