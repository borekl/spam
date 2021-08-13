package SPAM::Host::IfIndexToPortIndex;

# role to build index based on portTable defined in CISCO-STACK-MIB; some (but
# not all) Cisco devices use this style of indexing; the index we build is
# ifIndex -> (module, port)

use Moo::Role;
use experimental 'signatures';

requires 'snmp';

# ifIndex to (portModuleIndex, portIndex), some CISCO MIBs use this
has ifindex_to_portindex => ( is => 'lazy', predicate => 1 );

#------------------------------------------------------------------------------
# builder function for ifindex_to_portindex
sub _build_ifindex_to_portindex ($self)
{
  my %by_portindex;

  # check prerequisites; this is not universally supported, so failure to
  # statisfy should be just silently skipped
  if(
    exists $self->snmp->{'CISCO-STACK-MIB'}
    && exists $self->snmp->{'CISCO-STACK-MIB'}{'portTable'}
  ) {
    my $t = $self->snmp->{'CISCO-STACK-MIB'}{'portTable'};

    for my $idx_mod (keys %$t) {
      for my $idx_port (keys %{$t->{$idx_mod}}) {
        $by_portindex{$t->{$idx_mod}{$idx_port}{'portIfIndex'}{'value'}}
        = [ $idx_mod, $idx_port ];
      }
    }
  }

  return \%by_portindex;
}

1;
