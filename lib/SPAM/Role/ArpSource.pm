package SPAM::Role::ArpSource;

# code that handles retrieving ARP tables from routers and saving them into
# backend database (through SPAM::Model::Arptable class)

use Moo::Role;
use strict;
use warnings;
use experimental 'signatures';

use Socket;

use SPAM::Config;
use SPAM::SNMP qw(snmp_get_object);
use SPAM::Model::Arptable;

# SNMP entity that is used for ARP table read-out
has _arp_snmp_object => ( is => 'lazy' );

#-------------------------------------------------------------------------------
sub _build__arp_snmp_object
{
  SPAM::Config->instance->find_object(sub ($o) {
    return 1 if $o->has_flag('arptable');
  });
}

#-------------------------------------------------------------------------------
sub poll_arpsource ($self)
{
  my $o = $self->_arp_snmp_object;

  # read ARP table via SNMP
  $self->_m('Loading ARP table started');
  my $r = snmp_get_object(
    'snmpwalk',
    $self->name,
    undef,
    $o->mib_name,
    $o->name,
    $o->columns,
    sub ($v, $c) {
      $self->_m('%s', $v) if $v && !$c;
      $self->_m('%s (%d)', $v, $c) if $v && $c;
    }
  );

  # handle result
  if(ref $r) {
    $self->add_snmp_object($o->mib_name, undef, $o, $r);
    $self->_m('Loading ARP table finished');
  } else {
    $self->_m('Loading ARP table failed (%s)', $o->mib_name, $r);
  }
}

#-------------------------------------------------------------------------------
# iterate ARP table entries previously read by 'poll_arpsource'
sub iter_arptable ($self, $cb)
{
  my $mib = $self->_arp_snmp_object->mib_name;
  my $table = $self->_arp_snmp_object->name;
  my $t = $self->snmp->_d->{$mib}{$table};

  foreach my $if (keys $t->%*) {
    foreach my $ip (keys $t->{$if}->%*) {
      next unless $t->{$if}{$ip}{'ipNetToMediaType'}{'enum'} eq 'dynamic';
      my $mac = $t->{$if}{$ip}{'ipNetToMediaPhysAddress'}{'value'};
      $cb->({
        source => $self->name,
        mac => $mac,
        ip => $ip,
        dnsname => gethostbyaddr(inet_aton($ip), AF_INET) // undef,
      });
    }
  }
}

#-------------------------------------------------------------------------------
sub update_arptable_db ($self)
{
  my $dbx = SPAM::Config->instance->get_dbx_handle('spam');
  my $atdb = SPAM::Model::Arptable->new;

  $dbx->txn(fixup => sub ($dbh) {
    $self->iter_arptable(sub ($data) {
      $atdb->insert_or_update($dbh, %$data);
    });
  });
}

1;
