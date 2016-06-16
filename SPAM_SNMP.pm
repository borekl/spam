#!/usr/bin/perl

#===========================================================================
# Switch Ports Activity Monitor -- SNMP support library
# """""""""""""""""""""""""""""
# 2000 Borek Lupomesky <Borek.Lupomesky@oskarmobil.cz>
#===========================================================================


package SPAM_SNMP;
require Exporter;
use SPAMv2 qw(load_config file_lineread);
use Data::Dumper;

use integer;

@ISA = qw(Exporter);
@EXPORT = qw(
  snmp_entity_to_hwinfo
  snmp_system_info
  snmp_get_arptable
  snmp_vlanlist
  snmp_get_tree
);


#==========================================================================
# Select SNMP fields OIDs
#==========================================================================

my %snmp_fields = (
  sysObjectId => '.1.3.6.1.2.1.1.2.0',
  sysUpTime => '.1.3.6.1.2.1.1.3.0',
  #--- standard interface MIB ---
  ifDescr => ".1.3.6.1.2.1.31.1.1.1.1",
  ifType =>  ".1.3.6.1.2.1.2.2.1.3", # 6=ethernet,117=gigabitEther,
  ifSpeed => ".1.3.6.1.2.1.2.2.1.5",
  ifOperStatus => ".1.3.6.1.2.1.2.2.1.8", # 1=up,2=down,3=testing,4=unkn,5=dormant
  ifAdminStatus => ".1.3.6.1.2.1.2.2.1.7", # 1=up,2=down,3=testing
  ifInOctets => ".1.3.6.1.2.1.2.2.1.10",
  ifOutOctets => ".1.3.6.1.2.1.2.2.1.16",
  ifOutUcastPkts => ".1.3.6.1.2.1.2.2.1.17",
  ifInUcastPkts => ".1.3.6.1.2.1.2.2.1.11",
  dot1dTpFdbPort => ".1.3.6.1.2.1.17.4.3.1.2",
  dot1dTpFdbStatus => '.1.3.6.1.2.1.17.4.3.1.3',
  dot1dStpRootPort => ".1.3.6.1.2.1.17.2.7.0",
  dot1dBasePortIfIndex => '.1.3.6.1.2.1.17.1.4.1.2',
  #--- Cisco locIf ---
  locIfDescr => ".1.3.6.1.4.1.9.2.2.1.1.28",
  #--- Cisco Catalyst 6XXX port MIB ---
  portIfIndex => ".1.3.6.1.4.1.9.5.1.4.1.1.11",    # for conversion to ifindex
  portName => ".1.3.6.1.4.1.9.5.1.4.1.1.4", # user defined port description
  portType => ".1.3.6.1.4.1.9.5.1.4.1.1.5", # medium type
  portDuplex => ".1.3.6.1.4.1.9.5.1.4.1.1.10", # duplex status (1=half,2=full,3=disagree,4=auto)
  portSpantreeFastStart => ".1.3.6.1.4.1.9.5.1.4.1.1.12", # STP portfast (1=ena,2=dis)
  portAdditionalOperStatus => '.1.3.6.1.4.1.9.5.1.4.1.1.23', # Additional status info (bitfield)
  vlanPortVlan => '.1.3.6.1.4.1.9.5.1.9.3.1.3',
  vlanTrunkPortDynamicStatus => '.1.3.6.1.4.1.9.9.46.1.6.1.1.14', # 1=trunking,2=not trunking
  vlanTrunkPortEncapsulationOperType => '.1.3.6.1.4.1.9.9.46.1.6.1.1.16', # trunking encapsulation 1=ISL,4=802.1q
  moduleModel => '.1.3.6.1.4.1.9.5.1.3.1.1.17', # cisco.workgroup.ciscoStackMIB.moduleGrp.moduleTable.moduleEntry.moduleModel
  moduleSerialNumberString => '.1.3.6.1.4.1.9.5.1.3.1.1.26', # ...moduleSerialNumberString
  # C6xxx with IOS
  # portIfIndex
  ifIndex => ".1.3.6.1.2.1.2.2.1.1", #.iso.org.dod.internet.mgmt.mib-2.interfaces.ifTable.ifEntry.ifIndex
  # portName
  ifAlias => ".1.3.6.1.2.1.31.1.1.1.18", #.iso.org.dod.internet.mgmt.mib-2.ifMIB.ifMIBObjects.ifXTable.ifXEntry.ifAlias
  # moduleModel
  moduleModelIOS => ".1.3.6.1.4.1.9.9.92.1.1.1.3", #.iso.org.dod.internet.private.enterprises.cisco.ciscoMgmt.92.1.1.1.3
  moduleSerialNumberStringIOS => ".1.3.6.1.4.1.9.9.92.1.1.1.2", #
  #--- Cisco Catalyst 29XX port MIB ---
  c2900PortIfIndex => '.1.3.6.1.4.1.9.9.87.1.4.1.1.25', # for conversion to ifindex
  c2900PortDuplexStatus => '.1.3.6.1.4.1.9.9.87.1.4.1.1.32', # 1=full,2=half
  vmVlan => '.1.3.6.1.4.1.9.9.68.1.2.2.1.2',
  #--- other ---
  managementDomainName => '.1.3.6.1.4.1.9.9.46.1.2.1.1.2',
  managementDomainLocalMode => '.1.3.6.1.4.1.9.9.46.1.2.1.1.3',
  #--- VTP MIB ---
  vtpVlanName => '.1.3.6.1.4.1.9.9.46.1.3.1.1.4',
  #--- Etherlike MIB (supported by all but C2900 series ---
  dot3StatsDuplexStatus => '.1.3.6.1.2.1.10.7.2.1.19', # 2=half,3=full
  #--- dot1x IEEE MIB
  dot1xAuthAuthControlledPortControl => '.1.0.8802.1.1.1.1.2.1.1.6', # 1=forceUnauth,2=auto,3=forceAuth
  dot1xAuthAuthControlledPortStatus => '.1.0.8802.1.1.1.1.2.1.1.5', # 1=authorized,2=unauthorized
  #--- CAF MIB
  # cafSessionMethodState.<ifIndex>.<cafSessionId>.<cafSessionMethod> = INTEGER
  #   cafSessionMethod { 1:other, 2:dot1x; 3:MAB; 4:webAuth }
  #   cafSessionMethodState { 1:not run; 2:running; 3:failed; 4:auth success; 5:auth fail }
  cafSessionMethodState => '.1.3.6.1.4.1.9.9.656.1.4.2.1.2',
  #--- POWER-ETHERNET-MIB
  # pethPsePortDetectionStatus.<mod>.<port> = INTEGER
  #   1:disabled, 2:searching, 3:deliveringPower,4:fault
  pethPsePortDetectionStatus => '.1.3.6.1.2.1.105.1.1.1.6'
);


