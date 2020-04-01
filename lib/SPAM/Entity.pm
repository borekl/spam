#!/usr/bin/env perl

#=============================================================================
# Encapsulate handling ENTITY-MIB entPhysicalTable entries.
#=============================================================================

package SPAM::Entity;

use warnings;
use integer;
use strict;

use Moo;
use Carp;
use Scalar::Util qw(reftype);

use SPAM::Config;

# parent entry, undef for tree root

has parent => (
  is => 'rw',
  isa => sub {
    croak 'Not a SPAM::Entity instance'
    unless ref $_[0] && $_[0]->isa('SPAM::Entity');
  },
);

# array of children

has children => (
  is => 'ro',
  default => sub { [] },
);

# defined in IETF RFC 2737

has entPhysicalIndex        => ( is => 'ro' );
has entPhysicalDescr        => ( is => 'ro' );
has entPhysicalVendorType   => ( is => 'ro' );
has entPhysicalContainedIn  => ( is => 'ro' );
has entPhysicalClass        => ( is => 'ro' );
has entPhysicalParentRelPos => ( is => 'ro' );
has entPhysicalName         => ( is => 'ro' );
has entPhysicalHardwareRev  => ( is => 'ro' );
has entPhysicalFirmwareRev  => ( is => 'ro' );
has entPhysicalSoftwareRev  => ( is => 'ro' );
has entPhysicalSerialNum    => ( is => 'ro' );
has entPhysicalMfgName      => ( is => 'ro' );
has entPhysicalModelName    => ( is => 'ro' );
has entPhysicalAlias        => ( is => 'ro' );
has entPhysicalAssetID      => ( is => 'ro' );
has entPhysicalIsFRU        => ( is => 'ro' );
has entPhysicalMfgDate      => ( is => 'ro' );
has entPhysicalUris         => ( is => 'ro' );

# ifIndex, if it is known (through entAliasMappingTable)

has ifIndex                 => ( is => 'ro' );

# cabling side location, if known (through modwire table)

has location                => ( is => 'ro' );

# process arguments // if argument value is a hashref, we look if the hash
# has 'value' or 'enum' keys; if that is the case, we make the argument value
# that of 'enum' or 'value' (in that order of preference)

around BUILDARGS => sub {
  my $orig = shift;
  my $class = shift;
  my $args = $class->$orig(@_);

  foreach my $arg (keys %$args) {
    my $v = $args->{$arg};
    if(ref $v && reftype $v eq 'HASH') {
      if(exists $v->{'enum'}) {
        $args->{$arg} = $v->{'enum'}
      } elsif (exists $v->{'value'}) {
        $args->{$arg} = $v->{'value'}
      }
    }
  }

  return $args;
};


#------------------------------------------------------------------------------
# Add a new child entity
#------------------------------------------------------------------------------

sub add_child
{
  my ($self, @children) = @_;

  return undef if(!@children);

  my $c = $self->children();

  foreach my $child (@children) {
    die 'Not a SPAM::Entity instance'
    unless ref $child && $child->isa('SPAM::Entity');
    $child->parent($self);
    push(@$c, $child);
  }

  return @children;
}


#------------------------------------------------------------------------------
# Traverse the ancestor chain
#------------------------------------------------------------------------------

sub traverse_parents
{
  my ($self, $cb) = @_;
  my $parent = $self->parent;

  while($parent) {
    $cb->($parent);
    $parent = $parent->parent;
  }
}


#------------------------------------------------------------------------------
# Return list of ancestors (from closes to furthest), optionally filtered with
# a callback.
#------------------------------------------------------------------------------

sub ancestors
{
  my ($self, $cb) = @_;
  my @ancestors;

  $self->traverse_parents(sub {
    push(@ancestors, $_[0]) if !$cb || $cb->($_[0]);
  });

  return @ancestors
}


#------------------------------------------------------------------------------
# Return list of entities filtered from the chain of ancestors by
# entPhysicalClass field.
#------------------------------------------------------------------------------

sub ancestors_by_class
{
  my ($self, $class) = @_;

  return $self->ancestors(sub { $_[0]->entPhysicalClass eq $class});
}


#------------------------------------------------------------------------------
# Return chassis number (or croak if not found)
#------------------------------------------------------------------------------

sub chassis_no
{
  my ($self) = @_;
  my $chassis_no;
  my $chassis;

  # this entity is a chassis itself
  if($self->entPhysicalClass eq 'chassis') {
    $chassis = $self;
  }

  # this entity is something else but chassis
  else {
    ($chassis) = $self->ancestors_by_class('chassis');
    croak "No chassis found for entity " . $self->entPhysicalIndex if !$chassis;
  }

  # get chassis number
  $chassis_no = $chassis->entPhysicalParentRelPos;

  # chassis with position -1 means single chassis, map this value to 1
  if($chassis_no == -1) { $chassis_no = 1; }

  # chassis number mapping through entity-profiles.models.MODEL.chassis_map
  # configuration entry
  my $cfg = SPAM::Config->instance->config;
  if(
    exists $cfg->{'entity-profiles'}
    && exists $cfg->{'entity-profiles'}{'models'}
    && $chassis->entPhysicalModelName
    && exists $cfg->{'entity-profiles'}{'models'}{$chassis->entPhysicalModelName}
    && exists $cfg->{'entity-profiles'}{'models'}{$chassis->entPhysicalModelName}{'chassis_map'}
  ) {
    my $map = $cfg->{'entity-profiles'}{'models'}{$chassis->entPhysicalModelName}{'chassis_map'};
    $chassis_no = $map->{$chassis_no} if exists $map->{$chassis_no};
  }

  # return as integer number
  return int($chassis_no);
}


#------------------------------------------------------------------------------
# Return display string for current entry (intended for debugging)
#------------------------------------------------------------------------------

sub disp
{
  my ($self) = @_;

  return sprintf
    'idx=%d pos=%d name="%s" model="%s" sn="%s" hw="%s" fw="%s" sw="%s"',
    $self->entPhysicalIndex,
    $self->entPhysicalParentRelPos // 0,
    $self->entPhysicalName // '',
    $self->entPhysicalModelName // '',
    $self->entPhysicalSerialNum // '',
    $self->entPhysicalHardwareRev // '',
    $self->entPhysicalFirmwareRev // '',
    $self->entPhysicalSoftwareRev // '';
}


1;
