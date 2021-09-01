package SPAM::Model::SNMP;

# code for interfacing with SNMP and interpreting its data; this class needs to
# be instantiated on a per-host basis so that all indices are properly unique

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

with 'SPAM::MessageCallback';

# data retrieved from the host via SNMP; at this moment these are trees
# generated by snmp_get_object() and saved either under {MIB_NAME} or
# under {MIB_NAME}{VLAN_NO} (ie. the same was stored in %swdata). This should
# probably be improved upon later.
has _d => ( is => 'ro', default => sub {{}} );

with 'SPAM::Model::SNMP::IfTable';
with 'SPAM::Model::SNMP::Platform';
with 'SPAM::Model::SNMP::Location';
with 'SPAM::Model::SNMP::EntityTree';
with 'SPAM::Model::SNMP::PortTable';
with 'SPAM::Model::SNMP::Bridge';
with 'SPAM::Model::SNMP::TrunkVlans';
with 'SPAM::Model::SNMP::ActiveVlans';
with 'SPAM::Model::SNMP::PortFlags';
with 'SPAM::Model::SNMP::Boottime';
with 'SPAM::Model::SNMP::VmMembershipTable';
with 'SPAM::Model::SNMP::CafSessionTable';

# return list of MIBs loaded in this instance
sub mibs ($self) { keys %{$self->_d} }

# return list of loaded objects in a MIB
sub objects ($self, $mib) { keys %{$self->_d->{$mib}} }

# return object just by its name, without needing to know MIB name
sub get_object($self, $object_name) {
  foreach my $mib ($self->mibs) {
    foreach my $object ($self->objects($mib)) {
      return $self->_d->{$mib}{$object} if $object_name eq $object;
    }
  }
}

1;
