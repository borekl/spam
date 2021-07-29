package SPAM::Host::EntityTree;

use Moo::Role;
use experimental 'signatures';

use SPAM::Entity;
use SPAM::EntityTree;

# processed ENTITY-MIB information (SPAM::EntityTree instance)
has entity_tree => ( is => 'lazy' );

# build a hash-tree that represents entPhysicalTable returned by host; the
# elements of the three are SPAM::Entity instances
sub _build_entity_tree ($self)
{
  # ensure the necessary entries exist; if they don't, just bail out
  return undef
  unless
    exists $self->snmp->{'ENTITY-MIB'}
    && exists $self->snmp->{'ENTITY-MIB'}{'entPhysicalTable'};

  #--- convert the ENTITY-MIB into an array of SPAM::Entity instances

  my $ePT = $self->snmp->{'ENTITY-MIB'}{'entPhysicalTable'};
  my $eAMT = $self->snmp->{'ENTITY-MIB'}{'entAliasMappingTable'} // undef;
  my @entries = map {
    SPAM::Entity->new(
      %{$ePT->{$_}},
      entPhysicalIndex => $_,
      ifIndex => $eAMT->{$_}{'0'}{'entAliasMappingIdentifier'}{'value'} // undef,
    )
  } keys %$ePT;

  # finish
  return SPAM::EntityTree->new(entities => \@entries);
}

1;
