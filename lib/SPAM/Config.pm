#=============================================================================
# Encapsulate loading and managing configuration.
#=============================================================================

package SPAM::Config;

use v5.16;
use warnings;
use integer;
use strict;

use Moo;
with 'MooX::Singleton';
use experimental 'signatures', 'postderef';

use Carp;
use Perl6::Form;
use Scalar::Util qw(reftype);
use JSON::MaybeXS;
use Path::Tiny qw(path);
use Mojo::Pg;
use SPAM::Config::MIB;
use SPAM::Config::Keys;

# configuration file
has config_file => (
  is => 'ro',
  default => 'spam.cfg.json',
);

# configuration directory, this is automatically filled in from 'config_file'
has _config_dir => (
  is => 'ro',
  lazy => 1,
  default => sub ($s) { path($s->config_file)->absolute->parent },
);

# parsed configuration
has config => ( is => 'lazy', predicate => 1 );

# keys, instance of SPAM::Config::Keys that stores various security-critical
# tokens such as passwords, secrets, community strings etc
has keys => (
  is => 'ro',
  lazy => 1,
  default => sub ($s) { SPAM::Config::Keys->new(keys_dir => $s->_config_dir) },
  predicate => 1
);

# database connection handles
# this is used to store Mojo::Pg instances, one for each database binding; this
# should only be accessed through get_mojopg_handle method
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

# list of MIBs (SPAM::Config::MIB instances)
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

#-----------------------------------------------------------------------------
# Load and parse configuration
sub _build_config
{
  my ($self) = @_;

  # load and parse the config file
  my $file = $self->config_file();
  croak "Configuration file '$file' cannot be found or read" unless -e $file;
  my $cfg = JSON->new->relaxed(1)->decode(path($file)->slurp());

  # perform placeholder replacement
  _recurse->($cfg, sub ($s) {
    return $self->keys->fill($s);
  });

  #finish
  return $cfg;
}

#-----------------------------------------------------------------------------
# Get Mojo::Pg instance for given database binding
sub get_mojopg_handle ($self, $dbid)
{
  # sanity checks
  croak qq{Database configuration section missing}
  unless exists $self->config()->{'dbconn'};
  my $cfg = $self->config()->{'dbconn'};

  croak qq{Invalid argument in SPAM::Config::get_mojopg_handle()} unless $dbid;
  croak qq{Undefined database connection id "$dbid"} unless exists $cfg->{$dbid};
  $cfg = $cfg->{$dbid};

  # if already connected, just return the handle
  if(exists $self->dbconn->{$dbid}) {
    return $self->dbconn->{$dbid};
  }

  # otherwise try to connect to the database
  my $pg = Mojo::Pg->new($cfg->{dburl});
  $pg->password($cfg->{dbpass}) if $cfg->{dbpass};
  $pg->options({
    AutoCommit => 1, RaiseError => 1, PrintError => 0,
    pg_enable_utf8 => 1, FetchHashKeyName => 'NAME_lc',
  });
  $pg->database_class($pg->database_class->with_roles('+TxnMethods'));

  # finish
  return $self->dbconn->{$dbid} = $pg;
}

#-----------------------------------------------------------------------------
# load list of hosts (switches) from backend database
sub _build_hosts ($self)
{
  my $db = $self->get_mojopg_handle('ondb')->db;
  die 'Database connection failed (ondb)' unless ref $db;

  my %hosts;
  my $r = $db->select('v_switchlist');
  while (my $row = $r->hash) {
    my $h = $row->{hostname};
    $hosts{$h}{community} = $row->{community};
    $hosts{$h}{ip} = $row->{ip_addr};
  }

  return \%hosts;
}

#-----------------------------------------------------------------------------
# load list of routers from backend database
sub _build_arpservers ($self)
{
  my $db = $self->get_mojopg_handle('ondb')->db;
  die 'Database connection failed (ondb)' unless ref $db;

  # the v_arpservers view returns tuples (hostname, community)
  my @arpservers;
  my $r = $db->select('v_arpservers');
  while(my $row = $r->array) {
    my ($s, $cmty) = @$row;
    push(@arpservers, [lc $s, $cmty])
      unless scalar(grep { $_->[0] eq $s } @arpservers);
  }

  return \@arpservers;
}

#-----------------------------------------------------------------------------
# make a list of all hosts (switches and arpservers) with optional filtering
# through a callback; this is a helper method to create worklist for polling
sub worklist ($self, $cb=undef)
{
  my %hosts;

  # create a hash of all hosts, the values are arrayrefs with the same values
  # used in Host::poll to determine roles for each host
  $hosts{$_->[0]} = [ 'arpsource' ] foreach ($self->arpservers->@*);
  foreach my $h (keys $self->hosts->%*) {
    $hosts{$h} = [] unless exists $hosts{$h};
    push($hosts{$h}->@*, 'switch');
  }

  # host filtering through a callback; the return value from the callback
  # replaces the current value; if return value is undefined or it is an empty
  # arrayref, the current entry is completely removed
  if($cb) {
    foreach my $h (keys %hosts) {
      my $rv = $cb->($h, $hosts{$h});
      if(!defined $rv || !@$rv) { delete $hosts{$h} }
      else { $hosts{$h} = $rv; }
    }
  }

  return \%hosts;
}

