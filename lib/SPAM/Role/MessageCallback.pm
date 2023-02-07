package SPAM::Role::MessageCallback;

use Moo::Role;

# message display callback, default is an empty sub doing nothing
has mesg => (
  is => 'ro',
  isa => sub { ref $_[0] },
  default => sub { sub {} }
);

1;
