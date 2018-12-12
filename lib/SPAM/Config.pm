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

1;
