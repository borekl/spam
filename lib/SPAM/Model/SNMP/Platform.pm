package SPAM::Model::SNMP::Platform;

use Moo::Role;
use experimental 'signatures';

requires '_d';

# SNMP sysLocation
has platform => ( is => 'lazy' );

# platform builder
sub _build_platform ($self)
{
  my $s = $self->_d;

  if(
    %{$s}
    && $s->{'SNMPv2-MIB'}
    && $s->{'SNMPv2-MIB'}{'sysObjectID'}
  ) {
    my $platform = $s->{'SNMPv2-MIB'}{'sysObjectID'}{0}{'value'};
    $platform =~ s/^.*:://;
    return $platform;
  } else {
    return undef;
  }
}

1;
