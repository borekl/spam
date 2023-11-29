package SPAM::Model::SNMP::Bridge;

# interface to BRIDGE-MIB

use Moo::Role;
use experimental 'signatures';
use Carp;

requires '_d';

# ifIndex to BRIDGE-MIB index
has ifindex_to_dot1d => ( is => 'lazy' );

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

#------------------------------------------------------------------------------
sub iterate_macs ($self, $cb)
{
  my $s = $self->_d->{'BRIDGE-MIB'};
  my @vlans = grep(/^\d+$/, keys %$s);

  my $normalize = sub {
    join(':', map { length($_) == 2 ? $_ : '0' . $_; } split(/:/, shift));
  };

  for my $vlan (@vlans) {
    for my $mac (keys %{$s->{$vlan}{'dot1dTpFdbTable'}}) {
      my $dot1dTpFdbTable = $s->{$vlan}{'dot1dTpFdbTable'};
      my $dot1dBasePortTable = $s->{$vlan}{'dot1dBasePortTable'};

      # get base index, macs with index of 0 are are not interesting (management
      # macs etc.)
      my $dot1d = $dot1dTpFdbTable->{$mac}{'dot1dTpFdbPort'}{'value'};
      next unless $dot1d;

      # get port's ifindex and name; NOTE: for some reason sometimes there is no
      # mapping to ifIndex for a MAC -- such MACs are ignored
      my $if = $dot1dBasePortTable->{$dot1d}{'dot1dBasePortIfIndex'}{'value'};
      next unless $if;
      my $p = $self->ifindex_to_port->{$if};

      # skip uninteresting MACs (note, that we're not filtering 'static'
      # entries: ports with port security seem to report their MACs as static in
      # Cisco IOS)
      next if
        $dot1dTpFdbTable->{$mac}{'dot1dTpFdbStatus'}{'enum'} eq 'invalid' ||
        $dot1dTpFdbTable->{$mac}{'dot1dTpFdbStatus'}{'enum'} eq 'self';

      # don't consider MAC on ports we are not tracking
      next unless exists $self->ifindex_to_port->{$if};

      # don't consider MACs on ports that receive CDP
      next if exists $self->_d->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if};

      # normalize MAC (FIXME: do we need this?)
      my $mac_n = $normalize->($mac);

      # invoke callback
      $cb->(mac => $mac_n, if => $if, dot1d => $dot1d, p => $p);
    }
  }
}

1;
