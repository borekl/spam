package SPAM::Misc;

# miscellaneous functions library; this is the remnant of previously
# all-encompassing SPAM.pm library that contained everything non-SNMP related
# that was not in the main script

require Exporter;
use lib 'lib';
use integer;
use warnings;
use strict;
use experimental 'signatures';
use Carp;
use Feature::Compat::Try;
use Mojo::JSON;

use SPAM::Config;

our @ISA = qw(Exporter);
our @EXPORT = qw(
  tty_message
  compare_ports
  sql_site_uses_cp
  multipush
  file_lineread
  sql_show_query
  hash_create_index
  hash_iterator
  hash_index_access
  query_reduce
  decode_age
  vlans_bitstring_to_range_list
  maintenance
  remove_undefs
  js_bool
);

#=== FUNCTIONS =================================================================

#-------------------------------------------------------------------------------
# display message on a TTY, do nothing on anything else
sub tty_message ($msg, @args)
{
  if(!defined $msg) { $msg = "done\n"; }
  printf($msg, @args) if -t STDOUT;
}

#-------------------------------------------------------------------------------
# parse switch port designation (as in ifName) into an array of sub-tokens
# (returned as array-ref)
sub parse_port ($port)
{
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

#-------------------------------------------------------------------------------
# compare two switch port names for sorting purposes, mode 0 is 'numbers first',
# 1 'types first'
sub compare_ports ($port1, $port2, $mode)
{
  # process input
  my $p1 = parse_port($port1);
  my $p2 = parse_port($port2);
  if(!ref($p1) || !ref($p2)) { return undef; }

  # perform separate type/num comparisons
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

  # integrate result
  if($comp_type == $comp_num) { return $comp_type; }
  if($comp_type == 0) { return $comp_num; }
  if($comp_num == 0) { return $comp_type; }
  if(!$mode) { return $comp_num; }
  return $comp_type;
}

#-------------------------------------------------------------------------------
# check if given site uses two-level connection hierarchy (switch-cp-outlet) or
# single-level hierarchy (switch-outlet).
sub sql_site_uses_cp ($site)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;

  croak q{Undefined argument 'site'} unless $site;
  croak q{Database connection failed} unless ref $db;

  my $r = $db->select('out2cp', 'site', undef, {
    group_by => [ 'site' ], having => { site => lc $site }
  });
  return 1 if $r->rows == 1;

  return 0;
}

#-------------------------------------------------------------------------------
# Function to push values into multiple arrays with single function call. The
# arrays are supplied to this function as list of arrayrefs and function that
# will push values to all the arrays at once is returned. This exists to make
# preparing database quieries simpler and more readable (since this entails
# creating arrays of field names and values).
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

#-------------------------------------------------------------------------------
# function for line-reading files; the callback can abort reading the rest of
# the file by returning true; returns error message or undef
sub file_lineread ($file, $open_mode, $cb)
{
  open(my $fh, $open_mode, $file) || return 'Failed to open file';
  while(my $l = <$fh>) {
    chomp($l);
    last if $cb->($l);
  }
  close($fh);
  return undef;
}

#-------------------------------------------------------------------------------
# receives SQL query with ? placeholders and an array values and replaces the
# placeholders with the values and returns the result; this is used to pretty
# display the queries for debug purposes
sub sql_show_query ($query, @values)
{
  # squash extraneous whitespace, replace newlines
  $query =~ s/\n/ /g;
  $query =~ s/\s{2,}/ /g;

  # do the placeholders replacement
  for my $val (@values) {
    if(defined $val) {
      $val = "'$val'" if $val !~ /^\d+$/;
    } else {
      $val = 'NULL';
    }
    $query =~ s/\?/$val/;
  }

  # finish
  return $query;
}

#-------------------------------------------------------------------------------
# Utility function for creating hash indexes. The arguments are:
#
#   1. hashref of a point from which the index will be built
#   2. value which will be put as leaf R. the rest is list of indices
#
# Let's suppose we have hash %h, value 123 and list of indexes 'a', 'b' and 'c'.
# The invocation looks like this:
#
#   hash_create_index(\%h, 123, 'a', 'b', 'c')
#
# The hash will look like this after this call:
#
#   %h = ( 'a' => { 'b' => { 'c' => 123 } } )
#
# Subsequent calls on the same hash will non-destructively add more indexes:
#
#   hash_create_index(\%, 456, 'a', 'b', 'd')
#
# For resulting hash:
#
#   %h = ( 'a' => { 'b' => { 'c' => 123, 'd' => 456 } } );
#
# The number of indices must not vary though, otherwise unexpected behaviour can
# result.
#
# If the leaf value already exists and both this value and the new value
# supplied in argument 2 are hashref, then the function will merge these two
# hashrefs into one unified hash.  If the two values are not both hashrefs, then
# the old value in the hash will be overwritten with the new.
sub hash_create_index
{
  my $h = shift;    # 1. href / mount point
  my $v = shift;    # 2. any  / value
  my $g = $h;

  for(my $i = 0; $i < scalar(@_) - 1; $i++) {
    my $index = $_[$i];
    $g->{$index} = {} if !exists $g->{$index};
    $g = $g->{$index}
  }

  my $last_index = $_[scalar(@_)-1];
  if(
    exists $g->{$last_index}
    && ref($g->{$last_index}) eq 'HASH'
    && defined $v
    && ref($v) eq 'HASH'
  ) {
    my %h = ( %{$g->{$last_index}}, %$v );
    $g->{$last_index} = \%h;
  } else {
    $g->{$last_index} = $v;
  }
}

