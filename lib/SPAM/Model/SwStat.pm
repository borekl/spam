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
  my $dbh = SPAM::Config->instance->get_dbi_handle('spam');
  croak 'Database connection failed' unless ref $dbh;

  my $qry = q{SELECT date_part('epoch', boot_time) FROM swstat WHERE host = ?};
  my $sth = $dbh->prepare($qry);
  my $r = $sth->execute($self->hostname);
  my ($v) = $sth->fetchrow_array();
  return $v;
}

#------------------------------------------------------------------------------
# Update record in swstat table; note that we have to pass different attributes
# from the host instance, which feels bit inelegant.
sub update ($self, $snmp, $stat)
{
  my $dbh = SPAM::Config->instance->get_dbi_handle('spam');
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

  my @fields = keys %data;
  my @fields_wo_host = grep { $_ ne 'host' } @fields;
  my @values = map { $data{$_} } @fields;

  my $qry_tmpl =
  'INSERT INTO swstat ( %s ) VALUES ( %s ) ON CONFLICT (host) DO UPDATE SET %s';

  my $qry = sprintf(
    $qry_tmpl,
    join(',', @fields),
    join(',', ('?') x scalar(@fields)),
    join(',',
       ( map { "$_ = EXCLUDED." . $_ } @fields_wo_host ),
      'chg_when = DEFAULT'
    )
  );

  return $dbh->do($qry, undef, @values);
}

1;
