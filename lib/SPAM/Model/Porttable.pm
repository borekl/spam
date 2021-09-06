package SPAM::Model::Porttable;

# code for loading 'porttable' for the purposes of the collector script where
# this information is used for compiling some statistics and for port
# autoregistration; 'porttable' is purely manually maintained mapping between
# switch ports and network outlets (wall sockets, patch panel sockets etc.)

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

# hostname of the device
has hostname => ( required => 1, is => 'ro', coerce => sub ($h) { lc $h } );

# contents of portable
has porttable => ( is => 'ro', builder => 1 );

#------------------------------------------------------------------------------
# Load porttable from the backend database
sub _build_porttable ($self)
{
  my $dbh = SPAM::Config->instance->get_dbx_handle('spam')->dbh;
  my %p;

  # ensure we have database
  croak 'Database connection failed (spam)' unless ref $dbh;

  # perform database query
  my $sth = $dbh->prepare('SELECT portname, cp FROM porttable WHERE host = ?');
  $sth->execute($self->hostname);

  # process the result
  while(my ($port, $cp) = $sth->fetchrow_array) {
    my $site = substr($self->hostname, 0, 3);
    $p{$port} = { cp => $cp, site => $site };
  }

  # finish
  return \%p;
}

#------------------------------------------------------------------------------
# return true if given (host, portname) is in the porttable
sub exists ($self, $p) { exists $self->porttable->{$p} }

#------------------------------------------------------------------------------
# insert new entry into the porttable
sub insert ($self, $dbh, %args)
{
  my $site = substr($args{host}, 0, 3);
  return $dbh->do(
    'INSERT INTO porttable (host,portname,cp,site,chg_who) VALUES (?,?,?,?,?)',
    undef,
    $args{host}, $args{port}, $args{cp}, $args{site} // $site, 'swcoll'
  );
}

1;
