------------------------------------------------------------------------------
-- Table containing information from ENTITY-MIB::entAliasMappingTable
------------------------------------------------------------------------------

CREATE TABLE snmp_entAliasMappingTable (
  host varchar(64),
  entPhysicalIndex int,
  entAliasLogicalIndexOrZero int,
  entAliasMappingIdentifier int,
  creat_when TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  chg_when TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  fresh boolean,
  PRIMARY KEY ( host, entPhysicalIndex, entAliasMappingIdentifier)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON snmp_entAliasMappingTable TO swcoll;
GRANT SELECT ON snmp_entAliasMappingTable TO swcgi;
