#=============================================================================
# Module to interface with command-line options.
#=============================================================================

package SPAM::Cmdline;

use v5.10;
use Moo;
with 'MooX::Singleton';
use experimental 'signatures';

use Getopt::Long qw(GetOptionsFromString);
use Scalar::Util qw(looks_like_number);

# enable debugging mode
has debug => ( is => 'rwp' );

# turn switch data polling on or off
has switch => ( is => 'rwp', default => 1 );

# turn polling for ARP table on or off
has arptable => ( is => 'rwp' );

# turn getting bridging table on or off
has mactable => ( is => 'rwp', default => 1 );

# turn autoregistration of outlets on or off
has autoreg => ( is => 'rwp' );

# hosts to be polled (by enumeration)
has hosts => (
  is => 'rwp',
  default => sub { [] },
);

# hosts to be polled (by regular expression)
has hostre => ( is => 'rwp', predicate => 1 );

# force poll of a host (or multiple hosts) regardless of its registration in the
# source database, this lets user to quickly probe ad hoc hosts; if this option
# is used with --host or --hostre options all matching hosts are processed; if
# neither of these options is specified, only forced hosts are processed
has forcehost => ( is => 'rwp', predicate => 1 );

# only get hostinfo, display it and quit
has hostinfo => ( is => 'rwp' );

# number of concurrent tasks to be run
has tasks => (
  is => 'rwp',
  default => 8,
);

# remove a host from database
has remove_host => ( is => 'rwp' );

# execute maintenance tasks
has maintenance => ( is => 'rwp' );

# list known ARP servers and exit
has list_arpservers => ( is => 'rwp' );

# list switches that would be processed and exit
has list_worklist => ( is => 'rwp' );

# list known hosts and exit
has list_hosts => ( is => 'rwp' );

# no locking needed
has no_lock => ( is => 'rwp' );

# normal polling behaviour should be inhibited
has inhibit_poll => ( is => 'rwp' );

# migrate database schema // '' means migrate to the newest version, otherwise
# the value is considered a version number to migrate to
has migrate => ( is => 'rwp');

#-----------------------------------------------------------------------------
# initialize the object according to the command-line options given
sub BUILD ($self, $args)
{
  my @options = (
    'host=s'     => sub { $self->_add_host(split(/,/, $_[1])) },
    'hostre=s'   => sub { $self->_set_hostre($_[1]) },
    'force-host=s' => sub {
      $self->_set_forcehost([]) unless $self->has_forcehost;
      push(@{$self->forcehost}, $_[1]);
    },
    'switch!'    => sub { $self->_set_switch($_[1]) },
    'arptable!'  => sub { $self->_set_arptable($_[1]) },
    'mactable!'  => sub { $self->_set_mactable($_[1]) },
    'maint'      => sub {
      $self->_set_maintenance($_[1]);
      $self->_set_inhibit_poll('--maint');
    },
    'quick'      => sub { $self->_set_mactable(0); $self->_set_arptable(0); },
    'hostinfo',  => sub { $self->_set_hostinfo(1) },
    'arpservers' => sub {
      $self->_set_list_arpservers($_[1]);
      $self->_set_no_lock(1);
      $self->_set_inhibit_poll('--arpservers');
    },
    'hosts'      => sub {
      $self->_set_list_hosts($_[1]);
      $self->_set_no_lock(1);
      $self->_set_inhibit_poll('--hosts');
    },
    'tasks=i'    => sub {
      if($_[1] < 1 || $_[1] > 16) { die '--tasks must be between 1 and 16'; }
      $self->_set_tasks($_[1]);
    },
    'autoreg'    => sub { $self->_set_autoreg($_[1]) },
    'remove=s'   => sub {
      $self->_set_remove_host($_[1]);
      $self->_set_inhibit_poll('--remove');
    },
    'worklist'   => sub {
      $self->_set_list_worklist($_[1]);
      $self->_set_no_lock(1);
      $self->_set_inhibit_poll('--worklist');
    },
    'migrate:s'  => sub {
      if($_[1] eq '' || (looks_like_number($_[1]) && $_[1] >= 0)) {
        $self->_set_migrate($_[1]);
        $self->_set_inhibit_poll('--migrate');
      } else {
        die '--migrate value must be either non-negative integer or not present';
      }
    },
    'debug'      => \$ENV{'SPAM_DEBUG'},
    'help|?'     => sub { help(); exit(0); }
  );

  # if invoked with 'cmdline' argument, use the value of that argument to parse
  # options from; this is useful for tests
  if(defined $args->{cmdline}) {
    if(!GetOptionsFromString($args->{cmdline}, @options)) { exit(1) }
  }

  # otherwise parse options from @ARGV as usual
  if(!GetOptions(@options)) { exit(1) }
}

#-----------------------------------------------------------------------------
# add host to be processed, this is helper for the BUILD function
sub _add_host
{
  my ($self, @host) = @_;
  my $hosts = $self->hosts();

  $self->_set_hosts($hosts = []) if !ref($hosts);
  push(@$hosts, @host);

  return $self;
}

#-----------------------------------------------------------------------------
# Print help message.
sub help
{
  print <<EOHD;
Usage: spam-collector [OPTIONS]

Options that modify standard processing run:

  --[no]switch    turn polling for switch data on or off (default on)
  --[no]arptable  turn polling for ARP table on or off (default off)
  --[no]mactable  turn getting bridging table on or off (default on)
  --[no]autoreg   turn autoregistration of outlets on or off (default off)
  --quick         equivalent of --noarptable and --nomactable
  --hostinfo      only read basic info, show it and quit
  --host=HOST     poll only HOST, can be used multiple times (default all)
  --hostre=RE     poll only hosts matching the regexp
  --force-host=H  poll host H even if it is not in database
  --tasks=N       number of tasks to be run (N is 1 to 16, default 8)
  --debug         turn on debug mode

Options that initiate special actions and prevent normal processing:

  --remove=HOST   remove HOST from database and exit
  --maint         perform database maintenance and exit
  --arpservers    list known ARP servers and exit
  --worklist      display list of switches that would be processed and exit
  --hosts         list known hosts and exit
  --migrate[=N]   upgrade or downgrade database schema
  --help, -?      this help

EOHD
}

1;
