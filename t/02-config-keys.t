use strict;
use warnings;
use Test2::V0;
use Path::Tiny;

use SPAM::Config::Keys;

my $keys_file = 'authkeys.cfg.example';

# instance creation
my $cfg;
isa_ok(
  $cfg = SPAM::Config::Keys->new(keys_file => $keys_file), 'SPAM::Config::Keys'
);

# token replacement
is($cfg->fill('%0'), 'password123', 'token replacement (1)');
is($cfg->fill('%12%%'), 'secr3t2%', 'token replacement (2)');
is($cfg->fill('--%2--'), '--s3s4m3--', 'token replacement (3)');
is($cfg->fill('abcd123'), 'abcd123', 'token replacement (4)');
is($cfg->fill('%9'), '', 'token replacement (5)');

# finish
done_testing();
