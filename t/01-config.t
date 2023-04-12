use strict;
use warnings;
use experimental 'postderef';
use Test2::V0;
use Path::Tiny;

use SPAM::Config;

my $config_file = 'spam.cfg.json.example';
my $cfg;

# instance creation
isa_ok(
  $cfg = SPAM::Config->new(config_file => $config_file), 'SPAM::Config'
);

# MIBs
is(scalar($cfg->mibs->@*), 13, 'MIB count');
isa_ok($_, 'SPAM::Config::MIB') foreach ($cfg->mibs->@*);

# finish
done_testing();
