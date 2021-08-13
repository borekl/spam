package SPAM::Model::PortStatus;

# code for interfacing with the 'status' database table

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

# hostname of a device the data in this instance belong to
has hostname => (
  is => 'ro',
  required => 1,
  coerce => sub { lc $_[0] },
);

# port status data loaded from database
has status => (
  is => 'lazy',
);

# fields we are loading from the db; FIXME: this should be implemented as
# a database view
my @fields = (
  'portname', 'status', 'inpkts', 'outpkts',
  q{date_part('epoch', lastchg) AS lastchg},
  q{date_part('epoch', lastchk) AS lastchk},
  'vlan', 'descr', 'duplex', 'rate',
  'flags', 'adminstatus', 'errdis',
  q{floor(date_part('epoch',current_timestamp) - date_part('epoch',lastchg)) AS age},
  'vlans'
);

#------------------------------------------------------------------------------
# builder for status
sub _build_status ($self)
{
  my $dbx = SPAM::Config->instance->get_dbx_handle('spam');
  croak 'Database connection failed' unless $dbx;
  my %status;

  $dbx->run(fixup => sub ($dbh) {
    my $sth = $dbh->prepare(
      sprintf('SELECT %s FROM status WHERE host = ?', join(',', @fields))
    );
    $sth->execute($self->hostname);
    while(my $row = $sth->fetchrow_hashref) {
      # mangle values from ifOperStatus and ifAdminStatus; FIXME: is this
      # needed?
      $row->{status} =~ tr/0/2/;
      $row->{adminstatus} =~ tr/0/2/;
      $status{$row->{portname}} = $row;
    }
  });

  return \%status;
}

#------------------------------------------------------------------------------
# return list of ports
sub list_ports ($self)
{
  return keys %{$self->status}
}

1;
