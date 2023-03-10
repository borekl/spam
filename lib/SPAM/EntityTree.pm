package SPAM::EntityTree;

# encapsulate handling ENTITY-MIB entPhysicalTable trees

use warnings;
use integer;
use strict;
use v5.16;

use Moo;
use Carp;
use Scalar::Util qw(blessed reftype);
use Data::Dumper;

use SPAM::Config;

# tree root
has root => (
  is => 'rw',
  isa => sub {
    croak 'Not a SPAM::Entity instance'
    unless ref $_[0] && $_[0]->isa('SPAM::Entity');
  },
);

# hash that indexes nodes in the tree by their associated ifIndex; note, that
# only port entries have associated ifIndex
has node_by_ifIndex => (
  is => 'ro',
  default => sub { {} },
);

#------------------------------------------------------------------------------
# Constructor code, builds the tree from supplied array of individual entries.
# The individual must be SPAM::Entity instances.
sub BUILD
{
  my ($self, $arg) = @_;

  # check that we got the required argument
  croak 'SPAM::EntityTree requires "entities" argument'
  if !exists $arg->{'entities'};

  croak 'SPAM::EntityTree "entities" argument must be an arrayref'
  if !ref $arg->{'entities'} || !reftype $arg->{'entities'} eq 'ARRAY';

  my $entities = $arg->{'entities'};
  foreach my $e (@$entities) {
    croak '"entities" item is not a SPAM::Entity instance'
    if !blessed $e || !$e->isa('SPAM::Entity');
  }

  # find root element
  my (@root) = grep { !$_->entPhysicalContainedIn } @$entities;

  if(!@root) {
    croak 'Entity table has no root';
  } elsif(@root > 1) {

    # some devices' entPhysicalTable doesn't comprise one single-rooted tree,
    # but instead have some entries that are not part of the tree; in that case
    # the above method doesn't find the actual entity tree root and further
    # processing is required
    my (@stack) = grep { $_->entPhysicalClass eq 'stack' } @root;
    my (@chassis) = grep { $_->entPhysicalClass eq 'chassis' } @root;
    if(@stack) {
      $self->root($stack[0]);
    } elsif(@chassis == 1) {
      $self->root($chassis[0]);
    } else {
      croak 'Entity table has multiple roots';
    }

  } else {
    $self->root($root[0]);
  }

  # recursively build the tree from the array of elements
  my $build = sub {
    my $tree = shift;
    my $entPhysicalIndex = $tree->entPhysicalIndex;

    # find entities that are contained within current subtree
    my (@contained) = grep {
      defined $_->entPhysicalContainedIn
      && $_->entPhysicalContainedIn == $entPhysicalIndex
    } @$entities;

    # terminate this branch if no descendants exist
    return if !@contained;

    # add entry into ifIndex-to-node hash (if ifIndex is defined), add all
    # contained entries into current node and branch into every entry
    foreach my $c (@contained) {
      $self->node_by_ifIndex()->{$c->ifIndex} = $c if $c->ifIndex;
      $tree->add_child($c);
      __SUB__->($c);
    }

    # finish
    return $tree;
  };

  $build->($self->root);
}

#------------------------------------------------------------------------------
# Tree traversal utility function. The arguments in the form of hash are
# 'callback', 'depth' and 'start'. The latter two are optional. The callback
# argument can also be supplied outside of the argument has, in that case it
# must be the first argument.
#
# The callback gets two arguments:  SNMP::Entity instance ref and tree level
# (root being level 0, root children level 1 etc.).
sub traverse
{
  my ($self, @arg) = @_;

  # process arguments
  my $cb = shift @arg if @arg % 2;
  my %arg = @arg;

  my $depth = $arg{'depth'} // undef;
  my $start = $arg{'start'} // $self->root;
  $cb = $arg{'callback'} if exists $arg{'callback'};

  return if !$cb;

  # perform the traversal
  sub {
    my ($node, $level) = @_;
    $cb->($node, $level);
    foreach my $c (
      sort {
        $a->entPhysicalIndex <=> $b->entPhysicalIndex
      } @{$node->children}
    ) {
      __SUB__->($c, $level + 1) if !defined $depth || $level < $depth;
    }
  }->($start, 0);
}


#------------------------------------------------------------------------------
# Function to compile flat list of SPAM::Entity refs based on callback result
# and additional query parameters. Arguments are given as a hash. Callback
# argument can also be given as the first argument, or omitted completely. All
# arguments that are not callback are passed verbatim to the traverse()
# function.
sub query
{
  my ($self, @args) = @_;
  my @result;

  # process arguments
  my $cb = shift @args if @args % 2;
  my %args = @args;
  if(exists $args{'callback'}) {
    $cb = $args{'callback'} ;
  }
  delete $args{'callback'} if $cb && exists $args{'callback'};

  # perform the query
  $self->traverse(sub {
    my $entry = shift;
    push(@result, $entry) if !$cb || $cb->($entry);
  }, %args);

  return @result;
}


