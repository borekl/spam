#!/usr/bin/perl

# example of loading SNMP table from database

use v5.24;
use strict;
use warnings;
use lib 'lib';

use Data::Dumper;

use SPAM::Config;
use SPAM::Host;
use SPAM::Model::SNMPDbTable;

# table we want to load
my $table = 'entPhysicalTable';

# object that configures this table (this is taken from the master
# configuration file)
my $obj = SPAM::Config->instance->find_object($table);

# host to be loaded, this must be represented by instance of SPAM::Host
my $host = SPAM::Host->new(name => 'stos20');

# instantiate the model class
my $db = SPAM::Model::SNMPDbTable->new(host => $host, obj => $obj);

# load and dump the data (internal lazy attribute triggers load upon first use)
say Dumper($db->_db);
