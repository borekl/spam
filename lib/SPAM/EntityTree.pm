#!/usr/bin/env perl

#=============================================================================
# Encapsulate handling ENTITY-MIB entPhysicalTable trees.
#=============================================================================

package SPAM::EntityTree;

use warnings;
use integer;
use strict;
use v5.16;

use Moo;
use Carp;
use Scalar::Util qw(blessed reftype);

# tree root

has root => (
  is => 'rw',
  isa => sub {
    croak 'Not a SPAM::Entity instance'
    unless ref $_[0] && $_[0]->isa('SPAM::Entity');
  },
);

# hash that indexes nodes in the tree by their associated ifIndex; note, that
# only port entries have associated ifIndex

has node_by_ifIndex => (
  is => 'ro',
  default => sub { {} },
);


#------------------------------------------------------------------------------
# Constructor code, builds the tree from supplied array of individual entries.
# The individual must be SPAM::Entity instances.
#------------------------------------------------------------------------------

sub BUILD
{
  my ($self, $arg) = @_;

  # check that we got the required argument

  croak 'SPAM::EntityTree requires "entities" argument'
  if !exists $arg->{'entities'};

  croak 'SPAM::EntityTree "entities" argument must be an arrayref'
  if !ref $arg->{'entities'} || !reftype $arg->{'entities'} eq 'ARRAY';

  my $entities = $arg->{'entities'};
  foreach my $e (@$entities) {
    croak '"entities" item is not a SPAM::Entity instance'
    if !blessed $e || !$e->isa('SPAM::Entity');
  }

  # find root element

  my (@root) = grep { !$_->entPhysicalContainedIn } @$entities;

  if(!@root) {
    croak 'Entity table has no root';
  } elsif(@root > 1) {
    croak 'Entity table has multiple roots';
  }

  $self->root($root[0]);

  # recursively build the tree from the array of elements

  my $build = sub {
    my $tree = shift;
    my $entPhysicalIndex = $tree->entPhysicalIndex;

    # find entities that are contained within current subtree
    my (@contained) = grep {
      defined $_->entPhysicalContainedIn
      && $_->entPhysicalContainedIn == $entPhysicalIndex
    } @$entities;

    # terminate this branch if no descendants exist
    return if !@contained;

    # add entry into ifIndex-to-node hash (if ifIndex is defined), add all
    # contained entries into current node and branch into every entry
    foreach my $c (@contained) {
      $self->node_by_ifIndex()->{$c->ifIndex} = $c if $c->ifIndex;
      $tree->add_child($c);
      __SUB__->($c);
    }

    # finish
    return $tree;
  };

  $build->($self->root);
}

#------------------------------------------------------------------------------
# Tree traversal utility function. The arguments in the form of hash are
# 'callback', 'depth' and 'start'. The latter two are optional. The callback
# argument can also be supplied outside of the argument has, in that case it
# must be the first argument.
#
# The callback gets two arguments:  SNMP::Entity instance ref and tree level
# (root being level 0, root children level 1 etc.).
#------------------------------------------------------------------------------

sub traverse
{
  my ($self, @arg) = @_;

  #--- process arguments

  my $cb = shift @arg if @arg % 2;
  my %arg = @arg;

  my $depth = $arg{'depth'} // undef;
  my $start = $arg{'start'} // $self->root;
  $cb = $arg{'callback'} if exists $arg{'callback'};

  return if !$cb;

  #--- perform the traversal

  sub {
    my ($node, $level) = @_;
    $cb->($node, $level);
    foreach my $c (
      sort {
        $a->entPhysicalIndex <=> $b->entPhysicalIndex
      } @{$node->children}
    ) {
      __SUB__->($c, $level + 1) if !defined $depth || $level < $depth;
    }
  }->($start, 0);
}


#------------------------------------------------------------------------------
# Function to compile flat list of SPAM::Entity refs based on callback result
# and additional query parameters. Arguments are given as a hash. Callback
# argument can also be given as the first argument, or omitted completely. All
# arguments that are not callback are passed verbatim to the traverse()
# function.
#------------------------------------------------------------------------------

sub query
{
  my ($self, @args) = @_;
  my @result;

  #--- process arguments

  my $cb = shift @args if @args % 2;
  my %args = @args;
  if(exists $args{'callback'}) {
    $cb = $args{'callback'} ;
  }
  delete $args{'callback'} if $cb && exists $args{'callback'};

  #--- perform the query

  $self->traverse(sub {
    my $entry = shift;
    push(@result, $entry) if !$cb || $cb->($entry);
  }, %args);

  return @result;
}


