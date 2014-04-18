#!/usr/bin/perl

#===========================================================================
# Switch Ports Activity Monitor -- SNMP support library
# """""""""""""""""""""""""""""
# 2000 Borek Lupomesky <Borek.Lupomesky@oskarmobil.cz>
#===========================================================================


package SPAM_SNMP;
require Exporter;
use integer;

@ISA = qw(Exporter);
@EXPORT = qw(
  snmp_getif
  snmp_getif_cafSMS
  snmp_getif_cat
  snmp_reindex_cat
  snmp_merge_by_ifindex
  snmp_cat6k_modinfo
  snmp_cat4k_ios_modinfo
  snmp_cat6k_ios_modinfo
  snmp_hwinfo_entity_mib
  snmp_cat6k_vlan_name
  snmp_cdp_cache
  snmp_get_syslocation
  snmp_get_sysobjid
  snmp_get_sysuptime
  snmp_get_arptable
  snmp_mac_table
  snmp_get_stp_root_port
  snmp_get_vtp_info
  snmp_vlanlist
  snmp_portfast
);


#$snmpwalk = "/usr/bin/snmpbulkwalk -t 10 -m /dev/null -v 2c -Osqn -Iu";
#$snmpwalk = "snmpwalk -t 10 -m /dev/null -Os -Oq";
#$snmpget = "/usr/bin/snmpget -t 10 -m /dev/null -Osqn -v 2c -Iu";


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
  # Cat6500 IOS
  entPhysicalEntry => '.1.3.6.1.2.1.47.1.1.1.1',
  entPhysicalContainedIn => '.1.3.6.1.2.1.47.1.1.1.1.4',
  entPhysicalClass => '.1.3.6.1.2.1.47.1.1.1.1.5',
  entPhysicalModelName => ".1.3.6.1.2.1.47.1.1.1.1.13",
  entPhysicalSerialNum => ".1.3.6.1.2.1.47.1.1.1.1.11",
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
  #--- CISCO-STP-EXTENSIONS-MIB
  stpxFastStartPortEnable => '.1.3.6.1.4.1.9.9.82.1.9.3.1.2', # 1=true,2=false
  stpxFastStartPortMode => '.1.3.6.1.4.1.9.9.82.1.9.3.1.3', # 1=ena,2=disa,3=trunk,4=default
  #--- dot1x IEEE MIB
  dot1xAuthAuthControlledPortControl => '.1.0.8802.1.1.1.1.2.1.1.6', # 1=forceUnauth,2=auto,3=forceAuth
  dot1xAuthAuthControlledPortStatus => '.1.0.8802.1.1.1.1.2.1.1.5', # 1=authorized,2=unauthorized
  #--- CAF MIB
  # cafSessionMethodState.<ifIndex>.<cafSessionId>.<cafSessionMethod> = INTEGER
  #   cafSessionMethod { 1:other, 2:dot1x; 3:MAB; 4:webAuth }
  #   cafSessionMethodState { 1:not run; 2:running; 3:failed; 4:auth success; 5:auth fail }
  cafSessionMethodState => '.1.3.6.1.4.1.9.9.656.1.4.2.1.2'
);


#==========================================================================
# This function pulls given ifEntry field for all interfaces  from SNMP
# agent.
#
# Arguments: 1. host
#            2. community
#            3. field
# Returns:   1. ifindex -> value hash reference or undef on error
#==========================================================================

sub snmp_getif
{
  my ($host, $ip, $community, $field) = @_;
  my %result;
  my $oid = $snmp_fields{$field};

  if(!$oid) { return undef; }
  open(F, "$snmpwalk $ip -c $community $oid |") or return undef;
  while(<F>) {
    chomp;
    my ($if, $val);
    /^[0-9.]*\.(\d+) (.*)$/ && do {
      $if = $1; $oval = $2;
      if($oval =~ /^"(.*)"$/) { $val = $1; }
      else { $val = $oval; }
      $result{$if} = $val;
    };
  }
  close(F);  
  return \%result;
}


#==========================================================================
# This function pulls info from cafSessionMethodState variable.
#
# Arguments: 1. host
#            2. community
#            3. field
#==========================================================================

