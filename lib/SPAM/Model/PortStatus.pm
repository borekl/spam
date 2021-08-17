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
sub list_ports ($self) { keys %{$self->status} }

#------------------------------------------------------------------------------
# return true if given port exists in the database
sub has_port ($self, $p) { exists $self->status->{$p} }

#------------------------------------------------------------------------------
# port getter functions
sub oper_status ($self, $p) { $self->status->{$p}{adminstatus} }
sub admin_status ($self, $p) { $self->status->{$p}{status} }
sub packets_in ($self, $p) { $self->status->{$p}{inpkts} }
sub packets_out ($self, $p) { $self->status->{$p}{outpkts} }
sub vlan ($self, $p) { $self->status->{$p}{vlan} }
sub vlans ($self, $p) { $self->status->{$p}{vlans} }
sub descr ($self, $p) { $self->status->{$p}{descr} }
sub duplex ($self, $p) { $self->status->{$p}{duplex} }
sub speed ($self, $p) { $self->status->{$p}{rate} }
sub flags ($self, $p) { $self->status->{$p}{flags} }
sub errdisable ($self, $p) { $self->status->{$p}{errdis} }

1;
