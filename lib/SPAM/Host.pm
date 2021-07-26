package SPAM::Host;

use Moo;
use strict;
use warnings;
use experimental 'signatures';

# hostname
has name => (
  is => 'ro',
  required => 1,
  coerce => sub { lc $_[0] },
);

# SNMP sysLocation
has location => ( is => 'rw' );

# current boottime (derived from SNMP sysUpTimeInstance)
has boottime => ( is => 'rw' );

# last boottime (loaded from database)
has boottime_prev => ( is => 'rw' );

# platform (loaded SNMP sysObjectID)
has platform => ( is => 'rw' );

#==============================================================================

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

#==============================================================================

1;
