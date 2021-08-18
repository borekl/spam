package SPAM::Host::Boottime;

use Moo::Role;
use experimental 'signatures';

use SPAM::Model::Boottime;

requires qw(snmp name);

# current boottime (derived from SNMP sysUpTimeInstance)
has boottime => ( is => 'lazy' );

# last boottime (loaded from database)
has boottime_prev => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    SPAM::Model::Boottime->new(hostname => $self->name)->boottime_db
  }
);

# boottime builder
sub _build_boottime ($self)
{
  my $s = $self->snmp->_d;

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

# return true if the switch seems to have been rebooted since we last checked
# on it; this is slightly imprecise -- the switch returns its uptime as
# timeticks from its boot up and we calculate boot time from local system clock;
# since these two clocks can be misaligned, we're introducing bit of a fudge
# to reduce false alarms
sub is_rebooted ($self)
{
  if($self->boottime && $self->boottime_prev) {
    # 30 is fudge factor to account for imprecise clocks
    if(abs($self->boottime - $self->boottime_prev) > 30) {
      return 1;
    }
  }
  return 0;
}

1;
