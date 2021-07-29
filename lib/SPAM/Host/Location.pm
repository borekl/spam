package SPAM::Host::Location;

use Moo::Role;
use experimental 'signatures';

# SNMP sysLocation
has location => ( is => 'lazy' );

# location builder
sub _build_location ($self)
{
  if(
    %{$self->snmp}
    && $self->snmp->{'SNMPv2-MIB'}
    && $self->snmp->{'SNMPv2-MIB'}{'sysLocation'}
  ) {
    return $self->snmp->{'SNMPv2-MIB'}{'sysLocation'}{0}{value};
  } else {
    return undef;
  }
}

1;