sub snmp_getif_cafSMS
{
  my ($host, $ip, $community) = @_;
  my $oid = $snmp_fields{cafSessionMethodState};
  my %result;

  if(!$oid) { return undef; }
  open(F, "$snmpwalk $ip -c $community $oid |") or return undef;
  while(<F>) {
    chomp;
    /^(\.\d+){14}\.(\d+)(\.\d+){25}\.(\d+)\s(\d+)/ && do {
      my ($if, $method, $val) = ($2, $4, $5);
      $result{$if}{$method} = $val;
    };
  }
  close(F);
  return \%result;
}


#==========================================================================
# This function pulls given ifPort/c2900PortEntry field for all interfaces
# from SNMP agent. This function is specific to Catalyst 6XXX/29XX switches
# as they have different indexing scheme for many fields. The hash key here
# is "module/port" string.
#
# Arguments: 1. host
#            2. community
#            3. field
# Returns:   1. "module/port" -> value hash reference
#==========================================================================

sub snmp_getif_cat
{
  my ($host, $ip, $community, $field) = @_;
  my %result;
  my $oid = $snmp_fields{$field};

  if(!$oid) { return undef; }
  open(F, "$snmpwalk $ip -c $community $oid |") or return undef;
  while(<F>) {
    chomp;
    my ($p1, $p2, $val);
    /^.*\.(\d+)\.(\d+) (.*)$/ && do {
      $p1 = $1; $p2 = $2; $val = $3;
      if($val =~ /^"(.*)"$/) { $val = $1; }
      $result{"$p1/$p2"} = $val;
    };
  }
  close(F);  
  return \%result;
}


#==========================================================================
# This function reindexes data retrieved using snmp_getif_cat() call
# to standard ifindex way.
#
# Arguments: 1. data to be reindexed (hash reference)
#            2. cross index (portIfIndex data, hash reference)
# Returns:   1. ifindex -> value hash reference
#
# Example:   $data = snmp_getif_cat($host, "gere167DE", "portName");
#            $idx = snmp_getif_cat($host, "gere167DE", "portIfIndex");
#            $result = snmp_reindex_cat($data, $idx);
#==========================================================================

sub snmp_reindex_cat
{
  my ($ifdata, $xidx) = @_;
  my %result;

  if(!$ifdata || !$xidx) { return undef; }
  foreach my $k (keys %$ifdata) {
    my $ifindex = $xidx->{$k};
    $result{$ifindex} = $ifdata->{$k};
  }
  return \%result;
}


#==========================================================================
# This function merges several hashes from snmp_getif into one that has
# array references; where the values are the respective hash values.
# 
# Arguments: 1. reference to array of hash references (from snmp_getif)
#==========================================================================

sub snmp_merge_by_ifindex
{
  my ($in) = @_;
  my %result;
  my $i = 0;
  my @keys;

  #--- create list of all hash keys ---
  foreach my $k (@$in) {
    foreach my $l (keys %$k) {
      if(grep { $_ == $l } @keys) {
        next;
      } else {
        push(@keys, $l);
      }
    }
  }

  #--- now run through the keys ---
  foreach my $k (@keys) {
    my @valarr;
    foreach my $l (@$in) {
      push(@valarr, $l->{$k});
    }
    $result{$k} = \@valarr;
  }

  return \%result;
}


#==========================================================================
# This function retrieves information about modules installed in a Catalyst
# 6XXX switch (serial number and model).
#
# Arguments: 1. host
#            2. community
# Returns:   1. %modinfo. hash reference or error message string in form
#                     %modinfo -> MOD-NUMBER -> [sn|model] -> value
#==========================================================================

