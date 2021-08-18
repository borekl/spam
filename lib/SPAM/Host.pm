package SPAM::Host;

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;
use Socket;
use POSIX qw(strftime);
use Data::Dumper;

use SPAM::Config;
use SPAM::Model::PortStatus;
use SPAM::Model::SNMP;
use SPAM::SNMP qw(snmp_get_object sql_save_snmp_object);

with 'SPAM::MessageCallback';

# hostname
has name => (
  is => 'ro',
  required => 1,
  coerce => sub { lc $_[0] },
  isa => sub ($v) {
    die 'DNS resolution failed' unless inet_aton($v);
  }
);

# ports loaded from backend database
has ports_db => (
  is => 'ro', lazy => 1,
  default => sub ($self) {
    SPAM::Model::PortStatus->new(hostname => $self->name)
  }
);

# data retrieved from the host via SNMP; at this moment these are trees
# generated by snmp_get_object() and saved either under {MIB_NAME} or
# under {MIB_NAME}{VLAN_NO} (ie. the same was stored in %swdata). This should
# probably be improved upon later.
has snmp => (
  is => 'ro',
  default => sub ($self) {
    SPAM::Model::SNMP->new(mesg => sub { $self->_m(@_) } )
  }
);

# roles dependent on 'snmp'
with 'SPAM::Host::Boottime';
with 'SPAM::Host::PortFlags';

# port statistics
has port_stats => ( is => 'ro', default => sub {{
  p_total => 0,
  p_act => 0,
  p_patch => 0,
  p_illact => 0,
  p_inact => 0,
  p_errdis => 0,
  p_used => undef,
}} );

#------------------------------------------------------------------------------
sub iterate_ports_db ($self, $cb)
{
  foreach my $portname ($self->ports_db->list_ports) {
    my $r = $cb->($portname, $self->ports_db->status->{$portname});
    last if $r;
  }
}

#------------------------------------------------------------------------------
sub get_port_db ($self, $key, $col=undef)
{
  if(exists $self->ports_db->{$key}) {
    my $row = $self->ports_db->{$key};
    if(defined $col) {
      return $row->{$col};
    } else {
      return $row;
    }
  } else {
    return undef;
  }
}

#------------------------------------------------------------------------------
# add SNMP object
sub add_snmp_object ($self, $mib, $vlan, $object, $data)
{
  if($vlan) {
    $self->snmp->_d->{$mib->name}{$vlan}{$object->name} = $data;
  } else {
    $self->snmp->_d->{$mib->name}{$object->name} = $data;
  }
}

#------------------------------------------------------------------------------
# find and return reference to a snmp entity; trees with VLANs not supported
sub get_snmp_object ($self, $object_name)
{
  my $mibs = $self->snmp;

  foreach my $mib (keys %$mibs) {
    foreach my $object (keys %{$mibs->{$mib}}) {
      return $mibs->{$mib}{$object} if $object_name eq $object;
    }
  }

  return undef;
}


#------------------------------------------------------------------------------
# give list of ports that we have in database, but can no longer see in SNMP
# data
sub vanished_ports ($self)
{
  my @vanished;
  my @in_db = $self->ports_db->list_ports;

  $self->iterate_ports_db(sub ($pn, $p) {
    push(@vanished, $pn) if (!grep { $_ eq $pn } @in_db)
  });

  return @vanished;
}

#------------------------------------------------------------------------------
# A convenience wrapper for the message display callback 'mesg' that adds
# hostname
sub _m ($self, $message, @args)
{
  $self->mesg->('[' . $self->name . '] ' . $message, @args);
}

