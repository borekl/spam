package SPAM::Model::SNMP::VmMembershipTable;

# interface with the CISCO-VLAN-MEMBERSHIP-MIB vmMembershipTable

use Moo::Role;
use experimental 'signatures';
use Carp;

requires qw(_d port_to_ifindex);

has static_vlans => ( is => 'lazy' );

sub vm_membership_table ($self, $p, $f)
{
  my $s = $self->_d;
  my $if = $self->port_to_ifindex->{$p};

  croak "Port '$p' does not seem to exist" unless defined $if;

  if(
    exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}
    && exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}
    && exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if}
  ) {
    return $self->_d->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}{$if}{$f}{'value'};
  } else {
    return undef;
  }
}

sub _build_static_vlans ($self)
{
  my $s = $self->_d;
  my %vlans;

  if(
    exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}
    && exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'}
  ) {
    my $vmMembershipTable
    = $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmMembershipTable'};
    for my $if (keys %$vmMembershipTable) {
      my $v = $vmMembershipTable->{$if}{'vmVlan'}{'value'};
      $vlans{$v} = undef if $v > 0 && $v < 1000;
    }
  }

  return [ sort keys %vlans ];
}

1;