#==========================================================================
# Assemble SNMP command from supplied arguments.
#==========================================================================

sub snmp_command
{
  #--- argument and variables

  my ($command, $host, $community, $mibs, $root) = @_;
  my $cfg = load_config();

  #--- return if no config

  return undef if !ref($cfg);

  #--- return if non-existent command

  return undef if !exists($cfg->{'snmp'}{$command});
  my $cmd = join(' ',
    ( $cfg->{'snmp'}{$command}{'exec'},
    $cfg->{'snmp'}{$command}{'options'} )
  );

  #--- regularize MIBs list to always be an arrayref
  #--- note: at least one MIB must be passed in!

  if($mibs && !ref($mibs)) { $mibs = [ $mibs ]; }

  #--- stringify MIB list

  my $miblist = join(':', @$mibs);

  #--- tokens replacements

  $cmd =~ s/%c/$community/;
  $cmd =~ s/%h/$host/;
  $cmd =~ s/%r/$root/;
  $cmd =~ s/%m/+$miblist/;

  #--- finish

  return $cmd;
}


#==========================================================================
# Read SNMP command's output line by line.
#==========================================================================

sub snmp_lineread
{
  #--- argument and variables

  my @args = splice(@_, 0, 5);
  my $fn = shift;

  #--- prepare command

  my $cmd = snmp_command(@args);
  if(!$cmd) { return 'Failed to prepare SNMP command'; }

  #--- perform the read and finish

  return file_lineread($cmd, '-|', $fn);
}


