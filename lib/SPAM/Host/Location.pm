package SPAM::Host::Location;

use Moo::Role;
use experimental 'signatures';

requires 'snmp';

# SNMP sysLocation
has location => ( is => 'lazy' );

# location builder
sub _build_location ($self)
{
  my $s = $self->snmp->_d;

  if(
    %{$s}
    && $s->{'SNMPv2-MIB'}
    && $s->{'SNMPv2-MIB'}{'sysLocation'}
  ) {
    return $s->{'SNMPv2-MIB'}{'sysLocation'}{0}{value};
  } else {
    return undef;
  }
}

1;