#------------------------------------------------------------------------------
# Return a list of chassis entities. We are assuming that chassis is either the
# root entity or one level below (in case of stacks).
sub chassis
{
  my ($self) = @_;

  return $self->query(sub {
    $_[0]->entPhysicalClass eq 'chassis'
  }, depth => 1);
}


#------------------------------------------------------------------------------
# return a list of power supplies' entities
sub power_supplies
{
  my ($self) = @_;

  return $self->query(sub {
    $_[0]->entPhysicalClass eq 'powerSupply'
  });
}


#------------------------------------------------------------------------------
# Return a list of linecards' entities.
sub linecards
{
  my ($self) = @_;
  my @linecards;

  # find out if "modules_by_name" discovery option is defined for this model of
  # a switch; if that is the case, the $re variable will hold the discovery
  # regular expression

  my ($chassis) = $self->chassis;
  my $chassis_model = $chassis->entPhysicalModelName;
  my $cfg = SPAM::Config->instance->entity_profile(model => $chassis_model);
  my $re;

  $re = $cfg->{'modules_by_name'} if $cfg && exists $cfg->{'modules_by_name'};

  if($re) {
    @linecards = $self->query(sub {
      $_[0]->entPhysicalName =~ /$re/;
    });
  } else {
    @linecards = $self->query(sub {
      $_[0]->entPhysicalClass eq 'module'
      && $_[0]->parent
      && $_[0]->parent->entPhysicalClass eq 'container'
      && $_[0]->parent->parent
      && $_[0]->parent->parent->entPhysicalClass eq 'chassis'
    });
  }

  return @linecards;
}


#------------------------------------------------------------------------------
# Return a list of power supplies' entities.
sub fans
{
  my ($self) = @_;

  return $self->query(sub {
    $_[0]->entPhysicalClass eq 'fan'
  });
}


#------------------------------------------------------------------------------
# Return a list of ports, optionally starting at a node. The port list can
# optionally be filtered with 'entity-profiles.models.MODEL.port_filter'
# configuration option. Example of usage:
#
#  "N3K-C3548P-10GX": {
#    "port_filter": {
#      "filter_by": "entPhysicalName",
#      "regex": "^Linecard-\\d Port-(?<portno>\\d+)$",
#      "range": [ 1, 48 ],
#    }
#  }
sub ports
{
  my ($self, $start) = @_;
  my $filter;
  my @ports;

  # default starting node is the root
  $start = $self unless $start;

  # port filtering
  my ($chassis) = $start->ancestors_by_class('chassis');
  my $swmodel = $chassis->entPhysicalModelName if $chassis;
  my $cfg = SPAM::Config->instance->entity_profile(model => $swmodel);

  if($cfg && exists $cfg->{'port_filter'}) {
    $filter = $cfg->{'port_filter'};
    if(
      !exists $filter->{'filter_by'}
      || !exists $filter->{'regex'}
      || !exists $filter->{'range'}
    ) {
      croak 'port_filter option requires "filter_by", "regex" and "range"';
    }
  }

  # get unfiltered port list
  @ports = $self->query(start => $start, callback => sub {
    $_[0]->entPhysicalClass eq 'port'
  });

  # perform filtering
  if($filter) {
    my $field = $filter->{'filter_by'};
    my $re = $filter->{'regex'};
    my @range = @{$filter->{'range'}};

    @ports = grep {
      $_->$field =~ /$re/
      && $+{portno} >= $range[0]
      && $+{portno} <= $range[1]
    } @ports;
  }

  # finish

  return @ports;
}