sub snmp_cat6k_modinfo
{
  die; ### THIS FUNCTION NO LONGER IN USE
  
  my ($host, $ip, $community) = @_;
  my %modinfo;
  my $moduleModel = $snmp_fields{moduleModel};
  my $moduleSerialNumberString = $snmp_fields{moduleSerialNumberString};
  
  eval {

    #--- module model ---

    open(SW, "$snmpwalk -c $community $ip $moduleModel |") or die "Cannot run snmp command\n";
    #open(SW, "$snmpwalk $host $community .1.3.6.1.4.1.9.5.1.3.1.1.17 |") or die "Cannot run snmp command\n";
    while(<SW>) {
      /\.(\d{1,2}) \"(.*)\"$/ && do { $modinfo{$1}{model} = $2; };
    }
    close(SW);
    #--- module serial number ---
    open(SW, "$snmpwalk -c $community $ip $moduleSerialNumberString |") or die "Cannot run snmp command\n";
    #open(SW, "$snmpwalk $host $community .1.3.6.1.4.1.9.5.1.3.1.1.26 |") or die "Cannot run snmp command\n";
    while(<SW>) {
      chomp;
      /\.(\d{1,2}) \"(.*)\"$/ && do { $modinfo{$1}{sn} = $2; }
    }
    close(SW);  
  };
  if($@) {
    chomp($@);
    return 'failed (' . $@ . ')';
  }
  return \%modinfo;
}


#==========================================================================
# Retrieve VLAN name from Cisco Catalyst 6XXX switch
#==========================================================================

sub snmp_cat6k_vlan_name
{
  die; ### THIS FUNCTION NOT IN USE
  
  my ($host, $ip, $community, $vn) = @_;

  open(SW, "$snmpget $ip -c $community .1.3.6.1.4.1.9.9.46.1.3.1.1.4.1.$vn |") or return undef;
  $_ = <SW>;
  chomp;
  /^.*\"(.*)\"$/;
  close(SW);
  return $1;
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


#==========================================================================
# Retrieves CDP cache from Cisco device
#
# Arguments: 1. Host
#            2. Community
# Returns:   1. Resulting hash reference in form
#               % -> IFINDEX -> [platform|caps|devport] -> VALUE
#==========================================================================

sub snmp_cdp_cache
{
  my ($host, $ip, $community) = @_;
  my %cdp_cache;
  my $cdpCachePlatform = ".1.3.6.1.4.1.9.9.23.1.2.1.1.8";
  my $cdpCacheCapabilities = ".1.3.6.1.4.1.9.9.23.1.2.1.1.9";
  my $cdpCacheDevicePort = ".1.3.6.1.4.1.9.9.23.1.2.1.1.7";

  #--- platform ---
  open(SW, "$snmpwalk $ip -c $community $cdpCachePlatform |") or return undef;
  while(<SW>) {
    chomp;
    /\.(\d+)\.\d+ \"(.*)\"$/ && do { $cdp_cache{$1}{platform} = $2; };
  }
  close(SW);

  #--- capabilities ---
  open(SW, "$snmpwalk $ip -c $community $cdpCacheCapabilities |") or return undef;
  while(<SW>) {
    chomp;
    /\.(\d+)\.\d+ \"(.*)\"$/ && do {
      my $if = $1;
      my $caps = $2;
      $caps =~ /^([0-9A-F]{2}) ([0-9A-F]{2}) ([0-9A-F]{2}) ([0-9A-F]{2}) $/;
      $cdp_cache{$if}{caps} = hex("$1$2$3$4");
    };
  }
  close(SW);

  #--- device port ---
  open(SW, "$snmpwalk $ip -c $community $cdpCacheDevicePort |") or return undef;
  while(<SW>) {
    chomp;
    /\.(\d+)\.\d+ \"(.*)\"$/ && do {
      my ($if, $p) = ($1, $2);
      $p =~ s/\s$//g;
      $cdp_cache{$if}{devport} = $p;
    };
  }
  close(SW);

  return \%cdp_cache;
}


#===========================================================================
# Get SNMP sysLocation variable
#
# Arguments: 1. host
#            2. community
# Returns:   1. value of sysLocation variable
#===========================================================================

sub snmp_get_syslocation
{
  my ($host, $ip, $community) = @_;
  
  open(SW, "$snmpget $ip -c $community .1.3.6.1.2.1.1.6.0 |") or return undef;
  $_ = <SW>;
  chomp;
  /\"(.*)\"$/;
  close(SW);
  return $1;
}


