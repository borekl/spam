#!/usr/bin/env perl

#=============================================================================
# Encapsulate loading and managing configuration.
#=============================================================================

package SPAM::Config;

use v5.10;
use warnings;
use integer;
use strict;

use Moo;
with 'MooX::Singleton';

use Carp;
use JSON::MaybeXS;
use Path::Tiny qw(path);
use DBI;



#=============================================================================
#=== ATTRIBUTES ==============================================================
#=============================================================================

# configuration file

has config_file => (
  is => 'ro',
  default => 'spam.cfg.json',
);

# parsed configuration

has config => (
  is => 'lazy',
  builder => '_load_config',
);

# database connection handles
# This is used to cache DBI connection handles in a way that makes them
# available in the whole application. These handles should only be used
# through the SPAM::Db wrapper class.

has dbconn => (
  is => 'ro',
  default => sub { {} },
);



#=============================================================================
#=== METHODS =================================================================
#=============================================================================

#=============================================================================
# Load and parse configuration
#=============================================================================

sub _load_config
{
  my ($self) = @_;
  my $file = $self->config_file();
  if(!-e $file) {
    croak "Configuration file '$file' cannot be found or read";
  }
  my $cfg = JSON->new->relaxed(1)->decode(path($file)->slurp());

  return $cfg;
}


#=============================================================================
# Get DBI handle for supplied configured connection id. This handles local
# caching of the handles, so that there's only one handle per process.
#=============================================================================

sub get_dbi_handle
{
  my ($self, $dbid) = @_;
  my $cfg;
  my %dbi_params = ( AutoCommit => 1, pg_enable_utf => 1, PrintError => 0 );

  #--- sanity checks

  if(!exists $self->config()->{'dbconn'}) {
    croak qq{Database configuration section missing};
  }
  $cfg = $self->config()->{'dbconn'};

  if(!$dbid) {
    croak qq{Invalid argument in SPAM::Config::get_dbi_handle()};
  }

  if(!exists $cfg->{$dbid}) {
    croak qq{Undefined database connection id "$dbid"};
  }
  $cfg = $cfg->{$dbid};

  #--- if already connected, just return the handle

  if(exists $self->dbconn()->{$dbid}) {
    return $self->dbconn()->{$dbid};
  }

  #--- otherwise try to connect to the database

  my $dsn = 'dbi:Pg:db=' . $cfg->{'dbname'};
  $dsn .= ';host=' . $cfg->{'dbhost'} if $cfg->{'dbhost'};

  my $dbh = DBI->connect(
    $dsn,
    $cfg->{'dbuser'},
    $cfg->{'dbpass'},
  );

  if(!ref($dbh)) {
    return DBI::errstr();
  }

  #--- finish

  $self->dbconn()->{$dbid} = $dbh;
  return $dbh;
}



#=============================================================================

1;