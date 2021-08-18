package SPAM::Host::IfIndexToDot1d;

# role to build an index defined by BRIDGE-MIB's dot1dBasePortTable

use Moo::Role;
use experimental 'signatures';
use Carp;

requires 'snmp';

# ifIndex to BRIDGE-MIB index
has ifindex_to_dot1d => ( is => 'lazy', predicate => 1 );

#------------------------------------------------------------------------------
# builder for ifindex_to_dot1d
sub _build_ifindex_to_dot1d ($self)
{
  my %by_dot1d;
  my $s = $self->snmp->_d;

  if(
    exists $s->{'BRIDGE-MIB'}
    && exists $s->{'CISCO-VTP-MIB'}
    && exists $s->{'CISCO-VTP-MIB'}{'vtpVlanTable'}
    && exists $s->{'CISCO-VTP-MIB'}{'vtpVlanTable'}{1}
  ) {
    my @vlans
    = keys %{
      $s->{'CISCO-VTP-MIB'}{'vtpVlanTable'}{'1'}
    };
    for my $vlan (@vlans) {
      if(
        exists $s->{'BRIDGE-MIB'}{$vlan}
        && exists $s->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
      ) {
        my @dot1idxs
        = keys %{
          $s->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}
        };
        for my $dot1d (@dot1idxs) {
          $by_dot1d{
            $s->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}{$dot1d}{'dot1dBasePortIfIndex'}{'value'}
          } = $dot1d;
        }
      }
    }
  }

  return \%by_dot1d;
}

1;
