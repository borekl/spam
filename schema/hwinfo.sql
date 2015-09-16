------------------------------------------------------------------------------
-- Table containing information about switch hardware (linecards etc).
------------------------------------------------------------------------------

DROP TABLE hwinfo;

CREATE TABLE hwinfo (
  host       character varying(16)  NOT NULL,
  m          smallint               NOT NULL, -- chassis number or 0
  n          smallint               NOT NULL, -- linecard number
  partnum    varchar(32),
  sn         varchar(32), 
  type       varchar(8), 
  hwrev      varchar(32), 
  fwrev      varchar(32), 
  swrev      varchar(32),
  descr      varchar(64),
  creat_when timestamp without time zone default current_timestamp,
  chg_when   timestamp without time zone,
  PRIMARY KEY ( host, m, n)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON hwinfo TO swcoll;
GRANT SELECT ON hwinfo TO swcgi;
