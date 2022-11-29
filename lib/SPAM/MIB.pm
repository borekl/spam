package SPAM::MIB;

# encapsulate SNMP MIB configuration

use Moo;
use warnings;
use integer;
use strict;
use experimental 'signatures';

use SPAM::MIBobject;

#=== ATTRIBUTES ==============================================================

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

# list of managed objects
has objects => (
  is => 'lazy',
  builder => '_load_objects',
);

#=== METHODS =================================================================

#-----------------------------------------------------------------------------
sub iter_objects ($self, $cb)
{
  foreach my $object (@{$self->objects}) {
    last if $cb->($object);
  }
}

#-----------------------------------------------------------------------------
sub _load_objects ($self)
{
  my $mib = $self->config;
  my @objects;

  foreach my $o (@{$mib->{objects}}) {
    my %def;

    $def{name} = $o->{table} // $o->{scalar} // undef;
    die 'MIB object definition missing table/scalar key' unless $def{name};
    $def{type} = exists $o->{table} ? 'table' : 'scalar';
    $def{config} = $o;
    $def{mib_name} = $mib->{mib};

    foreach my $attr (qw(index columns addmib include exclude dbmaxage flags)) {
      $def{$attr} = $o->{$attr} if exists $o->{$attr};
    }

    push(@objects, SPAM::MIBobject->new(%def));
  }

  return \@objects;
}

#-----------------------------------------------------------------------------

1;
