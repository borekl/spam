package SPAM::Host;

use Moo;
use strict;
use warnings;
use experimental 'signatures', 'postderef';
use Carp;
use Socket;
use Data::Dumper;

use SPAM::Config;
use SPAM::Model::SNMP;
use SPAM::Model::SNMPDbTable;

with 'SPAM::Role::Switch';
with 'SPAM::Role::ArpSource';
with 'SPAM::Role::MessageCallback';

# hostname
has name => (
  is => 'ro',
  required => 1,
);

# site code, if site cannot be found the host, this will throw exception
has site => (
  is => 'lazy',
  builder => sub ($s) { SPAM::Config->instance->site_from_hostname($s->name) }
);

# this copies the value of the 'name' attribute but with additional check
# whether the name resolves via DNS; if it fails to resolve an exception is
# raised
has _name_resolved => (
  is => 'lazy',
  builder => sub ($self) { $self->name },
  isa => sub ($v) {
    croak qq{DNS resolution failed for '$v'} unless inet_aton($v);
  },
);

# list of roles, currently available roles are 'switch' and 'arpsource'
has roles => (
  is => 'ro',
  default => sub { [] },
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

# SNMP profile, ie. section of the configuration under the 'snmp' key that
# match the supplied condition
has snmp_profile => ( is => 'lazy' );

#------------------------------------------------------------------------------
# return true when this instance has requested role
sub has_role($self, $role) { scalar grep { $_ eq $role } $self->roles->@* }

#------------------------------------------------------------------------------
# add SNMP object
sub add_snmp_object ($self, $mib, $vlan, $object, $data)
{
  # MIB can be specified both by plain name or by SPAM::Config::MIB instance ref
  $mib = $mib->name if ref $mib;

  if($vlan) {
    $self->snmp->_d->{$mib}{$vlan}{$object->name} = $data;
  } else {
    $self->snmp->_d->{$mib}{$object->name} = $data;
  }
}

#------------------------------------------------------------------------------
# A convenience wrapper for the message display callback 'mesg' that adds
# hostname
sub _m ($self, $message, @args)
{
  $self->mesg->('[' . $self->name . '] ' . $message, @args);
}

#------------------------------------------------------------------------------
# host polling dispatch function; the actual executive functions are defined in
# SPAM::Role:: modules
sub poll ($self, %args)
{
  if($self->has_role('switch')) {
    $self->poll_switch(%args);
    # dump swstat and entity table
    if($ENV{'SPAM_DEBUG'}) {
      $self->debug_dump;
      $self->snmp->entity_tree->debug_dump if $self->snmp->entity_tree;
    }
  }
  if($self->has_role('arpsource')) { $self->poll_arpsource(%args) }
}

#------------------------------------------------------------------------------
# update the backend database with the data we retrieved from hosts with the
# 'poll' method
sub update_db ($self, %args)
{
  if($self->has_role('switch')) { $self->update_switch_db(%args) }
  if($self->has_role('arpsource')) { $self->update_arptable_db(%args) }
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
        my $db = SPAM::Model::SNMPDbTable->new(host => $self, obj => $obj);
        my $r = $db->save;
        if(!ref $r) {
          $self->_m('Saving %s (failed)', $obj->name);
        } else {
          $self->_m(
            'Saving %s (finished, i=%d,u=%d,d=%d,t=%d)',
            $obj->name, @{$r}{qw(insert update delete touch)}
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

#------------------------------------------------------------------------------
# return true if the switch seems to have been rebooted since we last checked
# on it; this is slightly imprecise -- the switch returns its uptime as
# timeticks from its boot up and we calculate boot time from local system clock;
# since these two clocks can be misaligned, we're introducing bit of a fudge
# to reduce false alarms
sub is_rebooted ($self)
{
  if($self->snmp->boottime && $self->swstat->boottime) {
    # 30 is fudge factor to account for imprecise clocks
    if(abs($self->snmp->boottime - $self->swstat->boottime) > 30) {
      return 1;
    }
  }
  return 0;
}


#------------------------------------------------------------------------------
# find associated SNMP profile name (from config)
sub _build_snmp_profile ($self)
{
  my $cfg = SPAM::Config->instance;
  my $snmp = $cfg->get_snmp_profile($self->name);
  return $snmp->{profile};
}

1;
