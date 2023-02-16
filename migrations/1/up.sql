CREATE TABLE porttable (
  host      varchar(16) NOT NULL,
  portname  varchar(24) NOT NULL,
  cp        varchar(16) NOT NULL,
  site      varchar(3)  NOT NULL,
  chg_who   varchar(16),
  chg_where inet,
  chg_when  timestamp with time zone DEFAULT ('now'::text)::timestamp without time zone,
  PRIMARY KEY (host, portname)
);

CREATE INDEX "porttable_cp_idx" ON porttable  (cp, site);
CREATE INDEX "porttable_cpp_idx" ON porttable (cp);
CREATE INDEX "porttable_scp_idx" ON porttable (site, cp);
CREATE INDEX "porttable_site" ON porttable (site);
GRANT SELECT ON porttable TO PUBLIC;
GRANT INSERT, UPDATE, DELETE ON porttable TO swcgi;

-- -----------------------------------------------------------------------------

CREATE TABLE status (
 host        varchar(16)               NOT NULL,
 portname    varchar(24)               NOT NULL,
 status      boolean                   NOT NULL,
 inpkts      bigint                    NOT NULL,
 outpkts     bigint                    NOT NULL,
 lastchg     timestamp with time zone  NOT NULL,
 lastchk     timestamp with time zone  NOT NULL,
 ifindex     bigint                    NOT NULL,
 vlan        smallint,
 descr       varchar(256),
 duplex      smallint,
 rate        bigint,
 flags       smallint,
 adminstatus boolean,
 errdis      boolean,
 vlans       bit(4096),
 PRIMARY KEY (host, portname)
);

GRANT SELECT ON status TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE arptable2 (
  source  varchar(64) NOT NULL,
  mac     macaddr,
  ip      inet NOT NULL,
  lastchk timestamp with time zone default now(),
  dnsname varchar(64),
  PRIMARY KEY (source, ip)
);

CREATE INDEX "arp_mac" ON arptable2 (mac);
GRANT SELECT ON arptable2 TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE prodstat (
  prodstat_i int,
  descr      character varying(32),
  wtime      smallint,
  PRIMARY KEY (prodstat_i)
);

INSERT INTO prodstat VALUES ( 1, 'Production', 4);
INSERT INTO prodstat VALUES ( 2, 'Development', 24);
INSERT INTO prodstat VALUES ( 3, 'Testing', 168);
INSERT INTO prodstat VALUES (99, 'Unknown', 0);
GRANT SELECT ON prodstat TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE hosttab (
  site       varchar(3)  NOT NULL,
  cp         varchar(10) NOT NULL,
  hostname   varchar(16),
  grpid      varchar(16),
  prodstat   int REFERENCES prodstat(prodstat_i),
  creat_who  varchar(8),
  creat_when timestamp without time zone  default ('now'::text)::timestamp(6) with time zone,
  chg_who    varchar(8),
  chg_when   timestamp without time zone  default ('now'::text)::timestamp(6) with time zone,
  PRIMARY KEY (site, cp)
);

GRANT SELECT ON hosttab TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE mactable (
  mac      macaddr NOT NULL,
  host     varchar(16) NOT NULL,
  portname varchar(24) NOT NULL,
  lastchk  timestamp with time zone  NOT NULL,
  active   boolean,
  PRIMARY KEY (mac)
);

CREATE INDEX "mactable_hp_idx" ON mactable (host, portname);
GRANT SELECT ON mactable TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE modwire (
  host      varchar(16) NOT NULL,
  m         int NOT NULL,
  n         int NOT NULL,
  location  varchar(24),
  chg_who   varchar(16),
  chg_where inet,
  chg_when  timestamp with time zone default now(),
  PRIMARY KEY (host, n)
);

GRANT SELECT ON modwire TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE out2cp (
  site     varchar(3)  NOT NULL,
  cp       varchar(10) NOT NULL,
  outlet   varchar(10) NOT NULL,
  location varchar(32),
  dont_age boolean default FALSE,
  fault    boolean default FALSE,
  coords   varchar(4),
  PRIMARY KEY (site, cp)
);

