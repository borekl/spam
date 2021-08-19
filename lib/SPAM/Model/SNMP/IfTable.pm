package SPAM::Model::SNMP::IfTable;

# interface for the ifTable/ifXTable MIB tables

use Moo::Role;
use experimental 'signatures';
use Carp;

requires '_d';

# portname to ifindex hash
has port_to_ifindex => ( is => 'lazy' );

# fields that are in ifXTable, not ifTable
my @ifXTable = qw(ifAlias ifHighSpeed);

#------------------------------------------------------------------------------
# return true if ifTable AND ifXTable exist
sub has_iftable ($self)
{
  if(
    exists $self->_d->{'IF-MIB'} &&
    exists $self->_d->{'IF-MIB'}{'ifTable'} &&
    exists $self->_d->{'IF-MIB'}{'ifXTable'}
  ) {
    return 1;
  } else {
    return undef;
  }
}

#------------------------------------------------------------------------------
# getter for ifTable/ifXTable MIB tables
sub iftable ($self, $p, $f)
{
  my ($v, $factor);
  my $obj = 'ifTable';

  # basic checks for existence
  croak 'ifTable not loaded' unless $self->has_iftable;
  croak "Port '$p' not present in ifTable"
  unless exists $self->port_to_ifindex->{$p};

  # get ifindex
  my $if = $self->port_to_ifindex->{$p};

  # special handling for ifSpeed: if available, ifHighSpeed should be used
  # instead; the returned value always uses ifHighSpeed factor
  if($f eq 'ifSpeed') {
    if(exists $self->_d->{'IF-MIB'}{'ifXTable'}{$if}{'ifHighSpeed'}) {
      $f = 'ifHighSpeed';
    } else {
      $factor = 1_000_000;
    }
  }

  # switch to ifXTable if the field requested belongs to it
  $obj = 'ifXTable' if grep { $_ eq $f } @ifXTable;

  # check for field's existence
  croak "Field '$obj/$f' does not exist"
  unless exists $self->_d->{'IF-MIB'}{$obj}{$if}{$f};

  # return value
  $v = $self->_d->{'IF-MIB'}{$obj}{$if}{$f}{'value'};
  $v /= $factor if defined $factor;
  return $v;
}

#------------------------------------------------------------------------------
# create port-to-ifindex hash from SNMP data
sub _build_port_to_ifindex ($self)
{
  my $s = $self->_d;
  my %by_ifindex;
  my $cnt_prune = 0;

  # feedback message
  $self->mesg->('Pruning non-ethernet interfaces (started)');

  # ifTable needs to be loaded, otherwise fail
  croak q{ifTable not loaded, cannot create 'port_to_ifindex' attribute}
  unless $self->has_iftable;

  # helper for accessing ifIndex
  my $_if = sub { $s->{'IF-MIB'}{'ifTable'}{$_[0]} };
  my $_ifx = sub { $s->{'IF-MIB'}{'ifXTable'}{$_[0]} };

  # iterate over entries in the ifIndex table
  foreach my $if (keys %{$s->{'IF-MIB'}{'ifTable'}}) {
    if(
      $_if->($if)->{'ifType'}{'enum'} ne 'ethernetCsmacd'
      || $_ifx->($if)->{'ifName'}{'value'} =~ /^vl/i
    ) {
      # matching interfaces are deleted, FIXME: this is probably not needed
      delete $s->{'IF-MIB'}{'ifTable'}{$if};
      delete $s->{'IF-MIB'}{'ifXTable'}{$if};
      $cnt_prune++;
    } else {
      $by_ifindex{$if} = $_ifx->($if)->{'ifName'}{'value'};
    }
  }

  $self->mesg->(
    'Pruning non-ethernet interfaces (finished, %d pruned)',
    $cnt_prune
  );

  # turn ifindex->portname into portname->ifindex hash
  return { reverse %by_ifindex };
}

1;