#===========================================================================
# Get SNMP sysObjectId and sysUpTime variables
#
# Arguments: 1. host
#            2. community
# Returns:   1. value of enterprise id
#            2. value of device id (two numbers connected with a dot)
#            3. last reload time in UNIX format
#===========================================================================

sub snmp_get_sysobjid
{
  my ($host, $ip, $community) = @_;
  my $sysObjId = $snmp_fields{sysObjectId};
  my ($vid, $model);
  
  open(SW, "$snmpget $ip -c $community $sysObjId |") or return undef;
  $_ = <SW>;
  chomp;
  /\.(\d+)\.(\d+)$/;
  $model = "$1.$2";
  /^.*\s+\.\d+\.\d+.\d+\.\d+\.\d+\.\d+\.(\d+)/;
  $vid = $1;
  close(SW);

  return($vid, $model);
}


#===========================================================================
# Get SNMP sysUpTime variables
#
# Arguments: 1. host
#            2. community
# Returns:   1. last reload time in UNIX format
#===========================================================================

sub snmp_get_sysuptime
{
  my ($host, $ip, $community) = @_;
  my $sysUpTime = $snmp_fields{sysUpTime};
  my ($d, $h, $m, $s, $t);

  open(SW, "$snmpget $ip -c $community $sysUpTime |") or return undef;
  $_ = <SW>;
  chomp;
  / (\d+):(\d+):(\d+):(\d+\.\d+)$/;
  close(SW);
  ($d, $h, $m, $s) = ($1, $2, $3, $4);
  $t = time();
  $s = int($s + 0.5);
  $u = $s + ($m * 60) + ($h * 3600) + ($d * 86400);
  $v = $t - $u;

  return $v;
}


#===========================================================================
# Get VTP domain name and VTP mode for a switch
#
# Arguments: 1. host
#            2. community
# Returns:   1. VTP domain name
#            2. VTP mode (1 - client, 2 - server, 3 - transparent)
#===========================================================================

sub snmp_get_vtp_info
{
  my ($host, $ip, $community) = @_;
  my $vtp_n = $snmp_fields{managementDomainName};
  my $vtp_m = $snmp_fields{managementDomainLocalMode};
  my ($name, $mode);

  open(SW, "$snmpget $ip -c $community ${vtp_n}.1 |") or return undef;
  $_ = <SW>;
  chomp;
  / \"(.*)\"$/;
  close(SW);
  $name = $1;

  open(SW, "$snmpget $ip -c $community ${vtp_m}.1 |") or return undef;
  $_ = <SW>;
  chomp;
  / (\d+)$/;
  $mode = $1;

  return($name, $mode);
}


#===========================================================================
# Get STP Root port ifindex
#
# Arguments: 1. host
#            2. community
# Returns:   1. root port ifindex, -1 in case of root bridge or undef in
#               case of error
#===========================================================================

sub snmp_get_stp_root_port
{
  my ($host, $ip, $community) = @_;
  my $oid = $snmp_fields{dot1dStpRootPort};
  my ($i, $if);

  open(SW, "$snmpget $ip -c $community $oid |") or return undef;
  $_ = <SW>;
  chomp;
  /(\d+)$/;
  close(SW);
  $i = $1;
  if($i == 0) { return -1; } # this switch is designated root 
  $oid = $snmp_fields{dot1dBasePortIfIndex} . ".$i";
  open(SW, "$snmpget $ip -c $community $oid |") or return undef;
  $_ = <SW>;
  chomp;
  /(\d+)$/;
  close(SW);
  return $1;  
}


#===========================================================================
# Retrieve ARP entries from list of routers
#
# Arguments: 1. arp hosts list with entries in form [ host, community ]
#            2. default community
#            3. callback that gets three arguments; undef means no callback
#               2a. number of arp servers
#               2b. number of currently processed arp server
#               2c. name of currently processed arp server
# Returns:   1. MAC->IP hash reference
#===========================================================================


