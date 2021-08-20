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
sub oper_status ($self, $p) { $self->status->{$p}{status} }
sub admin_status ($self, $p) { $self->status->{$p}{adminstatus} }
sub packets_in ($self, $p) { $self->status->{$p}{inpkts} }
sub packets_out ($self, $p) { $self->status->{$p}{outpkts} }
sub vlan ($self, $p) { $self->status->{$p}{vlan} }
sub vlans ($self, $p) { $self->status->{$p}{vlans} }
sub descr ($self, $p) { $self->status->{$p}{descr} }
sub duplex ($self, $p) { $self->status->{$p}{duplex} }
sub speed ($self, $p) { $self->status->{$p}{rate} }
sub flags ($self, $p) { $self->status->{$p}{flags} }
sub errdisable ($self, $p) { $self->status->{$p}{errdis} }

#------------------------------------------------------------------------------
# delete given ports; this is supposed to be wrapped in an transaction
sub delete_ports ($self, @ports)
{
  my $dbh = SPAM::Config->instance->get_dbx_handle('spam')->dbh;

  foreach my $p (@ports) {
    $dbh->do(
      'DELETE FROM status WHERE host = ? AND portname = ?', undef,
      $self->hostname, $p
    );
  }
}

#------------------------------------------------------------------------------
# insert ports with values supplied from SNMP; this is supposed to be wrapped in
# a transaction
sub insert_ports ($self, $snmp, @ports)
{
  my $dbh = SPAM::Config->instance->get_dbx_handle('spam')->dbh;

  my $f = join(',', qw(
    host portname status inpkts outpkts ifindex vlan descr
    duplex rate flags adminstatus errdis vlans lastchg lastchk
  ));

  my $sth = $dbh->prepare(
    "INSERT INTO status ($f) VALUES " .
    '(?,?,?,?,?,?,?,?,?,?,?,?,?,?,current_timestamp,current_timestamp)',
  );

  foreach my $p (@ports) {
    $sth->execute(
      $self->hostname,
      $p,
      $snmp->iftable($p, 'ifOperStatus') == 1 ? 't' : 'f',
      $snmp->iftable($p, 'ifInUcastPkts'),
      $snmp->iftable($p, 'ifOutUcastPkts'),
      $snmp->port_to_ifindex->{$p},
      $snmp->vm_membership_table($p, 'vmVlan'),
      $snmp->iftable($p, 'ifAlias'),
      $snmp->porttable($p, 'portDuplex'),
      $snmp->iftable($p, 'ifSpeed'),
      $snmp->get_port_flags($p),
      $snmp->iftable($p, 'ifAdminStatus') == 1 ? 't' : 'f',
      'f',
      $snmp->trunk_vlans_bitstring($p)
    );
  }
}

#------------------------------------------------------------------------------
# update ports with values supplied from SNMP; this is supposed to be wrapped in
# a transaction
sub update_ports ($self, $snmp, @ports)
{
  my $dbh = SPAM::Config->instance->get_dbx_handle('spam')->dbh;

  my $f = join(',', map { "$_ = ?" } qw(
    host portname status inpkts outpkts ifindex vlan descr
    duplex rate flags adminstatus errdis vlans
  ));

  my $sth = $dbh->prepare(
    "UPDATE status SET $f, ".
    'lastchg = current_timestamp, lastchk = current_timestamp ' .
    'WHERE host = ? AND portname = ?'
  );

  foreach my $p (@ports) {
    $sth->execute(
      $self->hostname,
      $p,
      $snmp->iftable($p, 'ifOperStatus') == 1 ? 't' : 'f',
      $snmp->iftable($p, 'ifInUcastPkts'),
      $snmp->iftable($p, 'ifOutUcastPkts'),
      $snmp->port_to_ifindex->{$p},
      $snmp->vm_membership_table($p, 'vmVlan'),
      $snmp->iftable($p, 'ifAlias'),
      $snmp->porttable($p, 'portDuplex'),
      $snmp->iftable($p, 'ifSpeed'),
      $snmp->get_port_flags($p),
      $snmp->iftable($p, 'ifAdminStatus') == 1 ? 't' : 'f',
      'f',
      $snmp->trunk_vlans_bitstring($p),
      $self->hostname,
      $p
    );
  }
}

#------------------------------------------------------------------------------
# update only 'lastchk' field for all supplied ports
sub touch_ports ($self, @ports)
{
  my $dbh = SPAM::Config->instance->get_dbx_handle('spam')->dbh;

  foreach my $p (@ports) {
    $dbh->do(
      'UPDATE status SET lastchk = current_timestamp ' .
      'WHERE host = ? AND portname = ?', undef,
      $self->hostname, $p
    );
  }
}

1;
