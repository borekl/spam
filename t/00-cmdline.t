use strict;
use warnings;
use Test2::V0;

use SPAM::Cmdline;

# instance creation
isa_ok(my $cmd = SPAM::Cmdline->new, 'SPAM::Cmdline');

# check defaults
is($cmd, object {
  call debug           => F();
  call switch          => T;
  call arptable        => F();
  call mactable        => T;
  call autoreg         => F();
  call hosts           => array { end() };
  call hostre          => U();
  call forcehost       => F();
  call hostinfo        => F();
  call tasks           => 8;
  call remove_host     => U();
  call maintenance     => F();
  call list_arpservers => F();
  call list_worklist   => F();
  call list_hosts      => F();
  call no_lock         => F();
}, 'Default values');

# binary switches without side effects
$cmd = SPAM::Cmdline->new(cmdline => join(' ',
  '--noswitch --arptable --nomactable --maint --autoreg'
));
is($cmd, object {
  call switch      => F();
  call arptable    => T();
  call mactable    => F();
  call maintenance => T();
  call autoreg     => T();
}, 'Binary switches without side-effects');

# switch --arpservers
$cmd = SPAM::Cmdline->new(cmdline => '--arpservers');
is($cmd, object {
  call list_arpservers => T();
  call no_lock => T();
}, 'Binary switch --arpservers');

# switch --hosts
$cmd = SPAM::Cmdline->new(cmdline => '--hosts');
is($cmd, object {
  call list_hosts => T();
  call no_lock => T();
}, 'Binary switch --hosts');

# switch --quick
$cmd = SPAM::Cmdline->new(cmdline => '--quick');
is($cmd, object {
  call mactable => F();
  call arptable => F();
}, 'Shortcut switch --quick');

# finish
done_testing();
