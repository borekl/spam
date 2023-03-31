package SPAM::Model::Mactable;

# code for interfacing with the 'mactable' database table

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

# hostname of a device the data in this instance belong to
has hostname => ( is => 'ro', predicate => 1 );

# macs loaded from database
has _macdb => ( is => 'lazy' );

#------------------------------------------------------------------------------
sub _build__macdb ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my %mactable;

  my $r = $db->select('mactable', [ qw(mac host portname active) ]);
  while(my $row = $r->hash) {
    $mactable{$row->{mac}} = $row;
  }

  return \%mactable;
}

#------------------------------------------------------------------------------
# set the 'active' field to 'false' for all MACs associated with the host
sub reset_active_mac ($self, $db)
{
  $db->update(
    mactable => { active => 0 }, { host => $self->hostname, active => 1 }
  )
}

#------------------------------------------------------------------------------
sub insert_or_update ($self, $db, %data)
{
  my %update = (
    host     => $self->hostname,
    portname => $data{p},
    lastchk  => \'current_timestamp',
    active   => 1,
  );

  $db->insert(
    'mactable',
    { mac => $data{mac}, %update },
    { on_conflict => [ mac => \%update ] }
  );
}

1;
