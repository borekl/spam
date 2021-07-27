#=============================================================================
# Module to interface with command-line options.
#=============================================================================

package SPAM::Cmdline;

use v5.10;
use Moo;
with 'MooX::Singleton';

use Getopt::Long;



#=============================================================================
#=== ATTRIBUTES ==============================================================
#=============================================================================

# enable debugging mode

has debug => (
  is => 'rwp',
);

# turn polling for ARP table on or off

has arptable => (
  is => 'rwp',
);

# turn getting bridging table on or off

has mactable => (
  is => 'rwp',
  default => 1,
);

# turn autoregistration of outlets on or off

has autoreg => (
  is => 'rwp',
);

# hosts to be polled (by enumeration)

has hosts => (
  is => 'rwp',
  default => sub { [] },
);

# hosts to be polled (by regular expression)

has hostre => (
  is => 'rwp',
);

# only get hostinfo, display it and quit
has hostinfo => ( is => 'rwp', default => 0 );

# number of concurrent tasks to be run

has tasks => (
  is => 'rwp',
  default => 8,
);

# remove a host from database

has remove_host => (
  is => 'rwp',
);

# execute maintenance tasks

has maintenance => (
  is => 'rwp',
);

# list known ARP servers and exit

has list_arpservers => (
  is => 'rwp',
);

# list switches that would be processed and exit

has list_worklist => (
  is => 'rwp',
);

# list known hosts and exit

has list_hosts => (
  is => 'rwp',
);

# no locking needed

has no_lock => (
  is => 'rwp',
);



#=============================================================================
# Initialize the object according to the command-line options given.
#=============================================================================

sub BUILD
{
  my ($self) = @_;

  if(!GetOptions(
    'host=s'     => sub { $self->_add_host(split(/,/, $_[1])) },
    'hostre=s'   => sub { $self->_set_hostre($_[1]) },
    'arptable!'  => sub { $self->_set_arptable($_[1]) },
    'mactable!'  => sub { $self->_set_mactable($_[1]) },
    'maint'      => sub { $self->_set_maintenance($_[1]) },
    'quick'      => sub { $self->_set_mactable(0); $self->_set_arptable(0); },
    'hostinfo',  => sub { $self->_set_hostinfo(1) },
    'arpservers' => sub {
      $self->_set_list_arpservers($_[1]);
      $self->_set_no_lock(1);
    },
    'hosts'      => sub {
      $self->_set_list_hosts($_[1]);
      $self->_set_no_lock(1);
    },
    'tasks=i'    => sub {
      if($_[1] < 1 || $_[1] > 16) { die '--tasks must be between 1 and 16'; }
      $self->_set_tasks($_[1]);
    },
    'autoreg'    => sub { $self->_set_autoreg($_[1]) },
    'remove=s'   => sub { $self->_set_remove_host($_[1]) },
    'worklist'   => sub {
      $self->_set_list_worklist($_[1]);
      $self->_set_no_lock(1);
    },
    'debug'      => \$ENV{'SPAM_DEBUG'},
    'help|?'     => sub { help(); exit(0); }
  )) {
    exit(1);
  }

}


#=============================================================================
# Add host to be processed, this is helper for the BUILD function.
#=============================================================================

sub _add_host
{
  my ($self, @host) = @_;
  my $hosts = $self->hosts();

  $self->_set_hosts($hosts = []) if !ref($hosts);
  push(@$hosts, @host);

  return $self;
}



#=============================================================================
# Print help message.
#=============================================================================

sub help
{
  print <<EOHD;
Usage: spam.pl [OPTIONS]

Options that modify standard processing run:

  --[no]arptable  turn polling for ARP table on or off (default off)
  --[no]mactable  turn getting bridging table on or off (default on)
  --[no]autoreg   turn autoregistration of outlets on or off (default off)
  --quick         equivalent of --noarptable and --nomactable
  --hostinfo      only read basic info, show it and quit
  --host=HOST     poll only HOST, can be used multiple times (default all)
  --hostre=RE     poll only hosts matching the regexp
  --tasks=N       number of tasks to be run (N is 1 to 16, default 8)
  --debug         turn on debug mode

Options that initiate special actions and prevent normal processing:

  --remove=HOST   remove HOST from database and exit
  --maint         perform database maintenance and exit
  --arpservers    list known ARP servers and exit
  --worklist      display list of switches that would be processed and exit
  --hosts         list known hosts and exit
  --help, -?      this help

EOHD
}



#=============================================================================

1;
