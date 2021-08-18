package SPAM::Model::SNMP::PortToIfIndex;

# this role implements portname to ifindex hash -- basic index to access SNMP
# data

use Moo::Role;
use experimental 'signatures';
use Carp;

requires qw(_d has_iftable);

# portname to ifindex hash
has port_to_ifindex => ( is => 'lazy' );

#------------------------------------------------------------------------------
# create port-to-ifindex hash from SNMP data
sub _build_port_to_ifindex ($self)
{
  my $s = $self->_d;
  my %by_ifindex;
  my $cnt_prune = 0;

  # feedback message
  $self->_m('Pruning non-ethernet interfaces (started)');

  # ifTable needs to be loaded, otherwise fail
  croak q{ifTable not loaded, cannot create 'port_to_ifindex' attribute}
  unless $self->has_iftable;

  # helper for accessing ifIndex
  my $_if = sub { $s->{'IF-MIB'}{'ifTable'}{$_[0]} };
  my $_ifx = sub { $s->{'IF-MIB'}{'ifXTable'}{$_[0]} };

  # iterate over entries in the ifIndex table
  foreach my $if (keys %{$s->{'IF-MIB'}{'ifTable'}}) {
    if(
      $_if->($if)->{'ifType'}{'enum'} ne 'ethernetCsmacd'
      || $_ifx->($if)->{'ifName'}{'value'} =~ /^vl/i
    ) {
      # matching interfaces are deleted, FIXME: this is probably not needed
      delete $s->{'IF-MIB'}{'ifTable'}{$if};
      delete $s->{'IF-MIB'}{'ifXTable'}{$if};
      $cnt_prune++;
    } else {
      $by_ifindex{$if} = $_ifx->($if)->{'ifName'}{'value'};
    }
  }

  $self->_m(
    'Pruning non-ethernet interfaces (finished, %d pruned)',
    $cnt_prune
  );

  # turn ifindex->portname into portname->ifindex hash
  return { reverse %by_ifindex };
}

1;
