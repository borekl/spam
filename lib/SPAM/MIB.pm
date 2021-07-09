#=============================================================================
# Encapsulate SNMP MIB configuration
#=============================================================================

package SPAM::MIB;

use v5.10;
use warnings;
use integer;
use strict;

use Moo;


#=============================================================================
#=== ATTRIBUTES ==============================================================
#=============================================================================

# SNMP MIB name

has name => (
  is => 'ro',
  required => 1
);

# reference to MIB configuration

has config => (
  is => 'ro',
  required => 1,
  isa => sub { die 'SPAM::MIB::config must be a hashref' unless ref $_[0] }
);

#=============================================================================

sub iter_objects
{
  my ($self, $cb) = @_;
  my $mib = $self->config;

  foreach my $object (@{$mib->{objects}}) {
    $cb->($object);
  }
}

#=============================================================================

1;
