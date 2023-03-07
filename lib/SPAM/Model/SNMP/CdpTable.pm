package SPAM::Model::SNMP::CdpTable;

# interface to CISCO-CDP-MIB

use Moo::Role;
use experimental 'signatures';
use Carp;

requires '_d';

#-------------------------------------------------------------------------------
# return cdpCacheTable entry if it exists, otherwise undef
sub cdp_port ($self, $if)
{
  if(
    exists $self->snmp->{'CISCO-CDP-MIB'}
    && exists $self->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
    && exists $self->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if}
  ) {
    return $self->snmp->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if};
  } else {
    return undef;
  }
}

1;
