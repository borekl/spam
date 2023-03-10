package SPAM::Model::SNMP::EntityTree;

use Moo::Role;
use experimental 'signatures';

use SPAM::Entity;
use SPAM::EntityTree;

requires '_d';

# processed ENTITY-MIB information (SPAM::EntityTree instance)
has entity_tree => ( is => 'lazy' );

# build a hash-tree that represents entPhysicalTable returned by host; the
# elements of the three are SPAM::Entity instances
sub _build_entity_tree ($self)
{
  my $s = $self->_d;
  # ensure the necessary entries exist; if they don't, just bail out
  return undef
  unless
    exists $s->{'ENTITY-MIB'}
    && exists $s->{'ENTITY-MIB'}{'entPhysicalTable'};

  #--- convert the ENTITY-MIB into an array of SPAM::Entity instances

  my $ePT = $s->{'ENTITY-MIB'}{'entPhysicalTable'};
  my $eAMT = $s->{'ENTITY-MIB'}{'entAliasMappingTable'} // undef;
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
