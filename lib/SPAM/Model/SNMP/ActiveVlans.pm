package SPAM::Model::SNMP::ActiveVlans;

use Moo::Role;
use experimental 'signatures';

requires '_d';

has active_vlans => ( is => 'lazy' );

sub _build_active_vlans ($self)
{
  my %vlans;
  my $s = $self->_d;

  # dynamic vlan configured by user authentication
  if(
    exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}
    && exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionTable'}
  ) {
    my $cafSessionTable = $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionTable'};
    for my $if (keys %$cafSessionTable) {
      for my $sid (keys %{$cafSessionTable->{$if}}) {
        if(exists $cafSessionTable->{$if}{$sid}{'cafSessionAuthVlan'}) {
          my $v = $cafSessionTable->{$if}{$sid}{'cafSessionAuthVlan'}{'value'};
          $vlans{$v} = undef if $v > 0 && $v < 1000;
        }
      }
    }
  }

  # sort and finish
  return [ sort { $a <=> $b } (keys %vlans, @{$self->static_vlans}) ];
}

1;
