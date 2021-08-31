package SPAM::Model::SNMP::PortTable;

# interface to CISCO-STACK-MIB portTable

use Moo::Role;
use experimental 'signatures';
use Carp;

requires '_d';

# ifIndex to (portModuleIndex, portIndex), some CISCO MIBs use this
has ifindex_to_portindex => ( is => 'lazy', predicate => 1 );

#------------------------------------------------------------------------------
# builder function for ifindex_to_portindex
sub _build_ifindex_to_portindex ($self)
{
  my %by_portindex;
  my $s = $self->_d;

  # check prerequisites; this is not universally supported, so failure to
  # statisfy should be just silently skipped
  if(
    exists $s->{'CISCO-STACK-MIB'}
    && exists $s->{'CISCO-STACK-MIB'}{'portTable'}
  ) {
    my $t = $s->{'CISCO-STACK-MIB'}{'portTable'};

    for my $idx_mod (keys %$t) {
      for my $idx_port (keys %{$t->{$idx_mod}}) {
        $by_portindex{$t->{$idx_mod}{$idx_port}{'portIfIndex'}{'value'}}
        = [ $idx_mod, $idx_port ];
      }
    }
  }

  return \%by_portindex;
}

#------------------------------------------------------------------------------
# getter for portTable object
sub porttable ($self, $p, $f)
{
  # CISCO-STACK-MIB missing (newer devices no longer support this)
  return undef unless %{$self->ifindex_to_portindex};

  # get ifIndex
  my $if = $self->port_to_ifindex->{$p};
  croak "Port '$p' does not appear to exist" unless defined $if;

  # get portIndex (apparently, ports without entry in portTable can appear)
  my $pi = $self->ifindex_to_portindex->{$if};
  return undef unless $pi;

  return $self->_d->{'CISCO-STACK-MIB'}{'portTable'}{$pi->[0]}{$pi->[1]}{$f}{'value'};
}

1;
