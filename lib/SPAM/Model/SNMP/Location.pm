package SPAM::Model::SNMP::Location;

use Moo::Role;
use experimental 'signatures';

requires '_d';

# SNMP sysLocation
has location => ( is => 'lazy' );

# location builder
sub _build_location ($self)
{
  my $s = $self->_d;

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