sub snmp_get_arptable
{
  my ($arpdef, $def_cmty, $disp_callback)= @_;
  my %arptable;
  my $arpserv_num = scalar(@$arpdef);
  my $arpserv_cur = 1;

  for my $serv (@$arpdef) {
    my $cmty = $serv->[1];
    if(!$cmty) { $cmty = $def_cmty; }
    if($disp_callback) { &$disp_callback($arpserv_num, $arpserv_cur, $serv); }
    open(F, "$snmpwalk " . $serv->[0] . " -c " . $cmty 
         . " .1.3.6.1.2.1.4.22 |") or return undef;
    while(<F>) {
      /\.\d+\.(\d+)\.(\d+)\.(\d+)\.(\d+) \"(..) (..) (..) (..) (..) (..) \"/ && do {
        my $ip = "$1.$2.$3.$4";
        my $mac = "${5}:${6}:${7}:${8}:${9}:${10}";
        if(!exists $arptable{$mac}) {
          $arptable{$mac} = $ip;
        }
      }
    }
    close(F);
    $arpserv_cur++;
  }
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
# This function retrieves MAC address table associated with switch ports.
# 
# Arguments: 1. host
#            2. community
#            3. vlan list (may be undef'd)
#            4. CDP cache (result of snmp_cdp_cache())
#            5. callback that gets arguments:
#               a - number of MACs so far
#==========================================================================

sub snmp_mac_table
{
  my ($host, $ip, $community, $vlanlist, $cdpcache, $disp_callback) = @_;
  my %macs;
  my %macs_status;
  my @vlans;
  my $macs_cur = 0;
  my $com;
  my %macs_plain;    # for removing duplicities
  
  #--- process community argument
  
  $com = $community;
  $com =~ s/@.*$//;
  
  #--- get vlan list (dummy 'vlan 0' if none supplied)
  
  &$disp_callback(0) if defined $disp_callback;
  if(defined $vlanlist) {
    @vlans = ( keys %$vlanlist );
  } else {
    @vlans = ( 0 );
  }

  ### NEW CODE ###
  
  #my %macs_dot1d;
  #foreach my $k (@vlans) {
  #  my $macs_per_vlan = 0;
  #  open(F, "$snmpwalk $ip -c ${com}${sel} $snmp_fields{dot1dTpFdbPort} |") || return undef;
  #  while(<F>) {
  #    chomp();
  #    # $1-6 contain MAC address octets, $7 contains dot1d index number
  #    /\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\s+(\d+)$/ && do {
  #      my $mac = sprintf("%02x:%02x:%02x:%02x:%02x:%02x", $1, $2, $3, $4, $5, $6);
  #      $macs_dot1d{$7} = $mac;
  #      $macs_per_vlan++;
  #    };
  #  }
  #  close(F);
  #  next if $macs_per_vlan == 0;
  #}
  
  ################
  
  #--- cycle through all VLANs

  foreach my $k (@vlans) {
    my $sel = ($k == 0 ? "" : "\@$k");
    # my $dot1dIdx = snmp_dot1d_idx($host, $ip, $community, $vlanlist);
    my $dot1dIdx = snmp_dot1d_idx($host, $ip, $community, {$k => undef});

    #--- second get the bridging table (MAC -> status)

    open(F, "$snmpwalk $ip -c ${com}${sel} $snmp_fields{dot1dTpFdbStatus} |") or return undef;
    while(<F>) {
      chomp;
      /\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\s+(\d+)$/ && do {
        my $mac = sprintf("%02x:%02x:%02x:%02x:%02x:%02x", $1, $2, $3, $4, $5, $6);
        $macs_status{$mac} = $7;
      }
    }
    close(F);
    
    #--- then get the bridging table (MAC -> port)

    open(F, "$snmpwalk $ip -c ${com}${sel} $snmp_fields{dot1dTpFdbPort} |") or return undef;
    while(<F>) {
      chomp; 
      /\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\s+(\d+)$/ && do {
        my $mac = sprintf("%02x:%02x:%02x:%02x:%02x:%02x", $1, $2, $3, $4, $5, $6);
        my $if = $dot1dIdx->{$7};

        # ignoring all ports receiving CDP packets; this certainly isn't
        # optimal, since it causes ports connecting to routers to be
        # ignored as well

        if(!exists $cdpcache->{$if}) {
        
#          if((grep { $_ eq $mac; } @{$macs{$if}}) == 0   # add only macs we've not seen before
#             && $macs_status{$mac} == 3) {               # AND add only learned macs
          if(
            !exists($macs_plain{$mac})   # add only macs we've not seen before
            && ( $macs_status{$mac} == 3 || $macs_status{$mac} == 5)
          ) {               # AND add only learned macs
            push(@{$macs{$if}}, $mac);
            $macs_plain{$mac} = undef;
            $macs_cur++;
            &$disp_callback($macs_cur) if defined $disp_callback;
          }
        }
      }
    }
    close(F);
  }
  return \%macs;
}


