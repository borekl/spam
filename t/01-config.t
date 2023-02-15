use strict;
use warnings;
use Test2::V0;
use Path::Tiny;

use SPAM::Config;

my $tempdir = Path::Tiny->tempdir;
my $config_file = $tempdir->child("config.$$.json");
$config_file->spew_utf8('{}');

# instance creation
isa_ok(
  my $cfg = SPAM::Config->new(config_file => $config_file), 'SPAM::Config'
);

# finish
done_testing();