CREATE UNIQUE INDEX "myo2c" ON out2cp (site, cp, outlet);
CREATE UNIQUE INDEX "o2c_outlet" ON out2cp (site, outlet);
CREATE INDEX "o2c_cp" ON out2cp (cp);
CREATE INDEX "o2c_site" ON out2cp (site);
GRANT SELECT ON out2cp TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE swstat (
  host          varchar(16) NOT NULL,
  location      varchar(256),
  ports_total   int,
  ports_active  int,
  ports_patched int,
  ports_illact  int,
  ports_errdis  int,
  ports_inact   int,
  chg_when      timestamp with time zone DEFAULT ('now'::text)::timestamp without time zone,
  vtp_domain    varchar(16),
  vtp_mode      int,
  boot_time     timestamp without time zone,
  ports_used    int,
  platform      varchar(32),
  PRIMARY KEY (host)
);

GRANT SELECT ON swstat TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE permout (
  site       varchar(3) NOT NULL,
  cp         varchar(10) NOT NULL,
  valfrom    timestamp without time zone NOT NULL default now(),
  valuntil   timestamp without time zone,
  owner      varchar(32) NOT NULL,
  descr      varchar(64),
  creat_who  varchar(8),
  creat_when timestamp without time zone default now(),
  chg_who    varchar(8),
  chg_when   timestamp without time zone,
  PRIMARY KEY (site, cp),
  FOREIGN KEY (site, cp) REFERENCES out2cp(site, cp) ON DELETE CASCADE
);

GRANT SELECT ON permout TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE snmp_cafsessiontable (
  host                    varchar(64)    NOT NULL,
  ifindex                 integer        NOT NULL,
  cafsessionid            varchar(32)    NOT NULL,
  cafsessionclientaddress inet,
  cafsessionauthusername  varchar(64),
  cafsessionauthvlan      integer,
  cafsessionvlangroupname varchar(32),
  creat_when              timestamp with time zone default now(),
  chg_when                timestamp with time zone default now(),
  fresh                   boolean,
  PRIMARY KEY (host, ifindex, cafsessionid)
);

GRANT SELECT ON snmp_cafsessiontable TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE snmp_cdpcachetable (
  host                varchar(64) NOT NULL,
  cdpcacheifindex     integer NOT NULL,
  cdpcachedeviceindex integer NOT NULL,
  cdpcacheplatform    varchar(64),
  cdpcachedeviceid    varchar(64),
  cdpcachesysname     varchar(64),
  creat_when          timestamp with time zone default now(),
  chg_when            timestamp with time zone default now(),
  cdpcachedeviceport  varchar(64),
  fresh               boolean,
  PRIMARY KEY (host, cdpcacheifindex, cdpcachedeviceindex)
);

GRANT SELECT ON snmp_cdpcachetable TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE snmp_entaliasmappingtable (
  host                       varchar(64) NOT NULL,
  entphysicalindex           integer NOT NULL,
  entaliaslogicalindexorzero integer,
  entaliasmappingidentifier  integer NOT NULL,
  creat_when                 timestamp with time zone default now(),
  chg_when                   timestamp with time zone default now(),
  fresh                      boolean,
  PRIMARY KEY (host, entphysicalindex, entaliasmappingidentifier)
);

GRANT SELECT ON snmp_entaliasmappingtable TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE TABLE snmp_entphysicaltable (
  host                    varchar(64) NOT NULL,
  entphysicalindex        integer NOT NULL,
  entphysicaldescr        varchar(256),
  entphysicalcontainedin  integer,
  entphysicalclass        varchar(32),
  entphysicalparentrelpos integer,
  entphysicalname         varchar(256),
  entphysicalhardwarerev  varchar(256),
  entphysicalfirmwarerev  varchar(256),
  entphysicalsoftwarerev  varchar(256),
  entphysicalserialnum    varchar(256),
  entphysicalmodelname    varchar(256),
  creat_when              timestamp with time zone default now(),
  chg_when                timestamp with time zone default now(),
  fresh                   boolean,
 PRIMARY KEY (host, entphysicalindex)
);

GRANT SELECT ON snmp_entphysicaltable TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE FUNCTION fmt_inactivity(i interval) RETURNS character varying
LANGUAGE plpgsql AS $function$