#==========================================================================
# Retrieves VLAN list from Cat6XXX switch
#
# Arguments: 1. Host
#            2. Host's IP address (can be undef)
#            3. Community
# Return:    1. Hash (vlan-number -> vlan-name)
#==========================================================================

sub snmp_vlanlist
{
  my ($host, $ip, $community) = @_;
  my %vlan_list;
  my $vtpVlanName = $snmp_fields{vtpVlanName};

  if(!$ip) { $ip = $host; }
  open(SW, "$snmpwalk $ip -c $community $vtpVlanName |") or return undef;
  while(<SW>) {
    chomp;
    /\.(\d+) \"(.*)\"$/ && do {
      #--- we skip VLANs numbers above 999; these are special
      #--- and have special handling in some cases causing
      #--- long timeouts for some requests
      $vlan_list{$1} = $2 unless $1 > 999;
    };
  }
  close(SW);
  return \%vlan_list;
}


#===========================================================================
# Get SNMPv2-MIB system tree; this contains some essential info about the
# SNMP host incl. platform, uptime, location etc.
#
# Arguments: 1. host
#            2. community
# Returns:   1. SNMP tree (hashref) or error string
#            2. platform string from sysObjectID
#            3. system uptime converted into UNIX epoch format
#===========================================================================

sub snmp_system_info
{
  my ($host, $community) = @_;
  my $cfg = load_config();

  #--- the SNMPv2-MIB::system tree

  my $r = snmp_get_tree(
    'snmpwalk',
    $host,
    $community,
    $cfg->{'snmp'}{'system'}{'mib'},
    $cfg->{'snmp'}{'system'}{'entries'}[0],
  );

  #--- process the output

  if(!ref($r)) {
    return $r;
  } else {

  #--- strip the MIB from the left-side

    my $sysobjid = $r->{'sysObjectID'}{0}{'value'};
    $sysobjid =~ s/^.*:://;

  #--- convert uptime time-ticks to UNIX epoch value

    my $sysuptime = $r->{'sysUpTimeInstance'}{'value'};
    $sysuptime = time() - int($sysuptime / 100);
    return ($r, $sysobjid, $sysuptime);
  }
}


#===========================================================================
# Retrieve ARP entries from list of routers. It returns mac->ip address hash
# reference. The optional callback is there to facilitate caller-side
# progress info display; arguments are: 1. number of arp servers, 2. number
# of currently processed entry, 3. name of currently processed server.
#===========================================================================

sub snmp_get_arptable
{
  #--- arguments

  my (
    $arpdef,     # 1. arp servers list in form [ host, community ]
    $def_cmty,   # 2. default SNMP community
    $cb          # 3. callback (optional)
  ) = @_;

  #--- other variables

  my %tree;
  my %arptable;
  my $cfg = load_config();

  #-------------------------------------------------------------------------
  #--- read the relevant MIB sections --------------------------------------
  #-------------------------------------------------------------------------

  for my $arp_source (@$arpdef) {
    my $r;

  #--- SNMP community, either default or per-server

    my $cmty = $arp_source->[1] // $def_cmty;
    $tree{$arp_source->[0]} = {};

  #--- read the MIB tree

    for my $tree_root (@{$cfg->{'snmp'}{'arptable'}{'entries'}}) {
      $r = snmp_get_tree(
        'snmpwalk',
        $arp_source->[0],
        $cmty,
        $cfg->{'snmp'}{'arptable'}{'mib'},
        $tree_root
      );

  #--- handle the result

      if(!ref($r)) {
        die sprintf("failed to get arptable from %s (%s)", $arp_source->[0], $r);
      } else {
        my $t = $tree{$arp_source->[0]};
        %$t = ( %$t, %$r );
      }
    }

  #--- display message through callback

    if($cb) {
      $cb->($arp_source->[0]);
    }
  }

  #-------------------------------------------------------------------------
  #--- transform the data int the format used by spam.pl
  #-------------------------------------------------------------------------

  for my $host (keys %tree) {
    for my $if (keys %{$tree{$host}{'ipNetToMediaPhysAddress'}}) {
      for my $ip (keys %{$tree{$host}{'ipNetToMediaPhysAddress'}{$if}}) {
        if(
          $tree{$host}{'ipNetToMediaType'}{$if}{$ip}{'enum'} eq 'dynamic'
        ) {
          my $mac = $tree{$host}{'ipNetToMediaPhysAddress'}{$if}{$ip}{'value'};
          $mac = join(':', map {
            if(length($_) < 2) { $_ = '0' . $_; } else { $_; }
          } split(/:/, $mac));
          $arptable{$mac} = $ip;
        }
      }
    }
  }

  #--- finish

  return \%arptable;
}