#-----------------------------------------------------------------------------
# Return SNMP configuration block (refered to as 'profile') based on supplied
# hostname and additional conditions specified in profiles. The profiles are
# tried sequentially and the first matching profile is returned.
sub get_snmp_profile
{
  my ($self, $host) = @_;
  my $cfg = $self->config;

  # no valid snmp section in configuration
  return undef if
    !$cfg->{snmp}          # snmp section does not exist at all
    || !ref $cfg->{snmp}   # snmp section is scalar
    || !$cfg->{snmp}->@*;   # snmp section is empty

  # iterate over the snmp config entries
  foreach my $entry ($cfg->{snmp}->@*) {

    # 'excludehost', list of hosts that are specifically excluded
    next if
      exists $entry->{excludehost}
      && ref $entry->{excludehost}
      && grep { lc $_ eq lc $host } $entry->{excludehost}->@*;

    # if the entry has no 'hostre' field, it always matches
    return $entry if !$entry->{hostre};

    foreach my $re ($entry->{hostre}->@*) {
      return $entry if $host =~ /$re/i;
    }
  }

  # no matching section was found
  die "Failed to find matching SNMP configuration for $host";
}

#-----------------------------------------------------------------------------
# Return snmp command and option strings for given (host, mib, oid, vlan)
# Following arguments are accepted: host, command, mibs, oids,
# context(optional)
sub get_snmp_command
{
  my ($self, %arg) = @_;
  my $cfg = $self->config;

  my $host = $arg{host} // '';
  my $cmd  = $arg{command} // 'snmpwalk';
  my $mibs = $arg{mibs} // undef;
  my $oid  = $arg{oid} // '';
  my $ctx  = $arg{context} // '';

  # get configuration
  my $snmp = $self->get_snmp_profile($host);
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

  # context prefix; Cisco uses prefixes their context to access different VLANs
  # in BRIDGE-MIB with 'vlan-' (ie. 'vlan-1' for VLAN 1), but only in SNMPv3;
  # this is defined with context.prefix configuration key in snmp profile
  $ctx = $snmp->{context}{prefix} . $ctx
  if $ctx ne '' && exists $snmp->{context} && exists $snmp->{context}{prefix};

  # perform placeholder replacement
  my $options = $snmp->{$cmd}{options};
  $options =~ s/%c/$cmty/g;
  $options =~ s/%h/$host/g;
  $options =~ s/%r/$oid/g;
  $options =~ s/%m/$miblist/g;
  $options =~ s/%x/$ctx/g;
  $options =~ s/%X/\@$ctx/g if $ctx;
  $options =~ s/%X//g unless $ctx;

  # finish
  return
    wantarray
    ? (($snmp->{$cmd}{exec} . ' ' . $options), $snmp->{profile})
    : ($snmp->{$cmd}{exec} . ' ' . $options)
}

#-----------------------------------------------------------------------------
# Return configured SNMP v2 community string for a host.
sub snmp_community
{
  my ($self, $host) = @_;
  my $cfg = $self->config;

  return $cfg->{'host'}{$host}{'community'}
    if $host && $cfg->{'host'}{$host}{'community'};

  return $cfg->{'community'};
}

#-------------------------------------------------------------------------------
# Return site associated with supplied hostname; optionally also return
# "front-end group", a category useful for separating groups of hosts in the web
# application; data for both are defined in configuration (keys "sitecodes" and
# "fegroups")
sub site_from_hostname ($self, $hostname)
{
  my $cfg = $self->config;

  # find site code
  my $sitecode;
  if($cfg->{sitecode} ) {
    foreach my $e ($cfg->{sitecode}->@*) {
      my $match = $e->[0];
      if($hostname =~ /^$match/i) {
        $sitecode = $e->[1];
        last;
      }
    }
  }

  # find front-end group, if none can be found default value of 'oth' is used
  my $fegroup = 'oth';
  if(wantarray && $sitecode && $cfg->{fegroups}) {
    foreach my $e ($cfg->{fegroups}->@*) {
      if($sitecode eq $e->[0]) {
        $fegroup = $e->[1];
        last;
      }
    }
  }

  # raise exception when no mapping was found
  die "No site mapping for host '$hostname'" unless $sitecode;

  # return values
  if(wantarray) {
    return ($sitecode, $fegroup);
  } else {
    return $sitecode;
  }
}


#-----------------------------------------------------------------------------
# Function to get entity profiles for given entity tree node. The
# configuration lies under the "entity-profiles" key.
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