DECLARE
  yr int;
  dy int;
  hr int;
  mi int;
  re varchar = '';

BEGIN

  -- decompose the interval into years/days/hours/minutes

  dy := extract(day from i);
  IF dy <> 0 THEN
    i := i - interval '1 day' * dy;
  END IF;

  yr := dy / 365;
  dy := dy % 365;

  hr := extract(hour from i);
  IF hr <> 0 THEN
    i := i - interval '1 hour' * hr;
  END IF;
  mi := extract(minute from i);

  -- RAISE NOTICE 'y:% d:% h:% m:%', yr, dy, hr, mi;

  -- adaptive formatting

  IF yr > 0 THEN
    re := yr || 'y';
  END IF;

  IF dy > 0 AND yr <= 1 THEN
    re := re || dy || 'd';
  END IF;

  IF hr > 0 AND dy <= 7 AND yr = 0 THEN
    re := re || hr || 'h';
  END IF;

  IF mi > 0 AND dy = 0 AND hr <= 1 AND yr = 0 THEN
    re := re || mi || 'm';
  END IF;

  IF re = '' THEN
    re := NULL;
  END IF;

  --- finish

  RETURN re;

END;

$function$;

-- -----------------------------------------------------------------------------

CREATE FUNCTION port_order(portname varchar) RETURNS integer
LANGUAGE plpgsql AS $function$

DECLARE
  result int := 0;
  mu int;
  pa int[];
  x int;

BEGIN

   pa = regexp_split_to_array(substring(portname, '\d.*$'), '/');

   mu := 100 ^ (array_length(pa, 1) - 1);
   FOREACH x IN ARRAY pa
   LOOP
     result := result + (x * mu);
     mu := mu / 100;
   END LOOP;

   RETURN result;

END;

$function$;

-- -----------------------------------------------------------------------------

CREATE VIEW v_search_status_raw AS
  SELECT
    COALESCE(p.site, "substring"(s.host::text, 1, 3)::character varying) AS site,
    s.host,
    s.portname,
    cp,
    o.outlet,
    s.descr,
    s.status,
    s.adminstatus,
    s.flags,
    s.duplex,
    s.rate,
    s.ifindex,
    o.location,
    s.vlan,
    s.vlans,
    p.chg_who,
    to_char(p.chg_when, 'FMHH24:MI, FMMonth FMDD, YYYY'::text) AS chg_when,
    fmt_inactivity(now() - p.chg_when) AS chg_age_fmt,
    date_part('epoch'::text, s.lastchk - s.lastchg)::integer AS inact,
    fmt_inactivity(s.lastchk - s.lastchg) AS inact_fmt,
    to_char(s.lastchg, 'FMHH24:MI, FMMonth FMDD, YYYY'::text) AS inact_date,
    date_part('epoch'::text, now() - s.lastchk)::integer AS lastchk_age,
    fmt_inactivity(now() - s.lastchk) AS lastchk_age_fmt,
    to_char(s.lastchk, 'FMHH24:MI, FMMonth FMDD, YYYY'::text) AS lastchk_date
    FROM status s
      LEFT JOIN porttable p USING (host, portname)
      LEFT JOIN out2cp o USING (cp, site);

GRANT SELECT ON v_search_status_raw TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_search_status_full AS
  SELECT
    v.site,
    v.host,
    v.portname,
    v.cp,
    v.outlet,
    v.descr,
    v.status,
    v.adminstatus,
    v.flags,
    v.duplex,
    v.rate,
    v.ifindex,
    v.location,
    v.vlan,
    v.vlans,
    v.chg_who,
    v.chg_when,
    v.chg_age_fmt,
    v.inact,
    v.inact_fmt,
    v.inact_date,
    v.lastchk_age,
    v.lastchk_age_fmt,
    v.lastchk_date,
    m.mac,
    date_part('epoch'::text, now() - m.lastchk)::integer AS mac_age,
    fmt_inactivity(now() - m.lastchk) AS mac_age_fmt,
    a.ip,
    date_part('epoch'::text, now() - a.lastchk)::integer AS ip_age,
    fmt_inactivity(now() - a.lastchk) AS ip_age_fmt
  FROM v_search_status_raw v
    LEFT JOIN mactable m USING (host, portname)
    LEFT JOIN arptable2 a USING (mac);

