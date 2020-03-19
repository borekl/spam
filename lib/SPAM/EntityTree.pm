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

    # branch into every subtree
    foreach my $c (@contained) {
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
# method entails multiple tree traversal and is very inefficient. FIXME
#------------------------------------------------------------------------------

sub hwinfo
{
  my ($self) = @_;
  my @result;

}


1;
