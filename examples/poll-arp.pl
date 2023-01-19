#!/usr/bin/perl

# this example shows retrieval of ARP table from a host and updating the
# backend database with the data

use strict;
use lib 'lib';
use experimental 'signatures';
use SPAM::Host;
use SPAM::Misc;

# create a host instance with hostname and tag it as ARP source; also define
# callback for displaying poll progress information
my $h = SPAM::Host->new(
  name => 'stos00',
  roles => [ 'arpsource' ],
  mesg => sub ($s, @arg) {
    tty_message("$s\n", @arg);
  }
);

# retrieve ARP table from the host
$h->poll;

# update backend database with the new information
$h->update_db;
