package SPAM::Host;

use Moo;
use strict;
use warnings;

# hostname
has name => (
  is => 'ro',
  required => 1,
  coerce => sub { lc $_[0] },
);

# SNMP sysLocation
has location => ( is => 'rw' );

#==============================================================================

1;