#------------------------------------------------------------------------------
# poll host for SNMP data
sub poll ($self, $get_mactable=undef, $hostinfo=undef)
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
        next if $include_re && $self->snmp->platform !~ /$include_re/;
        next if $exclude_re && $self->snmp->platform =~ /$exclude_re/;
      }

      # include additional MIBs; this implements the 'addmib' object key; we use
      # this to load product MIBs that translate sysObjectID into nice textual
      # platform identifiers; note that the retrieved values will be stored
      # under the first MIB name in the array @$mib
      push(@mib_list, @{$obj->addmib});

      # 'arptable' is only relevant for reading arptables from _routers_; here
      # we just skip it
      return undef if $obj->has_flag('arptable');

      # 'vlans' flag; this causes to VLAN number to be added to the community
      # string (as community@vlan) and the tree retrieval is iterated over all
      # known VLANs; this means that vtpVlanName must be already retrieved; this
      # is required for reading MAC addresses from switch via BRIDGE-MIB
      if($obj->has_flag('vlans')) {
        @vlans = @{$self->snmp->active_vlans};
        if(!@vlans) { @vlans = ( undef ); }
      }

      # 'vlan1' flag; this is similar to 'vlans', but it only iterates over
      # value of 1; these two are mutually exclusive
      if($obj->has_flag('vlan1')) {
        @vlans = ( 1 );
      }

      # 'mactable' MIBs should only be read when --mactable switch is active
      if($obj->has_flag('mactable')) {
        if(!$get_mactable) {
          $self->_m(
            'Skipping %s::%s, mactable loading not active',
            $mib->name, $obj->name
          );
          return undef;
        }
      }

      # iterate over vlans
      for my $vlan (@vlans) {
        next if $vlan && $vlan > 999;

        # retrieve the SNMP object
        my $r = snmp_get_object(
          'snmpwalk', $self->name, $vlan, \@mib_list,
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
      if($hostinfo) {
        $self->_m('Platform: %s', $self->snmp->platform // '?');
        $self->_m(
          'Booted on: %s', strftime('%Y-%m-%d', localtime($self->boottime))
        ) if $self->boottime;
        $self->_m('Location: %s', $self->snmp->location // '?');
        return 1;
      }

      # if platform information is unavailable it means the SNMP communications
      # with the device has failed and we should abort
      die "Failed to get platform information\n" unless $self->snmp->platform;

      # display message about platform and boottime
      $self->_m(
        'System info: platform=%s boottime=%s',
        $self->snmp->platform, strftime('%Y-%m-%d', localtime($self->boottime))
      );
    }

    # false to continue iterating
    return undef;
  });

  return undef if $hostinfo;

  # make sure ifTable and ifXTable exist
  die 'ifTable/ifXTable do not exist' unless $self->snmp->has_iftable;

  # dump swstat and entity table
  if($ENV{'SPAM_DEBUG'}) {
    $self->debug_dump;
    $self->snmp->entity_tree->debug_dump if $self->snmp->entity_tree;
  }
}

#------------------------------------------------------------------------------
# This saves all MIB objects marked with 'save' flag to the backend database
# for access from frontend
sub save_snmp_data ($self)
{
  SPAM::Config->instance->iter_mibs(sub ($mib, $is_first_mib=undef) {
    $mib->iter_objects(sub ($obj) {
      if(
        $obj->has_flag('save')
        && exists $self->snmp->_d->{$mib->name}
        && exists $self->snmp->_d->{$mib->name}{$obj->name}
      ) {
        $self->_m('Saving %s (started)', $obj->name);
        my $r = sql_save_snmp_object($self, $obj);
        if(!ref $r) {
          $self->_m('Saving %s (failed)', $obj->name);
        } else {
          $self->_m(
            'Saving %s (finished, i=%d,u=%d,d=%d)',
            $obj->name, @{$r}{qw(insert update delete)}
          );
        }
      }
    });
  });
}

#------------------------------------------------------------------------------
# Create a debug dump of SNMP data
sub debug_dump ($self)
{
  open(my $fh, '>', "debug.host.$$." . $self->name . '.log') || die;
  print $fh Dumper($self->snmp);
  close($fh);
}

#==============================================================================

1;