#==========================================================================
# This function loads dot1dBasePortIfIndex table (mapping from dot1d
# index to ifIndex).
#
# Arguments: 1. host
#            2. community
#            3. vlan list (may be undefined)
#
# Returns:   1. hash ref (dot1dIdx -> ifIndex)
#==========================================================================

sub snmp_dot1d_idx
{
  my ($host, $ip, $community, $vlanlist) = @_;
  my @vlans;
  my %dot1dIdx;

  #--- processing arguments
  # if no vlanlist is passed to this function, the vlan list is fed single
  # dummy 'vlan 0', which causes the loop below to not use any vlan selector

  $community =~ s/\@.*//;
  if(defined $vlanlist) {
    @vlans = ( keys %$vlanlist );
  } else {
    @vlans = ( 0 );
  }

  #--- cycle through all VLANs

  foreach my $k (@vlans) {
    my $sel = ($k == 0 ? '' : "\@$k");
    open(F, "$snmpwalk $ip -c ${community}${sel} $snmp_fields{dot1dBasePortIfIndex} |") or return undef;
    while(<F>) {
      chomp;
      /\.(\d+) (\d+)$/ && do { $dot1dIdx{$1} = $2; }
    }
    close(F);
  }

  return \%dot1dIdx;
}


#==========================================================================
# This function retrieves hwinfo (processed select information from
# entPhysicalTable) and stores it into $swdata{hwinfo}. This function is 
# a stopgap designed to be fully compatible with previous function that
# that worked in the old way.
#==========================================================================

sub snmp_entity_to_hwinfo
{
  my ($h) = @_;
  my $ent = $h->{'ENTITY-MIB'};
  my %hw;
  my $cidx = 1000;     # incremental index for non-module components

  #--- iterate ver entPhysicalTable 

  for my $idx (sort keys %{$ent->{'entPhysicalClass'}}) {
    my $class = $ent->{'entPhysicalClass'}{$idx}{'enum'};
    my $physname = $ent->{'entPhysicalName'}{$idx}{'value'};
    my $container = $ent->{'entPhysicalContainedIn'}{$idx}{'value'};
    my $c_physname = $ent->{'entPhysicalName'}{$container}{'value'};

    #--- power supply, chassis

    if($class eq 'chassis' || $class eq 'powerSupply') {
      $physname =~ /^(?:Chassis (\d) ).*$/;
      my $chassis = $1;
      if(!$chassis) { $chassis = 0; }

      $hw{$chassis}{$cidx}{'type'} = $class;
      if($class eq 'powerSupply') {
        $hw{$chassis}{$cidx}{'type'} = 'ps';
      }
      $hw{$chassis}{$cidx}{'descr'}
      = $ent->{'entPhysicalDescr'}{$idx}{'value'};
      $hw{$chassis}{$cidx}{'model'}
      = $ent->{'entPhysicalModelName'}{$idx}{'value'};
      $hw{$chassis}{$cidx}{'sn'}
      = $ent->{'entPhysicalSerialNum'}{$idx}{'value'};
      $hw{$chassis}{$cidx}{'hwrev'}
      = $ent->{'entPhysicalHardwareRev'}{$idx}{'value'};
      $cidx++;
    }

    #--- module (linecard)

    if(
      $class eq 'module'
      && $c_physname =~ /^(?:Chassis (\d) |)Physical Slot (\d)+$/
    ) {
      my $slot = $2;
      my $chassis = $1;
      if(!$chassis) { $chassis = 0; }

      $hw{$chassis}{$slot}{'type'} = 'linecard';
      $hw{$chassis}{$slot}{'model'}
      = $ent->{'entPhysicalModelName'}{$idx}{'value'};
      $hw{$chassis}{$slot}{'sn'}
      = $ent->{'entPhysicalSerialNum'}{$idx}{'value'};
      $hw{$chassis}{$slot}{'hwrev'}
      = $ent->{'entPhysicalHardwareRev'}{$idx}{'value'};
      $hw{$chassis}{$slot}{'fwrev'}
      = $ent->{'entPhysicalFirmwareRev'}{$idx}{'value'};
      $hw{$chassis}{$slot}{'swrev'}
      = $ent->{'entPhysicalSoftwareRev'}{$idx}{'value'};
      $hw{$chassis}{$slot}{'descr'}
      = $ent->{'entPhysicalDescr'}{$idx}{'value'};
    }
  }

  #--- finish

  return \%hw;
}


