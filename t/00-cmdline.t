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
  call inhibit_poll    => U();
}, 'Default values');

# binary switches without side effects
$cmd = SPAM::Cmdline->new(cmdline => join(' ',
  '--noswitch --arptable --nomactable --autoreg'
));
is($cmd, object {
  call switch      => F();
  call arptable    => T();
  call mactable    => F();
  call autoreg     => T();
}, 'Binary switches without side-effects');

# switch --arpservers
$cmd = SPAM::Cmdline->new(cmdline => '--arpservers');
is($cmd, object {
  call list_arpservers => T();
  call no_lock => T();
  call inhibit_poll => '--arpservers';
}, 'Special action switch --arpservers');

# switch --hosts
$cmd = SPAM::Cmdline->new(cmdline => '--hosts');
is($cmd, object {
  call list_hosts => T();
  call no_lock => T();
  call inhibit_poll => '--hosts';
}, 'Special action switch --hosts');

# switch --quick
$cmd = SPAM::Cmdline->new(cmdline => '--quick');
is($cmd, object {
  call mactable => F();
  call arptable => F();
}, 'Shortcut switch --quick');

# switch --maint
$cmd = SPAM::Cmdline->new(cmdline => '--maint');
is($cmd, object {
  call maintenance => T();
  call inhibit_poll => '--maint';
}, 'Special action switch --maint');

# switch --remove
$cmd = SPAM::Cmdline->new(cmdline => '--remove=myhost123');
is($cmd, object {
  call remove_host => 'myhost123';
  call inhibit_poll => '--remove';
}, 'Special action switch --remove');

# switch --worklist
$cmd = SPAM::Cmdline->new(cmdline => '--worklist');
is($cmd, object {
  call list_worklist => T();
  call inhibit_poll => '--worklist';
}, 'Special action switch --worklist');

# finish
done_testing();
