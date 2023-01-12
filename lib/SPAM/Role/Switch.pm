package SPAM::Role::Switch;

# role for the SPAM::Host base class, this implements switch-specific
# functionality

use Moo::Role;
use strict;
use warnings;
use experimental 'signatures';

use Carp;

use SPAM::Model::SwStat;
use SPAM::Model::PortStatus;
use SPAM::Model::Mactable;
use SPAM::Model::Porttable;

# switch statistics
has swstat => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    SPAM::Model::SwStat->new(hostname => $self->name)
  }
);

# ports loaded from backend database
has ports_db => (
  is => 'ro', lazy => 1,
  default => sub ($self) {
    SPAM::Model::PortStatus->new(hostname => $self->name)
  }
);

# MAC address in backend database
has mactable_db => (
  is => 'ro', lazy => 1,
  default => sub ($self) {
    SPAM::Model::Mactable->new(hostname => $self->name)
  }
);

# mapping from ports to cp (CO-side outlets)
has port_to_cp => (
  lazy => 1, is => 'ro',
  default => sub ($s) { SPAM::Model::Porttable->new(hostname => $s->name) }
);

# port statistics
has port_stats => ( is => 'lazy' );

#------------------------------------------------------------------------------
# give list of ports that we have in database, but can no longer see in SNMP
# data
sub vanished_ports ($self)
{
  my @vanished;
  my @in_snmp = $self->snmp->ports;

  $self->ports_db->iterate_ports(sub ($pn, $p) {
    push(@vanished, $pn) if (!grep { $_ eq $pn } @in_snmp)
  });

  return @vanished;
}

