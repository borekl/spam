package SPAM::Role::Switch;

# role for the SPAM::Host base class, this implements switch-specific
# functionality

use Moo::Role;
use experimental 'signatures';

use Carp;
use POSIX qw(strftime);

use SPAM::Model::SwStat;
use SPAM::Model::PortStatus;
use SPAM::Model::Mactable;
use SPAM::Model::Porttable;
use SPAM::SNMP qw(snmp_get_object);

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
sub update_switch_db ($self, %arg)
{
  $self->update_ports;

  # update swstat table
  $self->_m("Updating swstat table (started)");
  $self->swstat->update($self->snmp, $self->port_stats);
  $self->_m("Updating swstat table (finished)");

  # save SNMP data for use by frontend
  $self->save_snmp_data;

  # update mactable
  $self->update_mactable;

  # run autoregistration
  $self->autoregister if $arg{autoreg} && $self->has_role('switch');
}

#------------------------------------------------------------------------------
# update all ports
sub update_ports ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my $update_plan = $self->find_changes;

  $self->_m(
    'Updating status table (i=%d/d=%d/U=%d/u=%d)',
    @{$update_plan->{stats}}{qw(i d U u)}
  );

  $db->txn(sub ($tx) {
    foreach (@{$update_plan->{plan}}) {
      my ($act, $p) = @$_;
      if($act eq 'd') { $self->ports_db->delete_ports($tx, $p); }
      elsif($act eq 'i') { $self->ports_db->insert_ports($tx, $self->snmp, $p); }
      elsif($act eq 'U') { $self->ports_db->update_ports($tx, $self->snmp, $p); }
      elsif($act eq 'u') { $self->ports_db->touch_ports($tx, $p); }
      else { croak 'Invalid action in update plan'; }
    }
  });

  $self->_m('Updating status table (finished)');
}

#------------------------------------------------------------------------------
# Update mactable in the backend database according to the new data from SNMP
sub update_mactable ($self)
{
  my $count = 0;

  # do nothing when MAC table is not loaded
  unless($self->snmp->ifindex_to_dot1d) {
    $self->_m('Updating mactable (skipped, no ifindex to dot1d)');
    return undef;
  }

  # get database handle
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;

  # it is possible that for some reason the same mac will appear twice in the
  # SNMP data; we keep track of MACs we have already seen so that later we do
  # not try to INSERT same record twice (which would cause the transaction to
  # fail)
  my %mac_current;

  # ensure database connection
  die 'Cannot connect to database (spam)' unless ref $db;

  # start transaction
  $self->_m("Updating mactable (started)");
  $db->txn(sub ($tx) {
    $self->mactable_db->reset_active_mac($tx);
    $self->snmp->iterate_macs(sub (%arg) {
      $self->mactable_db->insert_or_update($tx, %arg);
      $count++;
    });
  });

  # finish
  $self->_m('Updating mactable (finished, updated %d macs)', $count);
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
      && !$self->snmp->cdp_port($if)
    ) {
      $stat{p_illact}++;
    }
    #--- used ports
    # ports that were used within period defined by "inactivethreshold2"
    # configuration parameter
    if($knownports && $self->ports_db->get_port($portname, 'age')) {
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
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my $count = 0;

  $self->_m('Running auto-registration (started)');

  # get site-code from hostname
  my $site = SPAM::Config->instance->site_from_hostname($self->name);

  # wrap the update in transaction
  $db->txn(sub ($tx) {

    # new, hopefully correct code that compares current patching indicated in
    # porttable.cp with data obtained via SNMP and parsed out of ifAlias
    foreach my $portname ($self->snmp->ports) {
      my $descr = $self->snmp->iftable($portname, 'ifAlias');
      my $cp_descr;
      if($descr && $descr =~ /^.*?;(.+?);.*?;.*?;.*?;.*$/) {
        $cp_descr = $1;
        next if $cp_descr eq 'x';
        next if $cp_descr =~ /^(eth\d|fa\d|gi\d|te\d)/i;
        $cp_descr = substr($cp_descr, 0, 10);
        if(!$self->port_to_cp->exists($portname)) {
          $self->port_to_cp->insert($tx,
            host => $self->name,
            port => $portname,
            cp => $cp_descr,
            site => $site
          );
          $count++;
        }
      }
    }

  });

  $self->_m('Registered %d ports', $count);
  $self->_m('Running auto-registration (finished)');
}

