------------------------------------------------------------------------------
-- Table containing information from CISCO-AUTH-FRAMEWORK-MIB::cdpSesionTable
------------------------------------------------------------------------------

CREATE TABLE snmp_cafSessionTable (
  host                    varchar(64),
  ifIndex                 int,
  cafSessionId            varchar(32),
  cafSessionClientAddress inet,
  cafSessionAuthUserName  varchar(64),
  cafSessionAuthVlan      int,
  cafSessionVlanGroupName varchar(32),
  creat_when              TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  chg_when                TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  fresh                   boolean,
  PRIMARY KEY ( host, ifIndex, cafSessionId )
);

GRANT SELECT, INSERT, UPDATE, DELETE ON snmp_cafSessionTable TO swcoll;
GRANT SELECT ON snmp_cafSessionTable TO swcgi;
