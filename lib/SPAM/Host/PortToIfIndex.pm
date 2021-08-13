package SPAM::Host::PortToIfIndex;

use Moo::Role;
use experimental 'signatures';
use Carp;

requires qw(snmp has_iftable);

# portname to ifindex hash
has port_to_ifindex => ( is => 'lazy' );

#------------------------------------------------------------------------------
# create port-to-ifindex hash from SNMP data
sub _build_port_to_ifindex ($self)
{
  my %by_ifindex;
  my $m = $self->mesg;
  my $cnt_prune = 0;

  # feedback message
  $m->('[%s] Pruning non-ethernet interfaces (started)', $self->name) if $m;

  # ifTable needs to be loaded, otherwise fail
  croak q{ifTable not loaded, cannot create 'port_to_ifindex' attribute}
  unless $self->has_iftable;

  # helper for accessing ifIndex
  my $_if = sub { $self->snmp->{'IF-MIB'}{'ifTable'}{$_[0]} };
  my $_ifx = sub { $self->snmp->{'IF-MIB'}{'ifXTable'}{$_[0]} };

  # iterate over entries in the ifIndex table
  foreach my $if (keys %{$self->snmp->{'IF-MIB'}{'ifTable'}}) {
    if(
      $_if->($if)->{'ifType'}{'enum'} ne 'ethernetCsmacd'
      || $_ifx->($if)->{'ifName'}{'value'} =~ /^vl/i
    ) {
      # matching interfaces are deleted, FIXME: this is probably not needed
      delete $self->snmp->{'IF-MIB'}{'ifTable'}{$if};
      delete $self->snmp->{'IF-MIB'}{'ifXTable'}{$if};
      $cnt_prune++;
    } else {
      $by_ifindex{$if} = $_ifx->($if)->{'ifName'}{'value'};
    }
  }

  $m->(
    '[%s] Pruning non-ethernet interfaces (finished, %d pruned)',
    $self->name, $cnt_prune
  ) if $m;

  # turn ifindex->portname into portname->ifindex hash
  return { reverse %by_ifindex };
}

1;
