#!/usr/bin/perl

use strict;
use lib 'lib';
use experimental 'signatures';
use SPAM::Host;
use SPAM::Misc;
use Data::Dumper;

# create a host instance with hostname
my $h = SPAM::Host->new(
  name => 'rcns04',
  roles => [ 'switch' ],
  mesg => sub ($s, @arg) {
    tty_message("$s\n", @arg);
  }
);

# retrieve ARP table from the host
$h->poll;

# dump hwinfo structure (reprocessed entity tree into a flat list of hardware
# components)
print Dumper(
  $h->snmp->entity_tree->hwinfo
);
