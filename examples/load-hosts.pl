#!/usr/bin/perl

# list configured sources of informations, both switches and arp sources
# (routers)

use strict;
use lib 'lib';
use experimental 'signatures';
use SPAM::Config;

my $cfg = SPAM::Config->instance;

# make worklist of all hosts, inclue both arpsources and switches
my $hosts_all = $cfg->worklist;

# make worklist of hosts matching a regex; whenever the callback returns undef,
# the entry is completely removed
my $hosts_chr = $cfg->worklist(sub ($h, $v) {
  $h =~ /^chr/ ? $v : undef;
});

# make worklist of only switches; if you want to remove sources, but no the
# whole host, modify the return value
my $switches = $cfg->worklist(sub ($h, $v) {
  [ grep { $_ eq 'switch' } @$v ];
});

print "S - switch,  A - ARP source\n\n";

foreach my $h (sort keys %$hosts_all) {
  print scalar(grep { $_ eq 'switch' } $hosts_all->{$h}->@*) ? 'S' : ' ';
  print scalar(grep { $_ eq 'arpsource' } $hosts_all->{$h}->@*) ? 'A' : ' ';
  print ' ', $h, "\n";
}
