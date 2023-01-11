package SPAM::Model::Arptable;

# code for interfacing with the 'arptable' database table; note that unlike
# mactable, arptable is not sectioned by source hosts -- it is one undivided
# entity and it needs to be updated as such

#             Table "public.arptable"
#  Column  |           Type           | Modifiers
# ---------+--------------------------+-----------
#  mac     | macaddr                  | not null
#  ip      | inet                     | not null
#  lastchk | timestamp with time zone |
#  dnsname | character varying(64)    |
# Indexes:
#     "arptable_new_pkey" PRIMARY KEY, btree (mac)
#     "arp_ip" btree (ip)

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
  my $dbh = SPAM::Config->instance->get_dbx_handle('spam')->dbh;
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
# insert single ARP entry into backend database
sub insert ($self, $dbh, %data)
{
  return $dbh->do(
    'INSERT INTO arptable (mac,ip,lastchk,dnsname) VALUES ( ?,?,current_timestamp,?',
    undef,
    $data{mac}, $data{ip}, $data{dnsname}
  );
}

#-------------------------------------------------------------------------------
# update single ARP entry in backend database
sub update ($self, $dbh, %data)
{
  return $dbh->do(
    'UPDATE arptable SET ip = ?, lastchk = current_timestamp, dnsname = ? WHERE mac = ?',
    undef,
    $data{ip}, $data{dnsname}, $data{mac}
  )
}

#-------------------------------------------------------------------------------
# insert or update single ARP entry in backend database depending on the state
# of the instance
sub insert_or_update($self, $dbh, %data)
{
  if($self->get_arp($data{ip})) {
    $self->update($dbh, %data);
  } else {
    $self->insert($dbh, %data);
  }
}

1;