#==========================================================================
# This function loads portfast mode of switch ports.
#
#==========================================================================

sub snmp_portfast
{
  my ($host, $ip, $community, $vlanlist) = @_;
  my $dot1dIdx = snmp_dot1d_idx($host, $ip, $community, $vlanlist);
  my %r;
  
  #--- processing arguments
  
  if(defined $vlanlist) {
      @vlans = ( keys %$vlanlist );
  } else {
    @vlans = ( 0 );
  }
  my $com = $community;
  $com =~ s/\@.*// ;

  return undef if !ref($dot1dIdx);
    
  #--- iterate over all VLANs

  foreach my $k (@vlans) {
    my $sel = ($k == 0 ? "" : "\@$k");
    my $s = "$snmpwalk $ip -c ${com}${sel} $snmp_fields{stpxFastStartPortMode} |";
    open(F, $s) or return undef;
    while(<F>) {
      chomp;
      /\.(\d+)\s(\d)$/ && do {
        my ($idx,$val) = ($1, $2);
        $r{$dot1dIdx->{$idx}} = $val;
      };
    }
  }
  return \%r;
}


#==========================================================================
# This function retrieves information about modules installed in a Catalyst
# 6XXX switch with IOS (serial number and model).
#
# Arguments: 1. host
#            2. community
# Returns:   1. %modinfo  hash reference or error message string in form
#                     %modinfo -> MOD-NUMBER -> [sn|model] -> value
#==========================================================================

sub snmp_cat6k_ios_modinfo
{
  my ($host, $ip, $community) = @_;
  my %modinfo;
  #my $entPhysicalModelName = $snmp_fields{entPhysicalModelName};
  #my $entPhysicalSerialNum = $snmp_fields{entPhysicalSerialNum};
  my $cmd_snmp_model = "$snmpwalk -c $community $ip .1.3.6.1.4.1.9.5.1.3.1.1.17 |";
  my $cmd_snmp_serial = "$snmpwalk -c $community $ip .1.3.6.1.4.1.9.5.1.3.1.1.26 |";

  eval {
    #--- module model ---
    open(SW, $cmd_snmp_model) or die "Cannot run snmp command\n";
    while(<SW>) {
      /\.(\d) \"(.*)\"$/ && do {
        $modinfo{$1}{model} = $2;
        $modinfo{$1}{type} = 'linecard';
      };
    }
    close(SW);
    #--- module serial number ---
    open(SW, $cmd_snmp_serial) or die "Cannot run snmp command\n";
    while(<SW>) {
      chomp;
      /\.(\d) \"(.*)\"$/ && do {
        $modinfo{$1}{sn} = $2;
        $modinfo{$1}{type} = 'linecard';
      }
    }
    close(SW);
  };
  if($@) {
    chomp($@);
    return 'failed (' . $@ . ')';
  }
  return \%modinfo;
}


#==========================================================================
# This function retrieves information about components installed in
# a Catalyst 6000-series switch with IOS.
#
# Uses ENTITY-MIB.
#
# Arguments: 1. host
#            2. community
# Returns:   1. %modinfo  hash reference or error message string in form
#                     %modinfo -> MOD-NUMBER -> [sn|model] -> value
#==========================================================================