#-----------------------------------------------------------------------------
# Convert MIB configuration into SPAM::Config::MIB instances
sub _build_mibs
{
  my $self = shift;
  my $cfg = $self->config->{'mibs'};
  my @result;

  foreach my $mib (@$cfg) {
    push(@result, SPAM::Config::MIB->new(
      name => $mib->{'mib'},
      config => $mib
    ));
  }

  return \@result;
}

#-----------------------------------------------------------------------------
# MIBs iterator, true value from the callback terminates the iteration
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

#-----------------------------------------------------------------------------
# Find MIBobject with requested 'table' attribute value or by evaluating
# a callback.
sub find_object
{
  my ($self, $cond) = @_;
  my $result;

  $self->iter_mibs(sub {
    my $mib = shift;
    $mib->iter_objects(sub {
      my $object = shift;
      if(ref $cond) {
        $result = $object if $cond->($object);
      } else {
        $result = $object if $object->name eq $cond;
      }
      return $result;
    });
    return $result;
  });

  return $result;
}

#-----------------------------------------------------------------------------
sub _build_knownports
{
  my $self = shift;
  my @knownports;

  if(exists $self->config->{knownports}) {
    @knownports = @{$self->config->{knownports}};
  }

  return \@knownports;
}

#-----------------------------------------------------------------------------
sub _build_mactableage
{
  my $self = shift;
  my $val = 1209600;

  if(exists $self->config->{mactableage}) {
    $val = $self->config->{mactableage};
  }

  return $val;
}

#-----------------------------------------------------------------------------
sub _build_arptableage
{
  my $self = shift;
  my $val = 1209600;

  if(exists $self->config->{arptableage}) {
    $val = $self->config->{arptableage};
  }

  return $val;
}

#-----------------------------------------------------------------------------
sub _build_vlanservers
{
  my $self = shift;
  my $val;

  if(exists $self->config->{vlanservers}) {
    $val = $self->config->{vlanservers};
  }

  return $val;
}

#-----------------------------------------------------------------------------
sub snmpget ($self) { $self->config->{snmpget} }
sub snmpwalk ($self) { $self->config->{snmpwalk} }

#-----------------------------------------------------------------------------
# this function walks the parsed configuration, invokes a callback for every
# value and lets the callback return a new value; if undef is returned, the
# old value is retained
sub _recurse ($h, $cb)
{
  if(reftype $h eq 'ARRAY') {
    foreach my $i (keys @$h) {
      if(ref $h->[$i]) {
        __SUB__->($h->[$i], $cb);
      } else {
        $h->[$i] = $cb->($h->[$i]) // $h->[$i];
      }
    }
  }

  elsif(reftype $h eq 'HASH') {
    foreach my $k (keys %$h) {
      if(ref $h->{$k}) {
        __SUB__->($h->{$k}, $cb);
      } else {
        $h->{$k} = $cb->($h->{$k}) // $h->{$k};
      }
    }
  }
}

#-----------------------------------------------------------------------------
# return filename of a logfile or undef; the argument specifies which logfile
# is requested: currently only 'web' is supported
sub logfile ($self, $which)
{
  my $cfg = $self->config;

  if(
    exists $cfg->{logfile}
    && ref $cfg->{logfile}
    && exists $cfg->{logfile}{$which}
  ) {
    return $cfg->{logfile}{$which};
  } else {
    return undef;
  }
}

#-----------------------------------------------------------------------------
# display list of hosts along with some configuration fields
sub list_hosts ($self)
{
  my @hosts = sort keys $self->hosts->%*;
  my @sites = map { [ $self->site_from_hostname($_) ] } @hosts;
  my @snmp_profiles = map { $self->get_snmp_profile($_)->{profile} } @hosts;
  print form
    'Dumping configured switches:',
    '',
    'hostname          site   grp  SNMP profile',
    '----------------  -----  ---  -----------------',
    '{[[[[[[[[[[[[[[}  {[[[}  {[}  {[[[[[[[[[[[[[[[[}',
    \@hosts,
    [ map { $_->[0] } @sites ],
    [ map { $_->[1] } @sites ],
    \@snmp_profiles,
    '-----------------------------------------------',
    '{>} switches configured', scalar(@hosts), '';
}

#-----------------------------------------------------------------------------
# display list of arp sources along with some configuration fields
sub list_arpservers ($self)
{
  my @hosts = sort map { $_->[0] } $self->arpservers->@*;
  my @snmp_profiles = map { $self->get_snmp_profile($_)->{profile} } @hosts;
  print form
    'Dumping configured ARP servers:',
    '',
    'hostname          SNMP profile',
    '----------------  -----------------',
    '{[[[[[[[[[[[[[[}  {[[[[[[[[[[[[[[[[}',
    \@hosts,
    \@snmp_profiles,
    '-----------------------------------',
    '{} ARP sources configured', scalar(@hosts), '';
}

1;
