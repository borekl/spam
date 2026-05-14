package SPAM::Model::SNMP::ActiveVlans;

# this role collates all VLANs we know about into a single list

use Moo::Role;
use experimental 'signatures';
use List::MoreUtils qw(uniq);

requires '_d';

has active_vlans => ( is => 'lazy' );

sub _build_active_vlans ($self)
{
  return [
    uniq sort { $a <=> $b } (
      $self->auth_vlans->@*,
      $self->static_vlans->@*,
      $self->voice_vlans->@*
    )
  ];
}

1;
