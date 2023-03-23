DROP VIEW v_switch_mod;
DROP VIEW v_switch;
DROP VIEW v_swinfo;
DROP VIEW v_portinfo;
DROP VIEW v_port_list_mod;
DROP VIEW v_port_list;
DROP VIEW v_search_user;
DROP VIEW v_search_mac;
DROP VIEW v_search_outlet;
DROP VIEW v_search_status;
DROP VIEW v_search_status_mod;
DROP VIEW v_search_status_full;
DROP VIEW v_search_status_raw;

--

ALTER TABLE hosttab ALTER COLUMN site TYPE varchar(16);
ALTER TABLE porttable ALTER COLUMN site TYPE varchar(16);
ALTER TABLE out2cp ALTER COLUMN site TYPE varchar(16);
ALTER TABLE permout ALTER COLUMN site TYPE varchar(16);

--

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