#==========================================================================
# Function for parsing SNMP values as returned snmp-utils.
#==========================================================================

sub snmp_value_parse
{
  my $value = shift;
  my %re;

  #--- integer

  if($value =~ /^INTEGER:\s+(\d+)$/) {
    $re{'type'} = 'INTEGER';
    $re{'value'} = $1 + 0;
  }

  #--- integer-enum

  elsif($value =~ /^INTEGER:\s+(\w+)\((\d+)\)$/) {
    $re{'type'} = 'INTEGER';
    $re{'value'} = $2;
    $re{'enum'} = $1;
  }

  #--- string

  elsif($value =~ /^STRING:\s+(.*)$/) {
    $re{'type'} = 'STRING';
    $re{'value'} = $1;
  }

  #--- gauge

  elsif($value =~ /^Gauge(32|64): (\d+)$/) {
    $re{'type'} = 'Gauge';
    $re{'bitsize'} = $1;
    $re{'value'} = $2 + 0;
  }

  #--- counter

  elsif($value =~ /^Counter(32|64): (\d+)$/) {
    $re{'type'} = 'Counter';
    $re{'bitsize'} = $1;
    $re{'value'} = $2 + 0;
  }

  #--- timeticks

  elsif($value =~ /Timeticks:\s+\((\d+)\)\s+(.*)\.\d{2}$/) {
    $re{'type'} = 'Timeticks';
    $re{'value'} = $1;
    $re{'fmt'} = $2;
  }

  #--- hex string

  elsif($value =~ /^Hex-STRING:\s+(.*)$/) {
    $re{'type'} = 'Hex-STRING';
    my @v = split(/\s/, $1);
    if(scalar(@v) == 6) {
      $re{'value'} = lc(join(':', @v));
    } else {
      $re{'value'} = lc($1);
    }
  }

  #--- MIB reference

  elsif($value =~ /^([\w-]+)::(\w+)$/) {
    $re{'type'} = 'Ref';
    $re{'mib'} = $1;
    $re{'value'} = $2;
  }

  #--- generic type:value

  elsif($value =~ /^(\w+): (.*)$/) {
    $re{'type'} = 'generic';
    $re{'gentype'} = $1;
    $re{'value'} = $2;
  }

  #--- uncrecognized output

  else {
    $re{'type'} = 'unknown';
    $re{'value'} = $value;
  }

  #--- finish

  return \%re;
}


#==========================================================================
# Get SNMP sub-tree and store it into a hashref. First five arguments are
# the same as for snmp_lineread(), sixth argument is optional callback
# that receives line count as argument (for displaying progress indication)
# The callback can optionally return number of seconds that determine the
# period it should be called at.
#==========================================================================

