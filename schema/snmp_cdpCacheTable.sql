------------------------------------------------------------------------------
-- Table containing information from CISCO-CDP-MIB::cdpCacheTable
------------------------------------------------------------------------------

CREATE TABLE snmp_cdpCacheTable (
  host                 varchar(64),
  cdpCacheIfIndex      int,
  cdpCacheDeviceIndex  int,
  cdpCachePlatform     varchar(64),
  cdpCacheDeviceId     varchar(64),
  cdpcacheSysName      varchar(64),
  creat_when           TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  chg_when             TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ( host, cdpCacheIfIndex, cdpCacheDeviceIndex )
);

GRANT SELECT, INSERT, UPDATE, DELETE ON snmp_cdpCacheTable TO swcoll;
GRANT SELECT ON snmp_cdpCacheTable TO swcgi;