GRANT SELECT ON v_search_status_full TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_search_status_mod AS
  SELECT
    v_search_status_full.site,
    v_search_status_full.host,
    v_search_status_full.portname,
    v_search_status_full.cp,
    v_search_status_full.outlet,
    v_search_status_full.descr,
    v_search_status_full.status,
    v_search_status_full.adminstatus,
    v_search_status_full.flags,
    v_search_status_full.duplex,
    v_search_status_full.rate,
    v_search_status_full.ifindex,
    v_search_status_full.location,
    v_search_status_full.vlan,
    v_search_status_full.vlans,
    v_search_status_full.chg_who,
    v_search_status_full.chg_when,
    v_search_status_full.chg_age_fmt,
    v_search_status_full.inact,
    v_search_status_full.inact_fmt,
    v_search_status_full.inact_date,
    v_search_status_full.lastchk_age,
    v_search_status_full.lastchk_age_fmt,
    v_search_status_full.lastchk_date,
    v_search_status_full.mac,
    v_search_status_full.mac_age,
    v_search_status_full.mac_age_fmt,
    v_search_status_full.ip,
    v_search_status_full.ip_age,
    v_search_status_full.ip_age_fmt
  FROM v_search_status_full
  ORDER BY v_search_status_full.host, (port_order(v_search_status_full.portname));

GRANT SELECT ON v_search_status_mod TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_search_status AS
  SELECT
    v_search_status_full.site,
    v_search_status_full.host,
    v_search_status_full.portname,
    v_search_status_full.cp,
    v_search_status_full.outlet,
    v_search_status_full.descr,
    v_search_status_full.status,
    v_search_status_full.adminstatus,
    v_search_status_full.flags,
    v_search_status_full.duplex,
    v_search_status_full.rate,
    v_search_status_full.ifindex,
    v_search_status_full.location,
    v_search_status_full.vlan,
    v_search_status_full.vlans,
    v_search_status_full.chg_who,
    v_search_status_full.chg_when,
    v_search_status_full.chg_age_fmt,
    v_search_status_full.inact,
    v_search_status_full.inact_fmt,
    v_search_status_full.inact_date,
    v_search_status_full.lastchk_age,
    v_search_status_full.lastchk_age_fmt,
    v_search_status_full.lastchk_date,
    v_search_status_full.mac,
    v_search_status_full.mac_age,
    v_search_status_full.mac_age_fmt,
    v_search_status_full.ip,
    v_search_status_full.ip_age,
    v_search_status_full.ip_age_fmt
  FROM v_search_status_full
  ORDER BY v_search_status_full.host, ("substring"(v_search_status_full.portname::text, '^[a-zA-Z]+'::text)), (port_order(v_search_status_full.portname));

GRANT SELECT ON v_search_status TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_search_outlet AS
  SELECT
    site,
    p.host,
    p.portname,
    cp,
    o.outlet,
    o.coords,
    o.location,
    s.vlan,
    s.flags,
    s.duplex,
    s.rate,
    s.status,
    p.chg_who,
    date_trunc('second'::text, p.chg_when) AS chg_when,
    date_part('epoch'::text, s.lastchk - s.lastchg) AS inact,
    fmt_inactivity(s.lastchk - s.lastchg) AS inact_fmt,
    m.mac,
    a.ip
  FROM out2cp o
    FULL JOIN porttable p USING (cp, site)
    LEFT JOIN status s USING (host, portname)
    LEFT JOIN mactable m USING (host, portname)
    LEFT JOIN arptable2 a USING (mac);

GRANT SELECT ON v_search_outlet TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_search_mac AS
  SELECT p.site,
    m.host,
    m.portname,
    cp,
    s.flags,
    s.status,
    s.duplex,
    s.rate,
    s.descr,
    date_part('epoch'::text, s.lastchk - s.lastchg) AS inact,
    fmt_inactivity(s.lastchk - s.lastchg) AS inact_fmt,
    o.outlet,
    o.coords,
    o.location,
    s.vlan,
    p.chg_who,
    date_trunc('second'::text, p.chg_when) AS chg_when,
    m.mac,
    a.ip
  FROM mactable m
    LEFT JOIN arptable2 a USING (mac)
    LEFT JOIN status s USING (host, portname)
    LEFT JOIN porttable p USING (host, portname)
    LEFT JOIN out2cp o USING (cp, site);

