package SPAM::Model::SNMP::Bridge;

# interface to BRIDGE-MIB

use Moo::Role;
use experimental 'signatures';
use Carp;

requires '_d';

# ifIndex to BRIDGE-MIB index
has ifindex_to_dot1d => ( is => 'lazy', predicate => 1 );

# dot1d to ifIndex
has dot1d_to_ifindex => ( is => 'lazy', predicate => 1 );

#------------------------------------------------------------------------------
# builder for ifindex_to_dot1d
sub _build_ifindex_to_dot1d ($self)
{
  my %by_dot1d;
  my $s = $self->_d;

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

#------------------------------------------------------------------------------
# builder for dot1d_to_ifindex, requires infindex_to_dot1d
sub _build_dot1d_to_ifindex ($self)
{
  my $if2dot1d = $self->ifindex_to_dot1d;
  return { reverse %$if2dot1d };
}

#------------------------------------------------------------------------------
# return port number of spanning tree root port
sub stp_root_port ($self)
{
  my $s = $self->_d;
  if(
    exists $s->{'BRIDGE-MIB'}
    && exists $s->{'BRIDGE-MIB'}{'dot1dStpRootPort'}
    && exists $s->{'BRIDGE-MIB'}{'dot1dStpRootPort'}{'0'}
  ) {
    return $s->{'BRIDGE-MIB'}{'dot1dStpRootPort'}{'0'}{'value'};
  } else {
    return undef;
  }
}

1;
