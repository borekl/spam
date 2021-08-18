package SPAM::Model::SNMP::Boottime;

# code for getting boot time from SNMP sysUpTimeInstance

use Moo::Role;
use experimental 'signatures';

requires '_d';

has boottime => ( is => 'lazy' );

sub _build_boottime ($self)
{
  my $s = $self->_d;

  if(
    %{$s}
    && $s->{'SNMPv2-MIB'}
    && $s->{'SNMPv2-MIB'}{'sysUpTimeInstance'}
  ) {
    my $uptime = $s->{'SNMPv2-MIB'}{'sysUpTimeInstance'}{undef}{'value'};
    return time() - int($uptime / 100);
  } else {
    return undef;
  }
}

1;
