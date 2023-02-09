package SPAM::Model::Arptable;

# code for interfacing with the 'arptable' database table; note that unlike
# mactable, arptable is not sectioned by source hosts -- it is one undivided
# entity and it needs to be updated as such

use Moo;
use strict;
use warnings;
use experimental 'signatures';
use Carp;

use SPAM::Config;

# arp entries loaded from database
has _arpdb => ( is => 'lazy' );

#-------------------------------------------------------------------------------
sub _build__arpdb ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my %arptable;

  my $r = $db->select('arptable');
  while(my $row = $r->hash) {
    $arptable{$row->{ip}} = $row;
  }

  return \%arptable;
}

#-------------------------------------------------------------------------------
# return single ARP entry
sub get_arp ($self, $ip) { $self->_arpdb->{$ip} // undef }

#-------------------------------------------------------------------------------
# insert or update single ARP entry in backend database depending on the state
# of the instance; Mojo::Pg::Database instance must be explicitly passed in
sub insert_or_update($self, $db, %data)
{
  $db->insert(
    'arptable2',
    {
      source  => $data{source},
      mac     => $data{mac},
      ip      => $data{ip},
      lastchk => \'current_timestamp',
      dnsname => $data{dnsname},
    },
    { on_conflict => [ [ 'source', 'ip' ] => {
      lastchk => \'current_timestamp',
      mac => $data{mac}
    }]}
  );
}

1;
