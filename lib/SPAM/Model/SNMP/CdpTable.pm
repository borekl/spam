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
  my $s = $self->_d;

  if(
    exists $s->{'CISCO-CDP-MIB'}
    && exists $s->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
    && exists $s->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if}
  ) {
    return $s->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if};
  } else {
    return undef;
  }
}

1;
