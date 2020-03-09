------------------------------------------------------------------------------
-- Table containing information from ENTITY-MIB
------------------------------------------------------------------------------

CREATE TABLE snmp_entPhysicalTable (
  host                    varchar(64),
  entPhysicalIndex        int,
  entPhysicalDescr        varchar(256),
  entPhysicalContainedIn  int,
  entPhysicalClass        varchar(32),
  entPhysicalParentRelPos int,
  entPhysicalName         varchar(256),
  entPhysicalHardwareRev  varchar(256),
  entPhysicalFirmwareRev  varchar(256),
  entPhysicalSoftwareRev  varchar(256),
  entPhysicalSerialNum    varchar(256),
  entPhysicalModelName    varchar(256),
  creat_when              TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  chg_when                TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  fresh                   boolean,
  PRIMARY KEY ( host, entPhysicalIndex )
);

GRANT SELECT, INSERT, UPDATE, DELETE ON snmp_entPhysicalTable TO swcoll;
GRANT SELECT ON snmp_entPhysicalTable TO swcgi;
