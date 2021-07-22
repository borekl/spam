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
use SPAM::MIB;


#=============================================================================
#=== ATTRIBUTES ==============================================================
#=============================================================================

# configuration file

has config_file => (
  is => 'ro',
  default => 'spam.cfg.json',
);

# parsed configuration

has config => ( is => 'lazy' );

# database connection handles
# This is used to cache DBI connection handles in a way that makes them
# available in the whole application. These handles should only be used
# through the SPAM::Db wrapper class.

has dbconn => (
  is => 'ro',
  default => sub { {} },
);

# list of switches
# this is the list of switches SPAM should talk to, retrieved from backend
# database

has hosts => ( is => 'lazy' );

# list of arp servers
# this is the list of routers SPAM should talk to to retrieve ARP information
# for mapping IPs to MACs

has arpservers => ( is => 'lazy' );

# list of MIBs (SPAM::MIB instances)

has mibs => ( is => 'lazy' );

# known ports, on following switches unpatched ports will be considered
# different port state separate from up/oper down/admin down.

has knownports => ( is => 'lazy' );

# retention period for MAC and ARP entries

has mactableage => ( is => 'lazy' );
has arptableage => ( is => 'lazy' );

# vlan servers list; each element is an array of (host, SNMPv2_community,
# VTP domain)

has vlanservers => (
  is => 'lazy',
  default => sub { [] },
);

#=============================================================================
#=== METHODS =================================================================
#=============================================================================

#=============================================================================
# Load and parse configuration
#=============================================================================

sub _build_config
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
# Close a DBI handle previously opened with get_dbi_handle().
#=============================================================================

sub close_dbi_handle
{
  my ($self, $dbid) = @_;

  #--- is the handle actually open?

  return if !exists $self->dbconn()->{$dbid};

  #--- close the handle

  $self->dbconn()->{$dbid}->disconnect();
  delete $self->dbconn()->{$dbid};

  #--- finish

  return $self;
}


#=============================================================================
# Load list of hosts (switches) from backend database.
#=============================================================================

sub _build_hosts
{
  my ($self) = @_;
  my $dbh = $self->get_dbi_handle('ondb');

  if(!ref $dbh) { die 'Database connection failed (ondb)'; }

  # the v_switchlist view returns tuples (hostname, community, ip_addr)

  my $sth = $dbh->prepare('SELECT * FROM v_switchlist');
  my $r = $sth->execute();
  if(!$r) {
    die 'Failed to load list of switches from database';
  }

  # the way the info is stored is the same as the old $cfg->{'host'} hash

  my %hosts;
  while(my $row = $sth->fetchrow_hashref()) {
    my $h = lc $row->{'hostname'};
    $hosts{$h}{'community'} = $row->{'community'};
    $hosts{$h}{'ip'} = $row->{'ip_addr'};
  }

  return \%hosts;
}


#=============================================================================
# Load list of routers from backend database.
#=============================================================================

sub _build_arpservers
{
  my ($self) = @_;

  my $dbh = $self->get_dbi_handle('ondb');

  if(!ref $dbh) { die 'Database connection failed (ondb)'; }

  # the v_arpservers view returns tuples (hostname, community)

  my $sth = $dbh->prepare('SELECT * FROM v_arpservers');
  my $r = $sth->execute();
  if(!$r) {
    die 'Failed to load list of arpservers from database';
  }

  my @arpservers;
  while(my ($s, $cmty) = $sth->fetchrow_array()) {
    push(@arpservers, [$s, $cmty])
      unless scalar(grep { $_->[0] eq $s } @arpservers) != 0;
  }

  return \@arpservers;

}


#=============================================================================
# Return SNMP configuration block based on supplied hostname
#=============================================================================

sub _get_snmp_config
{
  my ($self, $host) = @_;
  my $cfg = $self->config;

  # no valid snmp section in configuration
  return undef if
    !$cfg->{snmp}          # snmp section does not exist at all
    || !ref $cfg->{snmp}   # snmp section is scalar
    || !@{$cfg->{snmp}};   # snmp section is empty

  # iterate over the snmp config entries
  foreach my $entry (@{$cfg->{snmp}}) {

    # if the entry has no 'hostre' field, it always matches
    return $entry if !$entry->{hostre};

    foreach my $re (@{$entry->{hostre}}) {
      return $entry if $host =~ /$re/i;
    }
  }

  # no matching section was found
  die "Failed to find matching SNMP configuration for $host";
}


#=============================================================================
# Return snmp command and option strings for given (host, mib, oid, vlan)
#=============================================================================