#-------------------------------------------------------------------------------
# hash iterator with specified maximum depth of iteration
sub hash_iterator ($h, $depth, $cb, $rec=undef)
{
  if(!defined $rec) { $rec = []; }
  for my $key (keys %$h) {
    my $rec_inner = [ @$rec ];
    if(ref($h->{$key}) && $depth-1) {
      hash_iterator($h->{$key}, $depth-1, $cb, [ @$rec_inner, $key]);
    } else {
      $cb->($h->{$key}, (@$rec_inner, $key));
    }
  }
}

#-------------------------------------------------------------------------------
# function for accessing complex hash tree using path indices
sub hash_index_access ($h, @idx)
{
  for my $k (@idx) {
    if(ref $h && exists $h->{$k}) {
      $h = $h->{$k}
    } else {
      return undef;
    }
  }
  return $h;
}

#-------------------------------------------------------------------------------
# Remove duplicate rows from a query result (array of hashrefs). Duplicity is
# based on list of key names (fields from database row). Only the first
# occurence of the duplicate rows is retained.
sub query_reduce ($query_result, @fields)
{
  my @reduced_result;

  for my $row (@$query_result) {
    if(!grep {
      my $found = 1;
      for my $field (@fields) {
        if($row->{$field} ne $_->{$field}) {
          $found = 0;
          last;
        }
      }
      $found;
    } @reduced_result) {
      push(@reduced_result, $row);
    }
  }
  return \@reduced_result;
}

#-------------------------------------------------------------------------------
# convert textual age specification (such as 1d20h etc) into seconds; if unit is
# omitted, it defaults to days
sub decode_age ($age_txt)
{
  my $age_seconds = 0;

  if($age_txt =~ /^\d+$/) {
    return $age_txt * 86400;
  }

  my @components = split(/(?<=[a-z])/, $age_txt);

  for (@components) {
    /^([0-9]+)([a-z])/i;
    my ($n, $t) = ($1, $2);
    if($t eq 's') {
      $age_seconds += $n;
    } elsif($t eq 'm') {
      $age_seconds += $n * 60;
    } elsif($t eq 'h') {
      $age_seconds += $n * 3600;
    } elsif($t eq 'd') {
      $age_seconds += $n * 86400;
    }
  }

  return $age_seconds;
}

#-------------------------------------------------------------------------------
# convert bitstring value (from PgSQL's bit() type) returned as the "vlans"
# field to two lists: vlan list and vlan list with ranges coalesced. For example
# '10110111' yields ('1-3','5-6','8')
sub vlans_bitstring_to_range_list ($vlans)
{
  # other variables
  my @vlan_list;
  my @vlan_list_coalesced;

  # get a vlan list
  for(my $vlan = 0; $vlan < length($vlans); $vlan++) {
    my $v = substr($vlans, $vlan, 1);
    if($v eq '1') {
      push(@vlan_list, $vlan);
    };
  }

  # coalesce ranges
  my ($start, $end);
  my @result;

  for my $v (@vlan_list) {

    if(defined $end && $v-1 > $end) {
      push(@vlan_list_coalesced, $start == $end ? "$start" : "$start-$end");
      $start = $end = undef;
    }

    if(!defined $start) {
      $end = $start = $v;
      next;
    }

    if(!defined $end) {
      $end = $v;
      next;
    }

    if($v-1 == $end) {
      $end++;
    }
  }

  if(defined $start) {
    push(@vlan_list_coalesced, $start == $end ? "$start" : "$start-$end");
  }

  # finish
  return \@vlan_list, \@vlan_list_coalesced;
}

#-------------------------------------------------------------------------------
# this is just an untested copy of legacy maintenance code; FIXME: this should
# be in the SPAM::Host class
sub maintainance
{
  my $cfg = SPAM::Config->instance;
  my $db = $cfg->get_mojopg_handle('spam')->db;
  my $t = time();

  $db->txn(sub ($tx) {
    # arptable purging
    $tx->query(
      q{DELETE FROM arptable WHERE (? - date_part('epoch', lastchk)) > ?},
      $t, $cfg->arptableage
    );
    # mactable purging
    $tx->query(
      q{DELETE FROM mactable WHERE (? - date_part('epoch', lastchk)) > ?},
      $t, $cfg->mactableage
    );

    # status table purging
    $tx->query(
      q{DELETE FROM status WHERE (? - date_part('epoch', lastchk)) > ?},
      $t, 7776000 # 90 days
    );

  });
}

#-------------------------------------------------------------------------------
# Function to remove keys for a hash that have undefined values. This does not
# iterate over sub-hashes.
sub remove_undefs ($h)
{
  while(my ($key, $value) = each %$h) {
    delete $h->{$key} if !defined $value;
  }
}

#-------------------------------------------------------------------------------
# Return JSON boolean value of an argument.
sub js_bool ($v) { $v ? Mojo::JSON->true : Mojo::JSON->false }

1;
