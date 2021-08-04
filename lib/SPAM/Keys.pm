#=============================================================================
# Module for handling keys/passwords used in configuration file. The main
# purpose of this module is to move the security critical data into its own
# file (or maybe something else later).
#
# Upon instantiation, a JSON file is read and parsed (by default
# 'authkeys.json'). It contains something like:
#
# {
#   "0": "pa$$word0",
#   "1": "Secr3t1",
#   "2": "key2"
# }
#
# In the main config you can then use %0, %1, %2 in any value and it will be
# replaced with values from this file. Only values 0..9 are currently
# supported.
#=============================================================================

package SPAM::Keys;

use v5.10;
use warnings;
use integer;
use strict;

use Moo;
use experimental 'signatures';

use Carp;
use JSON::MaybeXS;
use Path::Tiny qw(path);


#=============================================================================
#=== ATTRIBUTES ==============================================================
#=============================================================================

has keys_file => (
  is => 'ro',
  default => 'authkeys.json',
);

has _keys => (
  is => 'lazy',
  predicate => 1,
);


#=============================================================================
#=== BUILDERS ================================================================
#=============================================================================

sub _build__keys ($self)
{
  my $file = $self->keys_file;
  croak "Key file '$file' cannot be found or read" unless -e $file;
  return JSON->new->relaxed(1)->decode(path($file)->slurp());
}

#=============================================================================
#=== METHODS =================================================================
#=============================================================================

# replace placeholders in passed in string that are in the form %N, where N
# is a single numeral 0..9; if the placeholder is used but not defined, it
# is removed from the string

sub fill ($self, $s)
{
  my $keys = $self->_keys;

  # no placeholders, just return the string
  return $s unless $s =~ /%\d/;

  # '%%' is special and stands for single '%'
  $s =~ s/%%/%/g;

  # replace the numeric placeholders
  foreach my $n (0..9) {
    if(exists $keys->{$n}) {
      my $p = '%' . $n;
      my $v = $keys->{$n};
      $s =~ s/$p/$v/g
    } else {
      $s =~ s/%$n//g;
    }
  }

  # finish
  return $s;
}

#=============================================================================

1;
