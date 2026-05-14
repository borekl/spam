package SPAM::Model::SNMP::VoiceVlans;

# interface to CISCO-VLAN-MEMBERSHIP-MIB::vmVoiceVlanTable

use Moo::Role;
use experimental 'signatures';
use List::MoreUtils qw(uniq);

requires '_d';

has voice_vlans => ( is => 'lazy' );

sub _build_voice_vlans ($self)
{
  my $s = $self->_d;
  my %voice_vlans;

  if(
    exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}
    && exists $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmVoiceVlanTable'}
  ) {
    my @ifs = keys $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmVoiceVlanTable'}->%*;
    foreach my $if (@ifs) {
      my $vlan = $s->{'CISCO-VLAN-MEMBERSHIP-MIB'}{'vmVoiceVlanTable'}{$if}{vmVoiceVlanId}{value};
      $voice_vlans{$vlan} = 1
    }
  }
  return [ sort keys %voice_vlans ];
}

1;