#------------------------------------------------------------------------------
# Return a list of chassis entities. We are assuming that chassis is either the
# root entity or one level below (in case of stacks).
#------------------------------------------------------------------------------

sub chassis
{
  my ($self) = @_;

  return $self->query(sub {
    $_[0]->entPhysicalClass eq 'chassis'
  }, depth => 1);
}


#------------------------------------------------------------------------------
# Return a list of power supplies' entities.
#------------------------------------------------------------------------------

sub power_supplies
{
  my ($self) = @_;

  return $self->query(sub {
    $_[0]->entPhysicalClass eq 'powerSupply'
  });
}


#------------------------------------------------------------------------------
# Return a list of linecards' entities.
#------------------------------------------------------------------------------

sub linecards
{
  my ($self) = @_;

  return $self->query(sub {
    $_[0]->entPhysicalClass eq 'module'
    && $_[0]->parent
    && $_[0]->parent->parent
    && $_[0]->parent->parent->entPhysicalClass eq 'chassis'
  });
}


#------------------------------------------------------------------------------
# Return a list of power supplies' entities.
#------------------------------------------------------------------------------

sub fans
{
  my ($self) = @_;

  return $self->query(sub {
    $_[0]->entPhysicalClass eq 'fan'
  });
}


#------------------------------------------------------------------------------
# Legacy function that returns the 'hwinfo' structure: a flat arrayref of
# hashes. Eventually we want to move to use the entity tree directly. This
# method entails multiple tree traversal and is very inefficient.
#
# The 'modwire' argument is a list of hashref loaded from the 'modwire' backend
# table, which gives identification of where given linecard is cabled to (for
# linecards that are permanently wired to patchpanels).
#
# FIXME
#------------------------------------------------------------------------------

sub hwinfo
{
  my ($self, $modwire) = @_;
  my @result;

  my @chassis = $self->chassis;
  my @ps = $self->power_supplies;
  my @cards = $self->linecards;
  my @fans = $self->fans;

  for(my $i = 0; $i < @chassis; $i++) {
    push(@result, {
      'm' => $chassis[$i]->chassis_no,
      idx => $chassis[$i]->entPhysicalIndex,
      partnum => $chassis[$i]->entPhysicalModelName,
      sn => $chassis[$i]->entPhysicalSerialNum,
      type => 'chassis',
    })
  }

  for(my $i = 0; $i < @ps; $i++) {
    push(@result, {
      'm' => $ps[$i]->chassis_no,
      idx => $ps[$i]->entPhysicalIndex,
      partnum => $ps[$i]->entPhysicalModelName,
      sn => $ps[$i]->entPhysicalSerialNum,
      type => 'ps',
    })
  }

  for(my $i = 0; $i < @cards; $i++) {

    # linecard number derivation is problematic; entPhysicalParentRelPos
    # of the direct container entity works on most hardware, but on Cat9410R
    # the supervisor it is in slot 5, but the respective container is shown as
    # being number 11; special casing required

    my ($chassis) = $cards[$i]->ancestors_by_class('chassis');
    croak "No chassis found for entity " . $cards[$i]->entPhysicalIndex
    if !$chassis;

    my $linecard_no = int($cards[$i]->parent->entPhysicalParentRelPos);
    if($chassis->entPhysicalModelName eq 'C9410R' && $linecard_no == 11) {
      $linecard_no = 5;
    }

    # find card 'location'
    my $m = $cards[$i]->chassis_no;
    my ($location_entry, $location);
    if($modwire && @$modwire) {
      ($location_entry) = grep {
        $_->{'m'} == $m && $_->{'n'} == $linecard_no
      } @$modwire;
      if($location_entry) {
        $location = $location_entry->{'location'};
      }
    }

    push(@result, {
      'm' => $m,
      'n' => $linecard_no,
      idx => $cards[$i]->entPhysicalIndex,
      partnum => $cards[$i]->entPhysicalModelName,
      sn => $cards[$i]->entPhysicalSerialNum,
      type => 'linecard',
      location => $location,
    })
  }

  for(my $i = 0; $i < @fans; $i++) {
    # only list fans with model name, some devices list every fan in the system
    # which is not very useful
    next if !$fans[$i]->entPhysicalModelName;
    push(@result, {
      'm' => $fans[$i]->chassis_no,
      idx => $fans[$i]->entPhysicalIndex,
      partnum => $fans[$i]->entPhysicalModelName,
      sn => $fans[$i]->entPhysicalSerialNum,
      type => 'fan',
    })
  }

  return \@result;
}


1;
