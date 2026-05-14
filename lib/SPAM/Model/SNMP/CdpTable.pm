package SPAM::Model::SNMP::CdpTable;

# interface to CISCO-CDP-MIB

use Moo::Role;
use experimental 'signatures';
use Carp;

requires '_d';

# semantics of the cdpCacheCapabilities column; this seems to never have been
# officialy released; the only source I found is:
# https://community.cisco.com/t5/network-management/cdpcachecapabilities-where-is-the-cdp-spec/td-p/1120164
my %cdp_capabilities = (
  router => 0x01,
  bridge =>  0x02,
  srbridge => 0x04,
  switch => 0x08,
  host => 0x10,
  igmpfltr => 0x20,
  repeater => 0x40,
  phone => 0x80,
  rmdevice => 0x100,
);

#-------------------------------------------------------------------------------
# return cdpCacheTable entry if it exists, otherwise undef
sub cdp_port ($self, $if)
{
  my $s = $self->_d;

  if(
    exists $s->{'CISCO-CDP-MIB'}
    && exists $s->{'CISCO-CDP-MIB'}{'cdpCacheTable'}
    && exists $s->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if}
  ) {
    return $s->{'CISCO-CDP-MIB'}{'cdpCacheTable'}{$if};
  } else {
    return undef;
  }
}

#-------------------------------------------------------------------------------
# return true if there's single cdp devices discovered on supplied interface
# and it has the specified capability; if the device is missing the capability
# or there are multiple devices, return false
sub cdp_single_device_is($self, $if, $capability)
{
  my @cdpdevs;
  my $cdp_entry = $self->cdp_port($if);

  # no CDP entries exist
  return undef unless $cdp_entry;

  # get list of devices we see over CDP, return false if there's more than one
  # (or zero, but that should never happen)
  @cdpdevs = keys %$cdp_entry if $cdp_entry;
  return undef if @cdpdevs != 1;

  # check the caps
  my $caps = oct('0b0' . $cdp_entry->{$cdpdevs[0]}{cdpCacheCapabilities}{bitstring});
  for my $cap (keys %cdp_capabilities) {
    if($cdp_capabilities{$cap} & $caps) { return 1; }
  }
  return undef;
}

1;
