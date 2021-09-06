package SPAM::Model::SwStat;

# code for interfacing with 'swstat' backend table

use Moo;
use v5.12;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

has hostname => (
  is => 'ro',
  required => 1,
);

has boottime => (
  is => 'lazy',
);

sub _build_boottime ($self)
{
  my $dbh = SPAM::Config->instance->get_dbi_handle('spam');
  croak 'Database connection failed' unless ref $dbh;

  my $qry = q{SELECT date_part('epoch', boot_time) FROM swstat WHERE host = ?};
  my $sth = $dbh->prepare($qry);
  my $r = $sth->execute($self->hostname);
  my ($v) = $sth->fetchrow_array();
  return $v;
}

1;