#------------------------------------------------------------------------------
# delete all record associated with this host
sub drop ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my @tables = (qw(status swstat mactable modwire));

  $db->txn(sub ($tx) {
    foreach my $table (@tables) {
      $tx->query(
        "DELETE FROM $table WHERE host = ?", $self->name
      );
    }
  });
}

#------------------------------------------------------------------------------
# poll host for SNMP data
sub poll_switch ($self, %args)
{
  # load configure MIBs; the first MIB is special and must contain reading
  # sysObjectID, sysLocation and sysUpTime; if these cannot be loaded; the
  # whole function fails.
  SPAM::Config->instance->iter_mibs(sub ($mib, $is_first_mib=undef) {
    my @mib_list = ( $mib->name );
    my @vlans = ( undef );

    # iterate over individual objects in a MIB
    $mib->iter_objects(sub ($obj) {

      # match platform string if defined
      if(!$is_first_mib) {
        my $include_re = $obj->include;
        my $exclude_re = $obj->exclude;
        return undef if $include_re && $self->snmp->platform !~ /$include_re/;
        return undef if $exclude_re && $self->snmp->platform =~ /$exclude_re/;
      }

      # include additional MIBs; this implements the 'addmib' object key; we use
      # this to load product MIBs that translate sysObjectID into nice textual
      # platform identifiers; note that the retrieved values will be stored
      # under the first MIB name in the array @$mib
      push(@mib_list, $obj->addmib->@*);

      # 'arptable' is only relevant for reading arptables from _routers_; here
      # we just skip it
      return undef if $obj->has_flag('arptable');

      # 'vlans' flag; this causes to VLAN number to be added to the community
      # string (as community@vlan) and the tree retrieval is iterated over all
      # known VLANs; this means that vtpVlanName must be already retrieved; this
      # is required for reading MAC addresses from switch via BRIDGE-MIB
      if($obj->has_flag('vlans')) {
        @vlans = $self->snmp->active_vlans->@*;
        if(!@vlans) { @vlans = ( undef ); }
      }

      # 'vlan1' flag; this is similar to 'vlans', but it only iterates over
      # value of 1; these two are mutually exclusive
      @vlans = ( 1 ) if $obj->has_flag('vlan1');

      # 'mactable' MIBs should only be read when --mactable switch is active
      if($obj->has_flag('mactable')) {
        if(!$args{mactable}) {
          $self->_m(
            'Skipping %s::%s, mactable loading not active',
            $mib->name, $obj->name
          );
          return undef;
        }
      }

      # iterate over vlans
      for my $vlan (@vlans) {

        # retrieve the SNMP object
        my $r = snmp_get_object(
          'snmpwalk', $self->_name_resolved, $vlan, \@mib_list,
          $obj->name,
          $obj->columns,
          sub {
            my ($var, $cnt) = @_;
            return if !$var;
            my $msg = sprintf("Loading %s::%s", $mib->name, $var);
            if($vlan) { $msg .= " $vlan"; }
            if($cnt) { $msg .= " ($cnt)"; }
            $self->_m($msg);
          }
        );

        # handle error
        if(!ref $r) {
          if($vlan) {
            $self->_m('Processing %s/%d (failed, %s)', $mib->name, $vlan, $r);
          } else {
            $self->_m('Processing %s (failed, %s)', $mib->name, $r);
          }
        }

        # process result
        else {
          $self->add_snmp_object($mib, $vlan, $obj, $r);
        }
      }

      # false to continue iterating
      return undef;
    });

  #--- first MIB entry is special as it gives us information about the host

    if($is_first_mib) {

      # --hostinfo command-line option in effect
      if($args{hostinfo}) {
        $self->_m('Platform: %s', $self->snmp->platform // '?');
        $self->_m(
          'Booted on: %s', strftime('%Y-%m-%d', localtime($self->snmp->boottime))
        ) if $self->snmp->boottime;
        $self->_m('Location: %s', $self->snmp->location // '?');
        return 1;
      }

      # if platform information is unavailable it means the SNMP communications
      # with the device has failed and we should abort
      die "Failed to get platform information\n" unless $self->snmp->platform;

      # display message about platform and boottime
      $self->_m(
        'System info: platform=%s boottime=%s',
        $self->snmp->platform,
        strftime('%Y-%m-%d',localtime($self->snmp->boottime))
      );
    }

    # false to continue iterating
    return undef;
  });

  return undef if $args{hostinfo};

  # make sure ifTable and ifXTable exist
  die 'ifTable/ifXTable do not exist' unless $self->snmp->has_iftable;
}

1;
