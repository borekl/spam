package SPAM::Model::SNMP::TrunkVlans;

use Moo::Role;
use experimental 'signatures';

requires '_d';

# Helper function to concatenate the bitstrings that represent enabled VLANs
# on a trunk (gleaned from vlaTrunkPortVlansEnabled group of columns).
# Filling in of ommited values is also performed here.
sub trunk_vlans_bitstring ($self, $if)
{
  no autovivification;

  my ($trunk_vlans, $e);

  # return undef if required SNMP data are not present
  return undef
  unless $e = $self->_d->{'CISCO-VTP-MIB'}{'vlanTrunkPortTable'}{$if};
  return undef
  unless $e->{'vlanTrunkPortVlansEnabled'}{'bitstring'};

  # perform concatenation and filling in zeroes
  for my $key (qw(
    vlanTrunkPortVlansEnabled
    vlanTrunkPortVlansEnabled2k
    vlanTrunkPortVlansEnabled3k
    vlanTrunkPortVlansEnabled4k
  )) {
    my $v = '';
    my $l = 0;
    if(exists $e->{$key}{'bitstring'}) {
      $v = $e->{$key}{'bitstring'};
      $l = length($v);
    }
    if($l > 1024) {
      warn('Trimming excessive number of bits from $key');
      $v = substr($v, 0, 1024);
      $l = 1024;
    }
    if($l < 1024) {
      $v .= ('0' x (1024 - $l));
    }
    $trunk_vlans .= $v;
  }

  return $trunk_vlans;
}

1;
