package SPAM::Model::SNMP::ActiveVlans;

use Moo::Role;
use experimental 'signatures';
use List::MoreUtils qw(uniq);

requires '_d';

has active_vlans => ( is => 'lazy' );

sub _build_active_vlans ($self)
{
  return [
    uniq sort { $a <=> $b } (@{$self->auth_vlans}, @{$self->static_vlans})
  ];
}

1;
