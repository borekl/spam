package SPAM::Host::Platform;

use Moo::Role;
use experimental 'signatures';

requires 'snmp';

# SNMP sysLocation
has platform => ( is => 'lazy' );

# platform builder
sub _build_platform ($self)
{
  if(
    %{$self->snmp}
    && $self->snmp->{'SNMPv2-MIB'}
    && $self->snmp->{'SNMPv2-MIB'}{'sysObjectID'}
  ) {
    my $platform = $self->snmp->{'SNMPv2-MIB'}{'sysObjectID'}{0}{'value'};
    $platform =~ s/^.*:://;
    return $platform;
  } else {
    return undef;
  }
}

1;
