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
# set the 'active' field to 'false' for all MACs associated with the host
sub reset_active_mac ($self, $dbh)
{
  return $dbh->do(
    q{UPDATE mactable SET active = 'f' WHERE host = ? and active = 't'},
    undef,
    $self->hostname
  );
}

#------------------------------------------------------------------------------
sub insert_mac ($self, $dbh, %data)
{
  my $f = 'mac,host,portname,lastchk,active';
  return $dbh->do(
    "INSERT INTO mactable ($f) VALUES ( ?,?,?,current_timestamp,? )",
    undef,
    $data{mac}, $self->hostname, $data{p}, 't'
  );
}

#------------------------------------------------------------------------------
sub update_mac ($self, $dbh, %data)
{
  my $f = 'host,portname,lastchk,active';
  return $dbh->do(
    "UPDATE mactable SET host = ?, portname = ?, lastchk = current_timestamp, active = 't' WHERE mac = ?",
    undef,
    $self->hostname, $data{p}, $data{mac}
  );
}

1;
