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
  my $cfg = SPAM::Config->instance;
  my $db = $cfg->get_mojopg_handle('spam')->db;
  croak 'Database connection failed (spam)' unless ref $db;

  # perform database query
  my $r = $db->select(
    'porttable', [ 'portname', 'cp' ], { host => $self->hostname }
  );

  # process the result
  my %p;
  while(my $row = $r->array) {
    my ($port, $cp) = @$row;
    my $site = $cfg->site_from_hostname($self->hostname);
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
sub insert ($self, $tx, %args)
{
  my $cfg = SPAM::Config->instance;
  my $site = $cfg->site_from_hostname($args{host});
  $tx->insert('porttable', {
    host     => $args{host},
    portname => $args{port},
    cp       => $args{cp},
    site     => $args{site} // $site,
    chg_who  => 'swcoll'
  });
}

1;
