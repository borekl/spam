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
  my $dbh = SPAM::Config->instance->get_dbi_handle('spam');
  my %arptable;

  my $sth = $dbh->prepare('SELECT * FROM arptable');
  $sth->execute;
  while(my $row = $sth->fetchrow_hashref) {
    $arptable{$row->{ip}} = $row;
  }

  return \%arptable;
}

#-------------------------------------------------------------------------------
# return single ARP entry
sub get_arp ($self, $ip) { $self->_arpdb->{$ip} // undef }

#-------------------------------------------------------------------------------
# insert or update single ARP entry in backend database depending on the state
# of the instance
sub insert_or_update($self, $dbh, %data)
{
  return $dbh->do(
    'INSERT INTO arptable2 (source,mac,ip,lastchk,dnsname) ' .
    'VALUES ( ?,?,?,current_timestamp,? ) ' .
    'ON CONFLICT (source, ip) DO ' .
    'UPDATE SET lastchk = current_timestamp, mac = ?',
    undef,
    $data{source}, $data{mac}, $data{ip}, $data{dnsname}, $data{mac}
  );
}

1;