#------------------------------------------------------------------------------
# Legacy function that returns the 'hwinfo' structure: a flat arrayref of
# hashes, each of which correspond to one of following entities: chassis, fan,
# power supply or linecard. Eventually we want to move to use the entity tree
# directly. This method entails multiple tree traversal and is quite
# inefficient.
#
# The 'modwire' argument is a list of hashref loaded from the 'modwire' backend
# table, which gives identification of where given linecard is cabled to (for
# linecards that are permanently wired to patchpanels).
sub hwinfo
{
  my ($self, $modwire) = @_;
  my $cfg = SPAM::Config->instance->entity_profile;
  my $ent_models = $cfg->{'models'} // undef;
  my @result;

  my @chassis = $self->chassis;
  my @ps = $self->power_supplies;
  my @cards = $self->linecards;
  my @fans = $self->fans;

  # get list of chassis entries
  foreach my $chassis (@chassis) {
    push(@result, {
      'm' => $chassis->chassis_no,
      idx => $chassis->entPhysicalIndex,
      partnum => $chassis->entPhysicalModelName,
      sn => $chassis->entPhysicalSerialNum,
      type => 'chassis',
    })
  }

  # get list of power supplies
  foreach my $ps (@ps) {
    push(@result, {
      'm' => $ps->chassis_no,
      idx => $ps->entPhysicalIndex,
      partnum => $ps->entPhysicalModelName,
      sn => $ps->entPhysicalSerialNum,
      type => 'ps',
    })
  }

  # get list of linecards
  my @cards_processed;
  foreach my $card (@cards) {

    # linecard number derivation is problematic; entPhysicalParentRelPos
    # of the direct container entity works on most hardware, but on Cat9410R
    # the supervisor it is in slot 5, but the respective container is shown as
    # being number 11; special casing required

    my ($chassis) = $card->ancestors_by_class('chassis');
    croak "No chassis found for entity " . $card->entPhysicalIndex
    if !$chassis;

    my $linecard_no = $card->linecard_no;

    # linecard number mapping; this uses configuration entry:
    # entity-profiles.models.MODEL.slot_map = HASH
    #
    # For example, following config maps slot 11 to slot 5 for C9410R:
    #
    # "entity-profiles": {
    #   "models": { "C9410R": { "slot_map": { "11": 5 } } }
    # }
    if(
      $ent_models
      && $chassis->entPhysicalModelName
      && $ent_models->{$chassis->entPhysicalModelName}
      && $ent_models->{$chassis->entPhysicalModelName}{'slot_map'}
    ) {
      my $map = $ent_models->{$chassis->entPhysicalModelName}{'slot_map'};
      $linecard_no
      = exists $map->{$linecard_no} ? $map->{$linecard_no} : $linecard_no;
    }

    # find card 'location'
    my $m = $card->chassis_no;
    my ($location_entry, $location);
    if($modwire && @$modwire) {
      ($location_entry) = grep {
        ( $_->{'m'} == $m || ($_->{'m'} == 0 && $m == 1) )
        && $_->{'n'} == $linecard_no
      } @$modwire;
      if($location_entry) {
        $location = $location_entry->{'location'};
      }
    }

    # get list of ports in given module
    my @ports = $self->ports($card);

    push(@cards_processed, {
      'm' => $m,
      'n' => $linecard_no,
      idx => $card->entPhysicalIndex,
      partnum => $card->entPhysicalModelName,
      sn => $card->entPhysicalSerialNum,
      type => 'linecard',
      location => $location,
      ports => [ map { $_->ifIndex } grep { $_->ifIndex } @ports ],
    })
  }

  # sort the linecards by their m/n values (ie. chassis/slot numbers)
  push(@result,
    sort {
      if($a->{'m'} == $b->{'m'}) {
        $a->{'n'} <=> $b->{'n'}
      } else {
        $a->{'m'} <=> $b->{'m'}
      }
    } @cards_processed
  );

  # get list of fans
  foreach my $fan (@fans) {
    # only list fans with model name, some devices list every fan in the system
    # which is not very useful
    next if !$fan->entPhysicalModelName;
    push(@result, {
      'm' => $fan->chassis_no,
      idx => $fan->entPhysicalIndex,
      partnum => $fan->entPhysicalModelName,
      sn => $fan->entPhysicalSerialNum,
      type => 'fan',
    })
  }

  # return the resulting hwinfo array
  return \@result;
}

#------------------------------------------------------------------------------
# Create a debug dump
sub debug_dump
{
  my $self = shift;

  open(my $fh, '>', "debug.entities.$$.log") || die;

  # dump the whole entity tree
  print $fh "entity index         | if     | class        | pos | model        | name\n";
  print $fh "---------------------+--------+--------------+-----+--------------+---------------------------\n";
  $self->traverse(sub {
    my ($node, $level) = @_;
    printf $fh "%-20s | %6s | %-12s | %3d | %12s | %s\n",
      ('  ' x $level) . $node->entPhysicalIndex,
      $node->ifIndex // '',
      $node->entPhysicalClass // '',
      $node->entPhysicalParentRelPos // 0,
      $node->entPhysicalModelName // '',
      $node->entPhysicalName // '';
  });

  # display some derived knowledge
  my @chassis = $self->chassis;
  printf $fh "\n===> CHASSIS (%d found)\n", scalar(@chassis);
  for(my $i = 0; $i < @chassis; $i++) {
    printf $fh "%d. %s\n", $i+1, $chassis[$i]->disp;
  }

  my @ps = $self->power_supplies;
  printf $fh "\n===> POWER SUPPLIES (%d found)\n", scalar(@ps);
  for(my $i = 0; $i < @ps; $i++) {
    printf $fh "%d. chassis=%d %s\n", $i+1,
      $ps[$i]->chassis_no,
      $ps[$i]->disp;
  }

  my @cards = $self->linecards;
  printf $fh "\n===> LINECARDS (%d found)\n", scalar(@cards);
  for(my $i = 0; $i < @cards; $i++) {
    printf $fh "%d. chassis=%d slot=%d %s\n", $i+1,
      $cards[$i]->chassis_no,
      $cards[$i]->linecard_no,
      $cards[$i]->disp;
  }

  my @fans = $self->fans;
  printf $fh "\n===> FANS (%d found)\n", scalar(@fans);
  for(my $i = 0; $i < @fans; $i++) {
    printf $fh "%d. chassis=%d %s\n", $i+1,
      $fans[$i]->chassis_no,
      $fans[$i]->disp;
  }

  my $hwinfo = $self->hwinfo;
  printf $fh "\n===> HWINFO (%d entries)\n", scalar(@$hwinfo) ;
  print $fh Dumper($hwinfo), "\n";

  # finish
  close($fh);
}

1;
