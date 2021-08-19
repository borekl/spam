package SPAM::Model::SNMP::CafSessionTable;

# interface with CISCO-AUTH-FRAMEWORK-MIB cafSessionTable

use Moo::Role;
use experimental 'signatures';
use Carp;

requires qw(_d port_to_ifindex);

has auth_vlans => ( is => 'lazy' );

sub _build_auth_vlans ($self)
{
  my %vlans;
  my $s = $self->_d;

  # dynamic vlan configured by user authentication
  if(
    exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}
    && exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionTable'}
  ) {
    my $cafSessionTable = $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionTable'};
    for my $if (keys %$cafSessionTable) {
      for my $sid (keys %{$cafSessionTable->{$if}}) {
        if(exists $cafSessionTable->{$if}{$sid}{'cafSessionAuthVlan'}) {
          my $v = $cafSessionTable->{$if}{$sid}{'cafSessionAuthVlan'}{'value'};
          $vlans{$v} = undef if $v > 0 && $v < 1000;
        }
      }
    }
  }

  # sort and finish
  return [ sort { $a <=> $b } keys %vlans ];
}

# return true if MAC bypass is active on the port; this is just a simplistic
# copy of the code that used to reside in PortFlags
sub has_mac_bypass ($self, $p)
{
  my $s = $self->_d;
  my $if = $self->port_to_ifindex->{$p};

  return undef unless defined $if;

  if(
    exists $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}
  ) {
    my $s = $s->{'CISCO-AUTH-FRAMEWORK-MIB'}{'cafSessionMethodsInfoTable'}{$if};
    for my $sessid (keys %$s) {
      if(
        exists $s->{$sessid}{'macAuthBypass'}
        && exists $s->{$sessid}{'macAuthBypass'}{'cafSessionMethodState'}
        && exists $s->{$sessid}{'macAuthBypass'}{'cafSessionMethodState'}{'enum'}
        && $s->{$sessid}{'macAuthBypass'}{'cafSessionMethodState'}{'enum'} eq 'authcSuccess'
      ) {
        return 1;
      }
    }
  }

  return undef;
}

1;