sub snmp_hwinfo_entity_mib
{
  my ($host, $ip, $community) = @_;
  my $hwinfo;
  my %tmpinfo;
  my $check;
  my $cidx = 1000;     # incremental index for non-module components
  my $cmd_snmp_phys = sprintf('%s -c %s %s %s |', $snmpwalk, $community, $ip, $snmp_fields{entPhysicalEntry});

  eval {

    #--- read entire entPhysicalTable

    open(SW, $cmd_snmp_phys) || die "Cannot run snmp command\n";
    while(<SW>) {
      /\.(\d+)\.(\d+) (\d+)$/ && do { #--- numeric value
        $tmpinfo{$1}{$2} = $3;
      };
      /\.(\d+)\.(\d+) \"(.*)\"$/ && do { #--- string value
        $tmpinfo{$1}{$2} = $3;
      };
    }
    close(SW);

    #--- check if ENTITY-MIB is really supported
    
    $check = 0;
    for my $idx (keys %{$tmpinfo{11}}) {
      if($tmpinfo{11}{$idx}) { $check = 1; last; }
    }
    if(!$check) {
      #--- fallback call
      my $ret = snmp_cat6k_ios_modinfo($host, $ip, $community);
      if(!$ret || !ref($ret)) {
        die "Failed ($ret)";
      }
      $hwinfo = $ret;
      return;
    }
    
    #--- processing

    for my $idx (keys %{$tmpinfo{5}}) {
      if($tmpinfo{5}{$idx} == 3) {
        $hwinfo->{$cidx}{type} = 'chassis';
      }
      elsif($tmpinfo{5}{$idx} == 6) {
        $hwinfo->{$cidx}{type} = 'ps';
      }
      elsif($tmpinfo{5}{$idx} == 9) {
        my $container = $tmpinfo{4}{$idx};
        #next if $tmpinfo{5}{$container} == 9;
        my $physdescr = $tmpinfo{7}{$container};
        $physdescr =~ /slot (\d+)/i && do {
          my $slot = $1;
          $hwinfo->{$slot}{type} = 'linecard';
          $hwinfo->{$slot}{model} = $tmpinfo{13}{$idx};
          $hwinfo->{$slot}{sn} = $tmpinfo{11}{$idx};
          $hwinfo->{$slot}{hwrev} = $tmpinfo{8}{$idx};
          $hwinfo->{$slot}{fwrev} = $tmpinfo{9}{$idx};
          $hwinfo->{$slot}{swrev} = $tmpinfo{10}{$idx};
          $hwinfo->{$slot}{descr} = $tmpinfo{2}{$idx};
        };
        next;
      } else {
        next;
      }
      $hwinfo->{$cidx}{sn} = $tmpinfo{11}{$idx};
      $hwinfo->{$cidx}{model} = $tmpinfo{13}{$idx};
      $hwinfo->{$cidx}{descr} = $tmpinfo{2}{$idx};
      $cidx++;
    }
  };

  if($@) {
    chomp($@);
    return 'failed (' . $@ . ')';
  }
  return $hwinfo;
}


#==========================================================================
#==========================================================================

sub snmp_cat4k_ios_modinfo
{
  die; ### FUNCTION NOT IN USE
  
  my ($host, $ip, $community) = @_;
  my %modinfo;
  my $cmd_snmp_model = "$snmpwalk -c $community $ip .1.3.6.1.4.1.9.9.92.1.1.1.3 |";
  my $cmd_snmp_serial = "$snmpwalk -c $community $ip .1.3.6.1.4.1.9.9.92.1.1.1.2 |";

  eval {
    #--- module model
    open(SW, $cmd_snmp_model) or die "Cannot run snmp command\n";
    while(<SW>) {
      /\.(\d)000 \"(.*)\"$/ && do { $modinfo{$1}{model} = $2;};
    }
    close(SW);
    #--- module serial
    open(SW, $cmd_snmp_serial) or die "Cannot run snmp command\n";
    while(<SW>) {
      /\.(\d)000 \"(.*)\"$/ && do { $modinfo{$1}{sn} = $2;};
    }
    close(SW);
  };
  if($@) {
    chomp($@);
    return 'failed (' . $@ . ')';
  }
  return \%modinfo;
}


1;