sub snmp_get_tree
{
  #--- arguments (same as to snmp_lineread)

  # arguments 0..5 are those of snmp_lineread(); the last argument is
  # optional and is an callback intended for displaying progress status that
  # is invoked with (VARIABLE, CNT) where variable is SNMP variable
  # currently being processed and CNT is entry counter that's zeroed for
  # each new variable.  This callback is invoked only when: a) the variable
  # being read is different from previous one (ie.  reading of one variable
  # finished), or specified amount of time passed between now and the last
  # time the callback was called.  Default delay is 1 second, but it can be
  # specified on callback invocation: the returned value will be used for
  # the rest of the invocations.  Granularity is only 1 second (the
  # implementation uses time() function).

  my @args = splice(@_, 0, 5);
  my $cback = shift;

  #--- other variables

  my %re;
  my $cnt = 0;
  my $tm1 = time();
  my $var1;
  my $delay = 1;
  my $fh;

  #--- initiate debugging

  if($ENV{'SPAM_DEBUG'}) {
    open($fh, '>>', "snmp_tree.$$.log");
    if($fh) {
      printf $fh "--> SNMP TREE %s::%s", $args[3], $args[4];
      if($args[2] =~ /\@(\d+)$/) {
        printf $fh " (%d)", $1;
      }
      print $fh "\n";
      printf $fh "--> %s\n", snmp_command(@args);
    }
  }

  #--- initial callback call

  if($cback) {
    my $rv = $cback->(undef, $cnt);
    $delay = $rv if $rv > 0;
  }

  #--- main loop ------------------------------------------------------------

  my $r = snmp_lineread(@args, sub {
    my $l = shift;
    my $tm2;

  #--- FIXME: skip lines that don't contain '='

  # This is ugly hack to work around the way snmp-utils display long binary
  # strings (type "Hex-STRING"): these are displayed on multiple lines, which
  # causes problems with current way of parsing the output. So this should
  # be reimplemented to accomodate this, but meanwhile we just slurp the hex
  # values on the first line and discard the rest.
  
    return if $l !~ /=/;
  
  #--- split into variable and value

    my ($var, $val) = split(/ = /, $l);

  #--- parse the right side (value)

    my $rval = snmp_value_parse($val);
    if($ENV{'SPAM_DEBUG'}) {
      $rval->{'src'} = $l;
    }

  #--- parse the left side (variable, indexes)

    $var =~ s/^.*:://;  # drop the MIB name

  #--- get indexes

  # left side as output by SNMP utils with -OX option appears in one of the
  # three forms (with corresponding sections of code below):
  #   1. snmpVariable.0
  #   2. snmpVariable
  #   2. snmpVariable[idx1][idx2]...[idxN]

    my @i;
    if($var =~ s/\.0$//) {
      @i = (0);
    } elsif($var =~ /^\w+$/) {
      @i = ();
    } else {
      $idx = $var;
      $idx =~ s/^([^\[]*)\[(.*)\]$/$2/;
      $var = $1;
      @i = split(/\]\[/, $idx);
      for (@i) { 
        s/^"(.*)"$/$1/;      # drop double quotes around index value
        s/^STRING:\s*//;     # drop type prefix from strings
      }
    }

  #--- store the values

  # following code builds hash so that [0][1][2] becomes $h->{0}{1}{2};
  # the hash creation is additive, so preexisting hashes are reused, not
  # overwritten

    if(!ref($re{$var})) { $re{$var} = {}; }
    my $h = $re{$var};
    if(@i) {
      for my $k (@i[0 .. $#i-1]) {
        $h->{$k} = {} if !ref($h->{$k});
        $h = $h->{$k};
      }
      $h->{$i[-1]} = $rval;
    } else {
      $re{$var} = $rval;
    }
  
  #--- debugging info
  
    if($fh) {
      my $rval_txt = join(',', %$rval);
      printf $fh "%s.%s = %s\n", $var, join('.', @i), $rval_txt;
    }

  #--- line counter

    $cnt++;

  #--- callback

    $tm2 = time();
    if($var1 ne $var) {
      $cnt = 0;
      $tm1 = $tm2;
      $var1 = $var;
      $cback->($var, $cnt) if $cback;
    } elsif(($tm2 - $tm1) >= $delay) {
      $cback->($var, $cnt) if $cback;
      $tm1 = $tm2;
    }

  #--- finish callback

    return undef;
  });

  #--- finish ---------------------------------------------------------------

  close($fh) if $fh;
  return $r ? $r : \%re;
}


#my $cfg = load_config('spam.cfg.json');
#printf("Getting ifTable:    0");
#my $r = snmp_get_tree(
#  'snmpwalk', 'stos20', '600meC73nerOK', 'IF-MIB', 'ifTable',
#  sub {
#    local $| = 1;
#    printf("\b\b\b\b%4d", $_[0]);
#    return 2;
#  }
#);
#if(!ref($r)) {
#  print $r, "\n";
#} else {
#  print "\nfinished\n";
#}

1;
