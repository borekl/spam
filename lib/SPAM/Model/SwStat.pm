package SPAM::Model::SwStat;

# code for interfacing with 'swstat' backend table

use Moo;
use v5.12;
use strict;
use warnings;
use experimental 'signatures';
use Carp;
use POSIX qw(strftime);

use SPAM::Config;

has hostname => (
  is => 'ro',
  required => 1,
);

has boottime => (
  is => 'lazy',
);

#------------------------------------------------------------------------------
sub _build_boottime ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  croak 'Database connection failed' unless ref $db;

  my $r = $db->select('swstat',
    [ \q{date_part('epoch', boot_time)} ],
    { host => $self->hostname }
  );

  return $r->array->@*;
}

#------------------------------------------------------------------------------
# Update record in swstat table; note that we have to pass different attributes
# from the host instance, which feels bit inelegant.
sub update ($self, $snmp, $stat)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my @vtp_stats = $snmp->vtp_stats;

  my %data = (
    host => $self->hostname,
    location => $snmp->location =~ s/'/''/r,
    ports_total => $stat->{p_total},
    ports_active => $stat->{p_act},
    ports_patched => $stat->{p_patch},
    ports_illact => $stat->{p_illact},
    ports_errdis => $stat->{p_errdis},
    ports_inact => $stat->{p_inact},
    ports_used => $stat->{p_used},
    vtp_domain => $vtp_stats[0],
    vtp_mode => $vtp_stats[1],
    boot_time => strftime('%Y-%m-%d %H:%M:%S', localtime($snmp->boottime)),
    platform => $snmp->platform
  );

  my %data_wo_host = %data;
  delete $data_wo_host{host};
  $data_wo_host{chg_when} = \'DEFAULT';

  $db->insert('swstat', \%data, { on_conflict => [ 'host' => \%data_wo_host ] });
}

1;
