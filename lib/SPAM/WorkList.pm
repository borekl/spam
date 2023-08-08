package SPAM::WorkList;

use Moo;
use experimental 'signatures';

# work list array
has _wl => ( is => 'ro', default => sub { [] } );

#-------------------------------------------------------------------------------
# add host to the work list
sub add ($self, $host)
{
  push($self->_wl->@*, [ $host, undef ]);
  return $self;
}

#-------------------------------------------------------------------------------
# This function finds another task to be scheduled for run.
sub schedule_task ($self)
{
  foreach ($self->_wl->@*) { return $_ unless defined $_->[1] }
  return undef;
}

#-------------------------------------------------------------------------------
# This function sets "pid" field in work list to 0, marking it as finished.
sub clear_task_by_pid ($self, $pid)
{
  foreach ($self->_wl->@*) {
    if($_->[1] == $pid) {
      $_->[1] = 0;
      return $_;
    }
  }
  return undef;
}

1;
