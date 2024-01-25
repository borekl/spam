package Mojo::Pg::Database::Role::TxnMethod;

use Role::Tiny;

our $VERSION = '0.01';
use strict;
use warnings;

sub txn {
  my ($self, $code) = @_;
  my $tx = $self->begin;
  my ($ret, @ret);
  if (!defined wantarray) {
    $code->($self);
  } elsif (wantarray) {
    @ret = $code->($self);
  } else {
    $ret = $code->($self);
  }
  $tx->commit;
  return unless defined wantarray;
  return @ret if wantarray;
  return $ret;
}

1;

__END__

=pod

=head1 NAME

Mojo::Pg::Database::Role::TxnMethod

=head1 SYNOPSIS

    # add role after creating the Mojo::Pg instance
    $pg->database_class(
      $pg->database_class->with_roles('+TxnMethod')
    );

    # wrap transaction code with txn method
    my $db = $pg->db;
    my $rv = $db->txn(sub ($db) {
      # transaction code goes here
    });

=head1 DESCRIPTION

Simple role to add a 'txn' method to Mojo::Pg::Database. This method takes
a single coderef that wraps around the transaction code. If an exception
is raised in this code, the transaction is automatically rolled back, otherwise
it is commited.

=head1 METHODS

=head2 C<txn>

Takes a single coderef as an argument. The method invokes 'begin' method on
a Mojo::Pg::Database instance, then executes the coderef and calls 'commit'
after it finishes. If the coderef raises exception, the transaction is
automatically aborted. Return value is that of the coderef.

=head1 AUTHORS

Matt S. Trout (mst) <mst@shadowcat.co.uk>
Borek Lupomesky <borek@lupomesky.cz>

=cut
