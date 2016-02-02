------------------------------------------------------------------------------
-- Table to contain some statistical information about switches; mostly
-- useful for displaying list of switches on SPAM's front page
------------------------------------------------------------------------------


DROP TABLE IF EXISTS swstat;

CREATE TABLE swstat (
  host           varchar(16) PRIMARY KEY,
  location       varchar(256),
  ports_total    smallint,
  ports_active   smallint,
  ports_patched  smallint,
  ports_illact   smallint,
  ports_errdis   smallint,
  ports_inact    smallint,
  chg_when       timestamp with time zone 
    DEFAULT ('now'::text)::timestamp without time zone,
  vtp_domain     varchar(16),
  vtp_mode       smallint,
  boot_time      timestamp without time zone,
  ports_used     smallint,
  platform       varchar(16)
);

