package SPAM::Model::SNMPDbTable;

# class for saving SNMP objects into backend database and retrieving them back

use Moo;
use warnings;
use strict;
use experimental 'signatures', 'postderef';

use Carp;
use Feature::Compat::Try;
use SPAM::Config;
use SPAM::DbTransaction;
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

# debugging filehandle
has _debug_fh => ( is => 'rw' );

#-------------------------------------------------------------------------------
# load data from backend database
sub _build__db ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my $ref_time = time;
  my $table = 'snmp_' . lc $self->obj->name;
  my @object_index = $self->obj->index->@*;
  my %data;

  my $r = $db->select($table,
    [
      \'*',
      \"$ref_time - extract(epoch from date_trunc('second', chg_when)) AS chg_age"
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
sub _dbg ($self, $fmt=undef, @args)
{
  my $fh;

  # do nothing if debugging not turned on
  return unless $ENV{SPAM_DEBUG};

  # open debug filehandle
  if(!$self->_debug_fh) {
    open($fh, '>>', "debug.save_snmp_object.$$.log");
    printf $fh "==> START OF DEBUG // sql_save_snmp_object(%s,%s)\n",
      $self->host->name, $self->obj->name;
    $self->_debug_fh($fh);
  } else {
    $fh = $self->_debug_fh;
  }

  # close filehandle on no input
  if(!$fmt) {
    $self->_dbg('END OF DEBUG');
    close($self->_debug_fh);
    $self->_debug_fh(undef);
    return;
  }

  # log debug message
  printf $fh "--> $fmt\n", @args;
}

#-------------------------------------------------------------------------------
# save current SNMP object into database
sub save ($self)
{
  # other variables
  my $host = $self->host;
  my $snmp_object = $self->obj;
  my $cfg = SPAM::Config->instance;
  my $dbh = $cfg->get_dbi_handle('spam');
  my %stats = ( insert => 0, update => 0, delete => 0 );
  my $ref_time = time();   # reference 'now' point of time
  my $tx = SPAM::DbTransaction->new;

  $self->_dbg('REFERENCE TIME: %s', scalar(localtime($ref_time)));

  try {

    # ensure database connection
    die 'Cannot connect to database (spam)' unless ref $dbh;

    # find the MIB object we're saving
    my $obj = $cfg->find_object($snmp_object->name);
    my @object_index = @{$snmp_object->index};
    $self->_dbg('OBJECT INDEX: %s', join(', ', @object_index));

    # find the object in the host instance
    my $object = $host->snmp->get_object($snmp_object->name);
    die "Object $snmp_object does not exist" unless $object;

    # debugging output
    if($self->_db->%*) {
      $self->_dbg('LOADED %d CURRENT ROWS, DUMP FOLLOWS', scalar(keys $self->_db->%*));
      $self->_dbg(Dumper($self->_db));
      $self->_dbg('CURRENT ROWS DUMP END');
    }

    # collect update plan; there are three conceptual steps:
    # 1. entries that do not exist in %old (= loaded from database) will be
    #    inserted as new
    # 2. entries that do exist in %old will be updated in place
    # 3. entries that do exist in %old but not in $object (= retrieved via
    #    SNMP) will be deleted
    $tx->add(
      sprintf(
        'UPDATE snmp_%s SET fresh = false WHERE host = ?',
        $snmp_object->name
      ),
      $host->name
    );

    # iterate over the SNMP-loaded data
    hash_iterator(
      $object,
      scalar(@object_index),
      sub {
        my $leaf = shift;
        my @idx = @_;
        my $val_old = hash_index_access($self->_db, @idx);
        my (@fields, @values, $query, @cond);

        # UPDATE - note, that we are not actually checking, if the data changed;
        # just existence of the same (host, @index) will cause all columns to be
        # overwritten with new values and 'chg_when' field updated
        if($val_old) {
          $stats{'update'}++;
          $tx->add(
            sprintf(
              'UPDATE snmp_%s SET %s WHERE %s',
              $snmp_object->name,
              join(',', (
                'chg_when = current_timestamp',
                'fresh = true',
                map { "$_ = ?" } @{$snmp_object->columns}
              )),
              join(' AND ', map { "$_ = ?" } ('host', @object_index))
            ),
            ( map {
              $leaf->{$_}{'enum'} // $leaf->{$_}{'value'} // undef
            } @{$snmp_object->columns} ),
            $host->name, @idx,
          );

          # set the age of the entry to zero, so it's not selected for deletion
          $val_old->{'chg_age'} = 0;
        }

        # INSERT
        else {
          $stats{'insert'}++;
          $tx->add(
            sprintf(
              'INSERT INTO snmp_%s ( %s ) VALUES ( %s )',
              $snmp_object->name,
              join(',',
                ('host', 'fresh', @object_index, @{$snmp_object->columns})
              ),
              join(',',
                ('?') x (2 + @object_index + @{$snmp_object->columns})
              ),
            ),
            $host->name, 't', @idx,
            map {
              $leaf->{$_}{'enum'} // $leaf->{$_}{'value'} // undef
            } @{$snmp_object->columns}
          );
        }
      }
    );

    # DELETE
    my $dbmaxage = $snmp_object->dbmaxage // undef;
    if(defined $dbmaxage) {
      hash_iterator(
        $self->_db,
        scalar(@object_index),
        sub {
          my $leaf = shift;
          my @idx = splice @_, 0;

          if($leaf->{'chg_age'} > $dbmaxage) {
            $stats{'delete'}++;
            $tx->add(
              sprintf(
                'DELETE FROM snmp_%s WHERE %s',
                $snmp_object->name,
                join(' AND ', map { "$_ = ?" } ('host', @{$snmp_object->index}))
              ),
              $host->name, @idx
            );
          }
        }
      );
    }

    # debug output
    $self->_dbg(
      'UPDATE PLAN INFO (%d rows, %d inserts, %d updates, %d deletes)',
      $tx->count, @stats{'insert','update', 'delete'}
    );

    # perform database transaction
    if($tx->count) {
      my $e = $tx->commit;
      die $e if $e;
    }

  }

  catch ($err) {
    $self->_dbg('EXCEPTION: %s', $err);
    #die $err;
  }

  # finish
  $self->_dbg;
  return \%stats;
}

1;