#------------------------------------------------------------------------------
# return true if port state differs between database and SNMP; this function is
# way more complicated than it would need to be if we only wanted a comparison
# and nothing else -- but we need debugging output, too
sub is_port_changed ($self, $p)
{
  my $result = 0;
  my $d = $self->ports_db;
  my $s = $self->snmp;

  my @data = (
  [ 'ifOperStatus', 'n', $d->oper_status($p), $s->iftable($p, 'ifOperStatus') ],
  [ 'ifAdminStatus', 'n', $d->admin_status($p), $s->iftable($p, 'ifAdminStatus') ],
  [ 'ifInUcastPkts', 'n', $d->packets_in($p), $s->iftable($p, 'ifInUcastPkts') ],
  [ 'ifOutUcastPkts', 'n', $d->packets_out($p), $s->iftable($p, 'ifOutUcastPkts') ],
  [ 'vmVlan', 'n', $d->vlan($p), $s->vm_membership_table($p, 'vmVlan') ],
  [ 'vlanTrunkPortVlansEnabled', 's', $d->vlans($p), $s->trunk_vlans_bitstring($p) ],
  [ 'ifAlias', 's', $d->descr($p), $s->iftable($p, 'ifAlias') ],
  [ 'portDuplex', 'n', $d->duplex($p), $s->porttable($p, 'portDuplex') ],
  [ 'ifSpeed', 'n', $d->speed($p), $s->iftable($p, 'ifSpeed') ],
  [ 'port_flags', 'n', $d->flags($p), scalar($s->get_port_flags($p)) ]
  );

  my $debug;   # debugging info
  my $cmp_acc; # compare accumulator

  # debug header
  $debug = sprintf("---> HOST %s PORT %s\n", $self->name, $p);

  # the ugly code in this loop is there to avoid warnings about uninitialized
  # variables in comparison and in sprintf
  foreach my $d (@data) {
    my $cmp;

    # we need to replace undefined values (which are perfectly possible) with
    # something well-defined so that we avoid warnings; since we can have either
    # numerical or string fields, we need to have two different default values
    # to replace undefs with
    my $default = $d->[1] eq 's' ? 'undef' : 0;

    # replace undefs with previously defined default value
    my ($d1, $d2) = map { $_ // $default } @$d[2..3];

    # perform the comparison
    if($d->[1] eq 's') {
      $cmp = $d1 ne $d2;
    } else {
      $cmp = $d1 != $d2;
    }

    # some additional mangling for debugging output
    ($d1, $d2) = map { $_ // '-' } @$d[2..3];
    ($d1, $d2) = ('-omitted-', '-omitted-')
    if $d->[0] eq 'vlanTrunkPortVlansEnabled';

    # debug output
    $debug .= sprintf(
      "%s: old:%s new:%s -> %s\n", $d->[0], $d1, $d2,
      $cmp ? 'NO MATCH' : 'MATCH'
    );

    # add result of comparison to the accumulator
    $cmp_acc ||= $cmp;
  }

  # finish
  return wantarray ? ($cmp_acc, $debug) : $cmp_acc;
}

#------------------------------------------------------------------------------
# function to generate update plan, this is a list of ports with action that
# needs to be done; the action can be: i) insert new port, d) delete no longer
# detected port, U) fully update port entry, u) update port entry's 'lastchk'
# field
sub find_changes ($self)
{
  my %update_plan = (
    plan => \my @u,
    stats => { i => 0, d => 0, U => 0, u => 0 }
  );

  # delete: ports that are no longer found by SNMP
  push(@u, map { [ 'd', $_ ] } $self->vanished_ports);
  $update_plan{stats}{d} = @u;

  # iterate over ports found via SNMP
  foreach my $p ($self->snmp->ports) {

    # the port is already known, check it for change
    if($self->ports_db->has_port($p)) {
      my $changed = $self->is_port_changed($p);
      my $mode = $changed ? 'U' : 'u';
      push(@u, [ $mode, $p ]);
      $update_plan{stats}{$mode}++;
    }

    # the port is seen for the first time, insert it
    else {
      push(@u, [ 'i', $p ]);
      $update_plan{stats}{i}++;
    }
  }

  # finish
  return \%update_plan;
}

#------------------------------------------------------------------------------
# update all ports
sub update_db ($self)
{
  my $dbx = SPAM::Config->instance->get_dbx_handle('spam');
  my $update_plan = $self->find_changes;

  $self->_m(
    'Updating status table (i=%d/d=%d/U=%d/u=%d)',
    @{$update_plan->{stats}}{qw(i d U u)}
  );

  $dbx->txn(fixup => sub {
    foreach (@{$update_plan->{plan}}) {
      my ($act, $p) = @$_;
      if($act eq 'd') { $self->ports_db->delete_ports($p); }
      elsif($act eq 'i') { $self->ports_db->insert_ports($self->snmp, $p); }
      elsif($act eq 'U') { $self->ports_db->update_ports($self->snmp, $p); }
      elsif($act eq 'u') { $self->ports_db->touch_ports($p); }
      else { croak 'Invalid action in update plan'; }
    }
  });

  $self->_m('Updating status table (finished)');
}

#------------------------------------------------------------------------------
# Update mactable in the backend database according to the new data from SNMP
sub update_mactable ($self)
{
  my $dbx = SPAM::Config->instance->get_dbx_handle('spam');

  # it is possible that for some reason the same mac will appear twice in the
  # SNMP data; we keep track of MACs we have already seen so that later we do
  # not try to INSERT same record twice (which would cause the transaction to
  # fail)
  my %mac_current;

  # ensure database connection
  die 'Cannot connect to database (spam)' unless ref $dbx;

  # start transaction
  $dbx->txn(fixup => sub ($dbh) {
    $self->mactable_db->reset_active_mac($dbh);
    $self->snmp->iterate_macs(sub (%arg) {
      if(
        $self->mactable_db->get_mac($arg{mac})
        || exists $mac_current{$arg{mac}}
      ) {
        $self->mactable_db->update_mac($dbh, %arg);
      } else {
        $self->mactable_db->insert_mac($dbh, %arg);
        $mac_current{$arg{mac}} = 1;
      }
    });
  });

  # finish
  return undef;
}

#------------------------------------------------------------------------------
# Generate switch statistics
sub _build_port_stats ($self)
{
  my %stat = (
    p_total => 0,
    p_act => 0,
    p_patch => 0,
    p_illact => 0,
    p_inact => 0,
    p_errdis => 0,
    p_used => undef,
  );

  # if 'knownports' is active, initialize its respective stat field
  my $knownports = grep {
    $_ eq $self->name
  } @{SPAM::Config->instance->knownports};
  $stat{'p_used'} = 0 if $knownports;

  # do the counts
  my $idx = $self->snmp->port_to_ifindex;
  foreach my $portname (keys %$idx) {
    my $if = $idx->{$portname};
    $stat{p_total}++;
    $stat{p_patch}++ if $self->port_to_cp->exists($portname);
    $stat{p_act}++ if $self->snmp->iftable($portname, 'ifOperStatus') == 1;
    # p_errdis used to count errordisable ports, but required SNMP variable
    # is no longer available
    #--- unregistered ports
    if(
      $knownports
      && $self->snmp->iftable($portname, 'ifOperStatus') == 1
      && !$self->port_to_cp->exists($portname)
      && !(
        exists $self->snmp->{'CISCO-CDP-MIB'}
        && exists $self->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
        && exists $self->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if}
      )
    ) {
      $stat{p_illact}++;
    }
    #--- used ports
    # ports that were used within period defined by "inactivethreshold2"
    # configuration parameter
    if($knownports) {
      if($self->ports_db->get_port($portname, 'age') < 2592000) {
        $stat{p_used}++;
      }
    }
  }

  # finish
  return \%stat;
}

#------------------------------------------------------------------------------
sub autoregister ($self)
{
  my $dbx = SPAM::Config->instance->get_dbx_handle('spam');
  my $count = 0;

  # get site-code from hostname
  my $site = SPAM::Config->instance->site_conv($self->name);

  # wrap the update in transaction
  $dbx->txn(fixup => sub ($dbh) {

    # iterate over all ports; FIXME: this is iterating ports loaded from the
    # database, not ports actually seen on the host -- this needs to be changed
    # to be correct; the workaround for now is to not run --autoreg on every
    # spam run or just hope the races won't occur
    $self->ports_db->iterate_ports(sub ($portname, $port) {
      my $descr = $port->{descr};
      my $cp_descr;
      if($descr && $descr =~ /^.*?;(.+?);.*?;.*?;.*?;.*$/) {
        $cp_descr = $1;
        return undef if $cp_descr eq 'x';
        return undef if $cp_descr =~ /^(fa\d|gi\d|te\d)/i;
        $cp_descr = substr($cp_descr, 0, 10);
        if(!$self->port_to_cp->exists($portname)) {
          $self->port_to_cp->insert($dbh,
            host => $self->name,
            port => $portname,
            cp => $cp_descr,
            site => $site
          );
          $count++;
        }
      }
      # continue iterating
      return undef;
    });
  });

  $self->_m('Registered %d ports', $count);
}

#------------------------------------------------------------------------------
# delete all record associated with this host
sub drop ($self)
{
  my $dbx = SPAM::Config->instance->get_dbx_handle('spam');
  my @tables = (qw(status hwinfo swstat badports mactable modwire));

  $dbx->txn(fixup => sub ($dbh) {
    foreach my $table (@tables) {
      $dbh->do("DELETE FROM $table WHERE host = ?", undef, $self->name);
    }
  });
}

1;
