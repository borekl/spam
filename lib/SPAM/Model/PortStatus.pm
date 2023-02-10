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
  \q{date_part('epoch', lastchg) AS lastchg},
  \q{date_part('epoch', lastchk) AS lastchk},
  'vlan', 'descr', 'duplex', 'rate',
  'flags', 'adminstatus', 'errdis',
  \q{floor(date_part('epoch',current_timestamp) - date_part('epoch',lastchg)) AS age},
  'vlans'
);

#------------------------------------------------------------------------------
# builder for status
sub _build_status ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  croak 'Database connection failed' unless $db;

  my %status;

  my $r = $db->select('status', \@fields, { host => $self->hostname});
  while(my $row = $r->hash) {
    $row->{status} =~ tr/0/2/;
    $row->{adminstatus} =~ tr/0/2/;
    $status{$row->{portname}} = $row;
  }

  return \%status;
}

#------------------------------------------------------------------------------
# return list of ports
sub list_ports ($self) { keys %{$self->status} }

#------------------------------------------------------------------------------
# return true if given port exists in the database
sub has_port ($self, $p) { exists $self->status->{$p} }

#------------------------------------------------------------------------------
sub iterate_ports ($self, $cb)
{
  foreach my $portname ($self->list_ports) {
    my $r = $cb->($portname, $self->status->{$portname});
    last if $r;
  }
}

#------------------------------------------------------------------------------
sub get_port ($self, $key, $col=undef)
{
  if(exists $self->status->{$key}) {
    my $row = $self->status->{$key};
    if(defined $col) {
      return $row->{$col};
    } else {
      return $row;
    }
  } else {
    return undef;
  }
}

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
sub delete_ports ($self, $tx, @ports)
{
  foreach my $p (@ports) {
    $tx->delete('status', { host => $self->hostname, portname => $p });
  }
}

#------------------------------------------------------------------------------
# insert ports with values supplied from SNMP; this is supposed to be wrapped in
# a transaction
sub insert_ports ($self, $tx, $snmp, @ports)
{
  foreach my $p (@ports) {
    $tx->insert('status', {
      host        => $self->hostname,
      portname    => $p,
      status      => $snmp->iftable($p, 'ifOperStatus') == 1 ? 't' : 'f',
      inpkts      => $snmp->iftable($p, 'ifInUcastPkts'),
      outpkts     => $snmp->iftable($p, 'ifOutUcastPkts'),
      ifindex     => $snmp->port_to_ifindex->{$p},
      vlan        => $snmp->vm_membership_table($p, 'vmVlan'),
      descr       => $snmp->iftable($p, 'ifAlias'),
      duplex      => $snmp->porttable($p, 'portDuplex'),
      rate        => $snmp->iftable($p, 'ifSpeed'),
      flags       => scalar($snmp->get_port_flags($p)),
      adminstatus => $snmp->iftable($p, 'ifAdminStatus') == 1 ? 't' : 'f',
      errdis      => 'f',
      vlans       => $snmp->trunk_vlans_bitstring($p),
      lastchg     => \'current_timestamp',
      lastchk     => \'current_timestamp',
    });
  }
}

#------------------------------------------------------------------------------
# update ports with values supplied from SNMP; this is supposed to be wrapped in
# a transaction
sub update_ports ($self, $tx, $snmp, @ports)
{
  foreach my $p (@ports) {
    $tx->update('status', {
      host        => $self->hostname,
      portname    => $p,
      status      => $snmp->iftable($p, 'ifOperStatus') == 1 ? 't' : 'f',
      inpkts      => $snmp->iftable($p, 'ifInUcastPkts'),
      outpkts     => $snmp->iftable($p, 'ifOutUcastPkts'),
      ifindex     => $snmp->port_to_ifindex->{$p},
      vlan        => $snmp->vm_membership_table($p, 'vmVlan'),
      descr       => $snmp->iftable($p, 'ifAlias'),
      duplex      => $snmp->porttable($p, 'portDuplex'),
      rate        => $snmp->iftable($p, 'ifSpeed'),
      flags       => scalar($snmp->get_port_flags($p)),
      adminstatus => $snmp->iftable($p, 'ifAdminStatus') == 1 ? 't' : 'f',
      errdis      => 'f',
      vlans       => $snmp->trunk_vlans_bitstring($p),
      lastchg     => \'current_timestamp',
      lastchk     => \'current_timestamp',
    },
    { host => $self->hostname, portname => $p });
  }
}

#------------------------------------------------------------------------------
# update only 'lastchk' field for all supplied ports
sub touch_ports ($self, $tx, @ports)
{
  foreach my $p (@ports) {
    $tx->update('status',
      { lastchk => \'current_timestamp' },
      { host => $self->hostname, portname => $p }
    );
  }
}

1;