GRANT SELECT ON v_search_mac TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_search_user AS
  SELECT
    s.site,
    s.host,
    s.portname,
    s.cp,
    s.outlet,
    s.descr,
    s.status,
    s.adminstatus,
    s.flags,
    s.duplex,
    s.rate,
    s.ifindex,
    s.location,
    s.vlan,
    s.vlans,
    s.chg_who,
    s.chg_when,
    s.chg_age_fmt,
    s.inact,
    s.inact_fmt,
    s.inact_date,
    s.lastchk_age,
    s.lastchk_age_fmt,
    s.lastchk_date,
    cst.cafsessionauthusername,
    cst.chg_when AS cst_chg_when,
    fmt_inactivity(now() - cst.chg_when) AS cst_chg_age
  FROM v_search_status_raw s
    LEFT JOIN snmp_cafsessiontable cst USING (host, ifindex)
  ORDER BY s.host, cst.cafsessionauthusername, cst.chg_when DESC;

GRANT SELECT ON v_search_user TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_port_list AS
  SELECT
    v.site,
    v.host,
    v.portname,
    v.cp,
    v.outlet,
    v.descr,
    v.status,
    v.adminstatus,
    v.flags,
    v.duplex,
    v.rate,
    v.ifindex,
    v.location,
    v.vlan,
    v.vlans,
    v.chg_who,
    v.chg_when,
    v.chg_age_fmt,
    v.inact,
    v.inact_fmt,
    v.inact_date,
    v.lastchk_age,
    v.lastchk_age_fmt,
    v.lastchk_date,
    cst.cafsessionauthvlan,
    cst.fresh,
    (
      SELECT count(mactable.mac) AS count FROM mactable
      WHERE
        v.host::text = mactable.host::text
        AND v.portname::text = mactable.portname::text
        AND mactable.active = true
    ) AS maccnt
    FROM v_search_status_raw v
    LEFT JOIN snmp_cafsessiontable cst USING (host, ifindex)
    ORDER BY
      v.host, ("substring"(v.portname::text, '^[a-zA-Z]+'::text)),
      (port_order(v.portname)),
      cst.chg_when DESC;

GRANT SELECT ON v_port_list TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_port_list_mod AS
  SELECT v.site,
    v.host,
    v.portname,
    v.cp,
    v.outlet,
    v.descr,
    v.status,
    v.adminstatus,
    v.flags,
    v.duplex,
    v.rate,
    v.ifindex,
    v.location,
    v.vlan,
    v.vlans,
    v.chg_who,
    v.chg_when,
    v.chg_age_fmt,
    v.inact,
    v.inact_fmt,
    v.inact_date,
    v.lastchk_age,
    v.lastchk_age_fmt,
    v.lastchk_date,
    cst.cafsessionauthvlan,
    cst.fresh,
    (
      SELECT count(mactable.mac) AS count FROM mactable
      WHERE
        v.host::text = mactable.host::text
        AND v.portname::text = mactable.portname::text
        AND mactable.active = true
    ) AS maccnt
    FROM v_search_status_raw v
    LEFT JOIN snmp_cafsessiontable cst USING (host, ifindex)
    ORDER BY v.host, (port_order(v.portname)), cst.chg_when DESC;

GRANT SELECT ON v_port_list_mod TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_portinfo AS
  SELECT
    v_search_status_full.site,
    v_search_status_full.host,
    v_search_status_full.portname,
    v_search_status_full.cp,
    v_search_status_full.outlet,
    v_search_status_full.descr,
    v_search_status_full.status,
    v_search_status_full.adminstatus,
    v_search_status_full.flags,
    v_search_status_full.duplex,
    v_search_status_full.rate,
    v_search_status_full.ifindex,
    v_search_status_full.location,
    v_search_status_full.vlan,
    v_search_status_full.vlans,
    v_search_status_full.chg_who,
    v_search_status_full.chg_when,
    v_search_status_full.chg_age_fmt,
    v_search_status_full.inact,
    v_search_status_full.inact_fmt,
    v_search_status_full.inact_date,
    v_search_status_full.lastchk_age,
    v_search_status_full.lastchk_age_fmt,
    v_search_status_full.lastchk_date,
    v_search_status_full.mac,
    v_search_status_full.mac_age,
    v_search_status_full.mac_age_fmt,
    v_search_status_full.ip,
    v_search_status_full.ip_age,
    v_search_status_full.ip_age_fmt
  FROM v_search_status_full
  ORDER BY v_search_status_full.mac_age;

