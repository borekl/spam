package SPAM::Host::PortFlags;

use Moo::Role;
use experimental 'signatures';

requires 'snmp';

# port flags cache
has _port_flags => (
  is => 'ro',
  default => sub {{}},
);

my %flag_map = (
  cdp                =>     1,
  stp_fstart         =>     2,
  stp_root           =>     4,
  trunk_dot1q        =>     8,
  trunk_isl          =>    16,
  trunk_unknown      =>    32,
  pauth_funauth      =>    64,
  pauth_fauth        =>   128,
  pauth_auto         =>   256,
  pauth_authorized   =>   512,
  pauth_unauthorized =>  1024,
  mac_bypass         =>  2048,
  poe                =>  4096,
  poe_enabled        =>  8192,
  poe_deliver        => 16384
);

# extract various flags from information scattered in the host instance
sub get_port_flags ($self, $if)
{
  no autovivification;
  use warnings FATAL => 'all';
  my $s = $self->snmp->_d;
  my @flags;

  # use cached value if available
  return $self->_port_flags->{$if}
  if exists $self->_port_flags->{$if};

  # trunking mode
  if(exists $s->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}) {

    my $trunk_flag;
    my $s = $s->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}{$if};
    my $trunk_dynstat = $s->{'vlanTrunkPortDynamicStatus'}{'enum'};

    if($trunk_dynstat && $trunk_dynstat eq 'trunking') {
      $trunk_flag = $s->{'vlanTrunkPortEncapsulationOperType'}{'enum'};
      if($trunk_flag eq 'dot1Q')  { push(@flags, 'trunk_dot1q') }
      elsif($trunk_flag eq 'isl') { push(@flags, 'trunk_isl') }
      elsif($trunk_flag)          { push(@flags, 'trunk_unknown') }
    }
  }

  # 802.1x authentication (from dot1xAuthConfigTable)
  if(exists $s->{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}) {
    my %dot1x_flag;
    my $s
    = $s->{'IEEE8021-PAE-MIB'}{'dot1xAuthConfigTable'}{$if};

    $dot1x_flag{'pc'} = $s->{'dot1xAuthAuthControlledPortControl'}{'enum'};
    $dot1x_flag{'st'} = $s->{'dot1xAuthAuthControlledPortStatus'}{'enum'};

    # for some reason some ports do not have entry in this table, I don't know
    # why; consider the 'if' statement a workaround done without understanding
    # what is going on
    if($dot1x_flag{'pc'} && $dot1x_flag{'st'}) {
      if($dot1x_flag{'pc'} eq 'forceUnauthorized') { push(@flags, 'pauth_funauth') }
      if($dot1x_flag{'pc'} eq 'auto') { push(@flags, 'pauth_auto') }
      if($dot1x_flag{'pc'} eq 'forceAuthorized') { push(@flags, 'pauth_fauth') }
      if($dot1x_flag{'st'} eq 'authorized') { push(@flags, 'pauth_authorized') }
      if($dot1x_flag{'st'} eq 'unauthorized') { push(@flags, 'pauth_unauthorized') }
    }
  }

  # MAC bypass
  if(
    exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}
  ) {
    my $s = $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}{$if};
    for my $sessid (keys %$s) {
      if(
        exists $s->{$sessid}{'macAuthBypass'}
        && exists $s->{$sessid}{'macAuthBypass'}{'cafSessionMethodState'}
        && exists $s->{$sessid}{'macAuthBypass'}{'cafSessionMethodState'}{'enum'}
        && $s->{$sessid}{'macAuthBypass'}{'cafSessionMethodState'}{'enum'} eq 'authcSuccess'
      ) {
        push(@flags, 'mac_bypass');
      }
    }
  }

  # CDP

  if(exists $s->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if}) {
    push(@flags, 'cdp');
  }

  # power over ethernet
  if(
    exists $s->{'POWER-ETHERNET-MIB'}{'pethPsePortTable'}
    && $self->has_ifindex_to_portindex
  ) {
    my $pi = $self->ifindex_to_portindex->{$if};
    if(
      ref $pi && @$pi
      && exists $s->{'POWER-ETHERNET-MIB'}{'pethPsePortTable'}{$pi->[0]}{$pi->[1]}{'pethPsePortDetectionStatus'}
    ) {
      my $s = $s->{'POWER-ETHERNET-MIB'}
                      {'pethPsePortTable'}
                      {$pi->[0]}{$pi->[1]}
                      {'pethPsePortDetectionStatus'};

      push(@flags, 'poe');
      push(@flags, 'poe_enabled') if $s->{'enum'} ne 'disabled';
      push(@flags, 'poe_deliver') if $s->{'enum'} eq 'deliveringPower';
    }
  }

  # STP root
  if(exists $s->{'BRIDGE-MIB'}{'dot1dStpRootPort'}) {
    my $dot1d_stpr = $s->{'BRIDGE-MIB'}{'dot1dStpRootPort'}{'0'};
    for my $vlan (keys %{$s->{'BRIDGE-MIB'}}) {
      # the keys under BRIDGE-MIB are both a) vlans b) object names
      # that are not defined per-vlan (such as dot1dStpRootPort);
      # that's we need to filter non-vlans out here
      next if $vlan !~ /^\d+$/;
      if(
        exists $s->{'BRIDGE-MIB'}{$vlan}{'dot1dBasePortTable'}{$dot1d_stpr}
      ) {
        push(@flags, 'stp_root');
        last;
      }
    }
  }

  # STP fast start
  if(
    exists $s->{'CISCO-STP-EXTENSIONS-MIB'}{'stpxFastStartPortTable'}
    && $self->has_ifindex_to_dot1d
  ) {
    my $port_dot1d = $self->ifindex_to_dot1d->{$if};
    if($port_dot1d) {
      my $portmode
      = $s->{'CISCO-STP-EXTENSIONS-MIB'}
                {'stpxFastStartPortTable'}{$port_dot1d}{'stpxFastStartPortMode'}
                {'enum'};
      if($portmode eq 'enable' || $portmode eq 'enableForTrunk') {
        push(@flags, 'stp_fstart');
      }
    }
  }

  # finish
  my $re = 0;
  foreach my $f (@flags) { $re += $flag_map{$f} }
  return $self->_port_flags->{$if} = $re;
}


1;
