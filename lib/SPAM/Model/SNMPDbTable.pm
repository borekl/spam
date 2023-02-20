package SPAM::Model::SNMPDbTable;

# class for saving SNMP objects into backend database and retrieving them back

use Moo;
use warnings;
use strict;
use experimental 'signatures', 'postderef';

use Carp;
use Feature::Compat::Try;
use Data::Dumper;
use SPAM::Config;
use SPAM::Misc qw(hash_create_index hash_iterator hash_index_access);

# SPAM::Host instance, this contains the data retrieved from SNMP
has host => ( is => 'ro', required => 1 );

# SNMP::MIBobject instance, this configures behaviour of this class and is
# derived from the configuration file
has obj => (
  is => 'ro',
  required => 1,
  isa => sub ($s) {
    unless (ref $s && $s->isa('SPAM::MIBobject')) {
      die 'SPAM::MIBobject instance required'
    }
  }
);

# data loaded from backend database
has _db => ( is => 'lazy' );

# debugging moniker for DebugFile role
has _debug_filename => (
  is => 'lazy',
  default => sub ($s) { 'save_snmp_object.' . $s->obj->name },
);
with 'SPAM::Role::DebugFile';

#-------------------------------------------------------------------------------
# load data from backend database
sub _build__db ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my $now = time;
  my $table = 'snmp_' . lc $self->obj->name;
  my @object_index = $self->obj->index->@*;
  my %data;

  my $r = $db->select($table,
    [
      \'*',
      \"$now - extract(epoch from date_trunc('second', chg_when)) AS chg_age"
    ],
    { host => $self->host->name }
  );

  while(my $row = $r->hash) {
    hash_create_index(
      \%data, $row,
      map { $row->{lc($_)} } @object_index
    );
  }

  return \%data;
}

#-------------------------------------------------------------------------------
# internal code to drop old entries, this is configured by 'dbmaxage' key
# in MIB object configuration
sub _delete_old_entries ($self, $tx)
{
  my $count = 0;
  # do nothing if dbmaxage is not defined (which means we just leave old
  # entries in db)
  return 0 unless defined $self->obj->dbmaxage;

  hash_iterator($self->_db, scalar($self->obj->index->@*), sub ($leaf, @path) {

    # do nothing if the entry is not old enough
    return unless $leaf->{chg_age} > $self->obj->dbmaxage;

    # where clause links indices to their values
    my %where_clause = ( host => $self->obj->name );
    for my $i (0 .. $#path) {
      $where_clause{lc $self->obj->index->[$i]} = $path[$i];
    }

    $tx->delete($self->_dbg_db(
      'delete', 'snmp_' . lc $self->obj->name, \%where_clause
    ));
    $count++;
  });

  return $count;
}

#-------------------------------------------------------------------------------
# save current SNMP object into database
sub save ($self)
{
  # other variables
  my $host = $self->host;
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my %stats = ( insert => 0, update => 0, delete => 0 );
  my $now = time;

  $self->_dbg(
    'FUNCTION: sql_save_snmp_object(%s,%s)',
    $self->host->name, $self->obj->name
  );
  $self->_dbg('REFERENCE TIME: %s', scalar(localtime($now)));

  try {

    # ensure database connection
    die 'Cannot connect to database (spam)' unless ref $db;

    # get the MIB object's index
    my @object_index = $self->obj->index->@*;
    $self->_dbg('OBJECT INDEX: %s', join(', ', @object_index));

    # find the object in the host instance
    my $object = $host->snmp->get_object($self->obj->name);
    die sprintf(q{Object '%s' not loaded}, $self->obj->name) unless $object;

    # debugging output
    if($self->_db->%*) {
      $self->_dbg('LOADED %d CURRENT ROWS, DUMP FOLLOWS', scalar(keys $self->_db->%*));
      $self->_dbg(Dumper($self->_db));
      $self->_dbg('CURRENT ROWS DUMP END');
    }

    $db->txn(sub ($tx) {

      # clear the 'fresh' flag on all entries
      my $table = 'snmp_' . lc $self->obj->name;
      $tx->update($self->_dbg_db(
        'update', $table, { fresh => 'f' }, { host => $self->obj->name }
      ));

      # commence iteration
      $host->snmp->iterate_data($self->obj->name, sub ($where, $set, @idx) {
        my $old_value = hash_index_access($self->_db, @idx);

        # update
        if($old_value) {
          $tx->update($self->_dbg_db(
            'update', $table, $set, { host => $self->obj->name, %$where }
          ));
          $stats{'update'}++;
          # set the age of the entry to zero, so it's not selected for deletion
          $old_value->{'chg_age'} = 0;
        }

        # insert
        else {
          $tx->insert($self->_dbg_db(
            'insert', $table, { host => $host->name, %$set, %$where }
          ));
          $stats{'insert'}++;
        }
      });

      # delete, if 'dbmaxage' is defined for a MIB object, deleting of old
      # entries is performed
      $stats{'delete'} += $self->_delete_old_entries($tx);

    }); # transaction ends here

    # debug output
    $self->_dbg(
      'TRANSACTION DONE (%d inserts, %d updates, %d deletes)',
      @stats{'insert','update', 'delete'}
    );

  }

  catch ($err) {
    chomp $err;
    $self->_dbg('EXCEPTION: %s', $err);
    die $err;
  }

  # finish
  $self->_dbg_close;
  return \%stats;
}

1;
