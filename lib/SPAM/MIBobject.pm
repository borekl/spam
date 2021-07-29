#=============================================================================
# Encapsulate SNMP MIB object configuration
#=============================================================================

package SPAM::MIBobject;

use v5.10;
use warnings;
use integer;
use strict;

use Moo;


#=============================================================================
#=== ATTRIBUTES ==============================================================
#=============================================================================

# SNMP MIB object name/type/MIB

has name => (
  is => 'ro',
  required => 1
);

has type => (
  is => 'ro',
  required => 1
);

has mib_name => (
  is => 'ro',
  required => 1
);

# reference to MIB object configuration

has config => (
  is => 'ro',
  required => 1,
  isa => sub {
    die 'SPAM::MIBobject::config must be a hashref' unless ref $_[0]
  }
);

# additional info

has include => ( is => 'ro' );
has exclude => ( is => 'ro' );
has dbmaxage => ( is => 'ro' );

has index => (
  is => 'ro',
  default => sub { [] },
  coerce => sub { ref $_[0] ? $_[0] : [ $_[0] ] }
);

has columns => (
  is => 'ro',
  default => sub { [] },
  coerce => sub { ref $_[0] ? $_[0] : [ $_[0] ] }
);

has addmib => (
  is => 'ro',
  default => sub { [] },
  coerce => sub { ref $_[0] ? $_[0] : [ $_[0] ] }
);

has flags => (
  is => 'ro',
  default => sub { [] },
  coerce => sub { ref $_[0] ? $_[0] : [ $_[0] ] }
);

#=============================================================================

sub has_flag
{
  my ($self, $f) = @_;

  return scalar grep { $f eq $_ } @{$self->flags};
}

#=============================================================================

1;
