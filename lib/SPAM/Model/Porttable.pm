package SPAM::Model::Porttable;

# code for loading 'porttable' for the purposes of the collector script where this
# information is used for compiling some statistics and for port autoregistration

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

has porttable => (
  is => 'ro',
  builder => 1,
);

sub _build_porttable ($self)
{
  my $dbh = SPAM::Config->instance->get_dbi_handle('spam');
  my %p;

  # ensure we have database
  croak 'Database connection failed (spam)' unless ref $dbh;

  # perform database query
  my $sth = $dbh->prepare(
    'SELECT host, portname, cp FROM porttable'
  );
  my $r = $sth->execute;
  croak 'Database query failed (spam, ' . $sth->errstr . ')' unless $r;

  # process the result
  while(my ($host, $port, $cp) = $sth->fetchrow_array) {
    my $site = substr($host, 0, 3);
    $p{$host}{$port} = { cp => $cp, site => $site };
  }

  # finish
  return \%p;
}

# return true if given (host, portname) is in the porttable

sub exists ($self, $h, $p)
{
  return exists $self->porttable->{$h}{$p};
}

# insert new entry into the porttable, this only returns the SQL insert with
# its bind values (we use sql_transaction() to actually send the insert into
# the db)

sub insert ($self, %args)
{
  my $site = substr($args{host}, 0, 3);
  [
    'INSERT INTO porttable (host,portname,cp,site,chg_who) VALUES (?,?,?,?,?)',
    $args{host}, $args{port}, $args{cp}, $args{site} // $site, 'swcoll'
  ]
}

1;
