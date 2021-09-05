package SPAM::Model::Mactable;

# code for interfacing with the 'mactable' database table

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

# hostname of a device the data in this instance belong to
has hostname => (
  is => 'ro', coerce => sub { lc $_[0] }, predicate => 1
);

# macs loaded from database
has _macdb => ( is => 'lazy' );

#------------------------------------------------------------------------------
sub _build__macdb ($self)
{
  my $dbh = SPAM::Config->instance->get_dbx_handle('spam')->dbh;
  my %mactable;

  my $sth = $dbh->prepare('SELECT mac, host, portname, active FROM mactable');
  $sth->execute;
  while(my $row = $sth->fetchrow_hashref) {
    $mactable{$row->{mac}} = $row;
  }

  return \%mactable;
}

#------------------------------------------------------------------------------
sub get_mac ($self, $mac) { $self->_macdb->{$mac} // undef }

#------------------------------------------------------------------------------


1;