sub get_snmp_command
{
  my ($self, %arg) = @_;
  my $cfg = $self->config;

  my $host = $arg{host} // '';
  my $cmd  = $arg{command} // 'snmpwalk';
  my $mibs = $arg{mibs} // undef;
  my $oid  = $arg{oid} // '';
  my $vlan = $arg{vlan} // '';

  # get configuration
  my $snmp = $self->_get_snmp_config($host);
  die "No valid SNMP configuration for host $host" if !$snmp;

  # abort on misconfiguration
  die "No SNMP executable specified for host $host"
    if !$snmp->{$cmd}{exec};
  die "No SNMP option string specified for host $host"
    if !$snmp->{$cmd}{options};

  # get community string for v2 requests
  my $cmty = $cfg->{community} // '';

  if(
    $cfg->{host}
    && $cfg->{host}{$host}
    && $cfg->{host}{$host}{community}
  ) {
    $cmty = $cfg->{host}{$host}{community};
  }

  # process mib lists
  if($mibs && !ref($mibs)) { $mibs = [ $mibs ]; }
  my $miblist = join(':', @$mibs);

  # perform placeholder replacement
  my $options = $snmp->{$cmd}{options};
  $options =~ s/%c/$cmty/g;
  $options =~ s/%h/$host/g;
  $options =~ s/%r/$oid/g;
  $options =~ s/%m/$miblist/g;
  $options =~ s/%x/\@$vlan/g;

  # finish
  return $snmp->{$cmd}{exec} . ' ' . $options;
}


#=============================================================================
# Return configured SNMP v2 community string for a host.
#=============================================================================

sub snmp_community
{
  my ($self, $host) = @_;
  my $cfg = $self->config;

  return $cfg->{'host'}{$host}{'community'}
    if $host && $cfg->{'host'}{$host}{'community'};

  return $cfg->{'community'};
}


#=============================================================================
# Convert hostname (e.g. 'vdcS02c') to site code (e.g. 'vin')
#=============================================================================

sub site_conv
{
  my ($self, $host) = @_;
  my $cfg = $self->config;

  $host =~ /^(...)/;
  my $hc = lc($1);
  my $site = $cfg->{'siteconv'}{$hc};
  if(!$site) { $site = $hc; }
  return $site;
}


#=============================================================================
# Function to get entity profiles for given entity tree node. The
# configuration lies under the "entity-profiles" key.
#=============================================================================

sub entity_profile
{
  my ($self, %args) = @_;
  my $cfg = $self->config;

  # no entity-profiles configuration exists at all
  return undef if !exists $cfg->{'entity-profiles'};

  # models section
  if($args{model}) {
    if(
      exists $cfg->{'entity-profiles'}{'models'}
      && exists $cfg->{'entity-profiles'}{'models'}{$args{model}}
    ) {
      return $cfg->{'entity-profiles'}{'models'}{$args{model}};
    } else {
      return undef;
    }
  }

  # return the config
  return $cfg->{'entity-profiles'};
}


#=============================================================================
# Convert MIB configuration into SPAM::MIB instances
#=============================================================================

sub _build_mibs
{
  my $self = shift;
  my $cfg = $self->config->{'mibs'};
  my @result;

  foreach my $mib (@$cfg) {
    push(@result, SPAM::MIB->new(
      name => $mib->{'mib'},
      config => $mib
    ));
  }

  return \@result;
}


#=============================================================================
# MIBs iterator, true value from the callback terminates the iteration
#=============================================================================

sub iter_mibs
{
  my ($self, $cb) = @_;
  my @mibs = @{$self->mibs};

  my $is_first_mib = 1;
  foreach my $mib (@mibs) {
    last if $cb->($mib, $is_first_mib);
    $is_first_mib = 0;
  }
}

#=============================================================================
# Find MIBobject with requested 'table' attribute value.
#=============================================================================

sub find_object
{
  my ($self, $snmp_object) = @_;
  my $result;

  $self->iter_mibs(sub {
    my $mib = shift;
    $mib->iter_objects(sub {
      my $object = shift;
      $result = $object if $object->name eq $snmp_object;
      return $result;
    });
    return $result;
  });

  return $result;
}

#=============================================================================

sub _build_knownports
{
  my $self = shift;
  my @knownports;

  if(exists $self->config->{knownports}) {
    @knownports = @{$self->config->{knownports}};
  }

  return \@knownports;
}


#=============================================================================

sub _build_mactableage
{
  my $self = shift;
  my $val = 1209600;

  if(exists $self->config->{mactableage}) {
    $val = $self->config->{mactableage};
  }

  return $val;
}

sub _build_arptableage
{
  my $self = shift;
  my $val = 1209600;

  if(exists $self->config->{arptableage}) {
    $val = $self->config->{arptableage};
  }

  return $val;
}

#=============================================================================

sub _build_vlanservers
{
  my $self = shift;
  my $val;

  if(exists $self->config->{vlanservers}) {
    $val = $self->config->{vlanservers};
  }

  return $val;
}

#=============================================================================

sub snmpget
{
  my $self = shift;
  return $self->config->{snmpget}
}

sub snmpwalk
{
  my $self = shift;
  return $self->config->{snmpwalk}
}

#=============================================================================

1;
