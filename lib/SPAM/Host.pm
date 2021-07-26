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

# port list ("dbStatus" in the old structure, in fact a hashref with port names
# as keys)

has ports => ( is => 'ro', default => sub {{}} );

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

# add one port as pulled from database by sql_load_status(); FIXME: this needs
# refactoring

sub add_port ($self, $key, @fields)
{
  $fields[0] =~ tr/0/2/;  # ifOperStatus
  $fields[10] =~ tr/0/2/; # ifAdminStatus
  $self->ports->{$key} = [ @fields ];
}

# iterate over ports; semantically same as swdata_status_iter() legacy function

sub iterate_ports ($self, $cb)
{
  foreach my $portname (keys %{$self->ports}) {
    my $r = $cb->($portname, @{$self->ports->{$portname}});
    last if $r;
  }
}

# reimplementation of swdata_status_get() legacy function

sub get_port ($self, $key, $col=undef)
{
  if(exists $self->ports->{$key}) {
    my $row = $self->ports->{$key};
    if(defined $col) {
      return $row->[$col];
    } else {
      return $row;
    }
  } else {
    return undef;
  }
}

#==============================================================================

1;
