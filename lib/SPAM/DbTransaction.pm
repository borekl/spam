package SPAM::DbTransaction;

# class to collect data for a database transaction and then send them to it; it
# contains built-in logging of transaction for debugging purposes

use Moo;
use v5.12;
use warnings;
use experimental 'signatures';
use Carp;
use Feature::Compat::Try;

use SPAM::Config;
use SPAM::Misc qw(sql_show_query);

# transaction buffer
has _tx_buffer => (
  is => 'ro',
  default => sub {[]}
);

#-----------------------------------------------------------------------------
# debugging helper
sub _debug ($self, $msg, @vals)
{
  state $fh;

  # not debugging, do nothing
  return unless $ENV{SPAM_DEBUG};

  # open debug log if not already open
  if(!$fh) {
    open($fh, '>>', "debug.transaction.$$.log");
    croak 'Cannot open transaction debug dump' unless $fh;
    print $fh "---> TRANSACTION LOG START\n";
  }

  # close debug log if the message is undefined
  if(!defined $msg) {
    print $fh "---> TRANSACTION LOG END\n";
    close($fh);
    $fh = undef;
    return;
  }

  # otherwise just write out the message
  croak 'Debug filehandle should not be closed, but is' unless $fh;
  printf $fh "$msg\n", @vals;
}

#-----------------------------------------------------------------------------
# add new entry to the transaction buffer
sub add ($self, @e) { push(@{$self->_tx_buffer}, \@e) }

#-----------------------------------------------------------------------------
# returns number of entries in the buffer
sub count($self) { scalar @{$self->_tx_buffer} }

#-----------------------------------------------------------------------------
# commit transaction
sub commit ($self)
{
  my $db = SPAM::Config->instance->get_mojopg_handle('spam')->db;
  my $rv;
  my $line = 1;

  # do a debug dump
  if($ENV{SPAM_DEBUG}) {
    my $line = 1;
    foreach my $row (@{$self->_tx_buffer}) {
      $self->_debug('%d. %s', $line++, sql_show_query(@$row));
    }
  }

  # send the transaction off to the database
  try {
    $db->txn(sub ($tx) {
      foreach my $row (@{$self->_tx_buffer}) {
        my $qry = shift @$row;
        my $r = $tx->query(@$row);
        $line++;
      }
    });
  } catch ($err) {
    chomp $err;
    $self->_debug('---> TRANSACTION FAILED (%s)', $rv = $err);
  }

  # finish
  $self->_debug(undef);
  return $rv;
}


1;