GRANT SELECT ON v_portinfo TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_swinfo AS
  SELECT swstat.host,
    swstat.location,
    swstat.ports_total,
    swstat.ports_active,
    swstat.ports_patched,
    swstat.ports_illact,
    swstat.ports_errdis,
    swstat.ports_inact,
    swstat.vtp_domain,
    swstat.vtp_mode,
    swstat.boot_time,
    regexp_replace(age(now(), swstat.boot_time::timestamp with time zone)::text, ':[^:]*$'::text, ''::text) AS boot_age,
    date_trunc('second'::text, swstat.chg_when::timestamp without time zone) AS chg_when,
    regexp_replace(age(now(), swstat.chg_when)::text, ':[^:]*$'::text, ''::text) AS lastchk_age,
    date_part('epoch'::text, date_trunc('second'::text, age(now(), swstat.chg_when))) > 86400::double precision AS stale,
    swstat.ports_used,
    swstat.platform
  FROM swstat
  ORDER BY swstat.host;

GRANT SELECT ON v_swinfo TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_switch AS
  SELECT
    s.host,
    s.portname,
    s.status,
    s.vlan,
    s.descr,
    s.duplex,
    s.rate,
    s.flags,
    cp,
    o.outlet,
    p.chg_who,
    date_trunc('second'::text, p.chg_when)::timestamp without time zone AS chg_when,
    s.adminstatus,
    s.errdis,
    date_part('epoch'::text, s.lastchk - s.lastchg) AS inact,
    fmt_inactivity(s.lastchk - s.lastchg) AS inact_fmt,
    h.hostname,
    h.grpid,
    h.prodstat,
    (EXISTS ( SELECT 1
          FROM permout
          WHERE o.site::text = permout.site::text AND o.cp::text = permout.cp::text)) AS dont_age,
    ( SELECT count(mactable.mac) AS count
      FROM mactable
      WHERE mactable.host::text = s.host::text AND mactable.portname::text = s.portname::text AND mactable.active = true) AS maccnt
  FROM status s
    LEFT JOIN porttable p USING (host, portname)
    LEFT JOIN out2cp o USING (site, cp)
    LEFT JOIN hosttab h USING (site, cp)
  ORDER BY ("substring"(s.portname::text, '^[a-zA-Z]+'::text)), (port_order(s.portname));

GRANT SELECT ON v_switch TO PUBLIC;

-- -----------------------------------------------------------------------------

CREATE VIEW v_switch_mod AS
 SELECT s.host,
    s.portname,
    s.status,
    s.vlan,
    s.descr,
    s.duplex,
    s.rate,
    s.flags,
    cp,
    o.outlet,
    p.chg_who,
    date_trunc('second'::text, p.chg_when)::timestamp without time zone AS chg_when,
    s.adminstatus,
    s.errdis,
    date_part('epoch'::text, s.lastchk - s.lastchg) AS inact,
    fmt_inactivity(s.lastchk - s.lastchg) AS inact_fmt,
    h.hostname,
    h.grpid,
    h.prodstat,
    (EXISTS ( SELECT 1
           FROM permout
          WHERE o.site::text = permout.site::text AND o.cp::text = permout.cp::text)) AS dont_age,
    ( SELECT count(mactable.mac) AS count
           FROM mactable
          WHERE mactable.host::text = s.host::text AND mactable.portname::text = s.portname::text AND mactable.active = true) AS maccnt
   FROM status s
     LEFT JOIN porttable p USING (host, portname)
     LEFT JOIN out2cp o USING (site, cp)
     LEFT JOIN hosttab h USING (site, cp)
  ORDER BY (port_order(s.portname));

GRANT SELECT ON v_switch_mod TO PUBLIC;
