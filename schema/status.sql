----------------------------------------------------------------------------
-- This contains the basic switchport data retrieved by SPAM collector.
----------------------------------------------------------------------------

CREATE TABLE status (
  host        character varying(16)    NOT NULL,
  portname    character varying(24)    NOT NULL,
  status      boolean                  NOT NULL,
  inpkts      bigint                   NOT NULL,
  outpkts     bigint                   NOT NULL,
  lastchg     timestamp with time zone NOT NULL,
  lastchk     timestamp with time zone NOT NULL,
  ifindex     bigint                   NOT NULL,
  vlan        smallint,
  vlans       bit(4096),
  descr       character varying(64),
  duplex      smallint,
  rate        bigint,
  flags       smallint,
  adminstatus boolean,
  errdis      boolean,
  PRIMARY KEY (host, portname)
);
