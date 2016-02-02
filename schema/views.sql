----------------------------------------------------------------------------
-- This view lists ports of a switch
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_switch;

CREATE OR REPLACE VIEW v_switch AS
  SELECT
    host, portname, status, vlan, descr, duplex, rate, flags,
    cp, outlet, p.chg_who,
    date_trunc('second', p.chg_when)::timestamp AS chg_when,
    adminstatus, errdis,
    extract(epoch from (lastchk - lastchg)) AS inact,
    fmt_inactivity(lastchk - lastchg) AS inact_fmt,
    hostname, grpid, prodstat,
    EXISTS ( 
      SELECT 1 FROM permout WHERE o.site = site AND o.cp = cp 
    ) AS dont_age,
    ( SELECT 
        count(mac) 
      FROM 
        mactable 
      WHERE 
        host = s.host
        AND portname = s.portname 
        AND active = 't'
    ) AS maccnt
  FROM 
    status s
    LEFT JOIN porttable p USING (host, portname)
    LEFT JOIN out2cp o USING (site, cp)
    LEFT JOIN hosttab h USING (site, cp)
  ORDER BY 
    substring(portname from '^[a-zA-Z]+'),
    port_order(portname);

GRANT SELECT ON v_switch TO swcgi;


----------------------------------------------------------------------------
-- This view lists ports of a _modular_ switch. The difference from v_switch
-- is only in sorting.
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_switch_mod;

CREATE OR REPLACE VIEW v_switch_mod AS
  SELECT
    host, portname, status, vlan, descr, duplex, rate, flags,
    cp, outlet, p.chg_who,
    date_trunc('second', p.chg_when)::timestamp AS chg_when,
    adminstatus, errdis,
    extract(epoch from (lastchk - lastchg)) AS inact,
    fmt_inactivity(lastchk - lastchg) AS inact_fmt,
    hostname, grpid, prodstat,
    EXISTS ( 
      SELECT 1 FROM permout WHERE o.site = site AND o.cp = cp 
    ) AS dont_age,
    ( SELECT 
        count(mac) 
      FROM 
        mactable 
      WHERE 
        host = s.host
        AND portname = s.portname 
        AND active = 't'
    ) AS maccnt
  FROM 
    status s
    LEFT JOIN porttable p USING (host, portname)
    LEFT JOIN out2cp o USING (site, cp)
    LEFT JOIN hosttab h USING (site, cp)
  ORDER BY 
    port_order(portname);

GRANT SELECT ON v_switch_mod TO swcgi;


----------------------------------------------------------------------------
-- List of switches with info from swstat table
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_swinfo;

CREATE OR REPLACE VIEW v_swinfo AS
  SELECT
    host, location, ports_total, ports_active, ports_patched,
    ports_illact, ports_errdis, ports_inact, vtp_domain, vtp_mode,
    boot_time,
    regexp_replace(age(current_timestamp, boot_time)::text, ':[^:]*$', '') AS boot_age,
    date_trunc('second', chg_when::timestamp) as chg_when,
    regexp_replace(age(current_timestamp, chg_when)::text, ':[^:]*$', '') AS lastchk_age,
    extract(epoch from date_trunc('second', age(current_timestamp, chg_when))) > 86400 AS stale,
    ports_used, platform
  FROM swstat
  ORDER BY host ASC;

GRANT SELECT ON v_swinfo TO swcgi;


----------------------------------------------------------------------------
-- Search Tool query to be used when only "outcp" is specified. The special
-- feature here is the full join of out2cp and porttable that allows
-- unconnected outlets searching.
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_search_outlet;

CREATE OR REPLACE VIEW v_search_outlet AS
  SELECT
    site, host, portname, cp, outlet, coords, location, vlan, flags,
    duplex, rate, status,
    p.chg_who AS chg_who,
    date_trunc('second', p.chg_when) AS chg_when,
    extract(epoch from (s.lastchk - s.lastchg)) AS inact,
    fmt_inactivity(s.lastchk - s.lastchg) AS inact_fmt,
    mac, ip
  FROM
    out2cp o FULL JOIN porttable p USING ( cp, site ) 
    LEFT JOIN status s USING ( host, portname )
    LEFT JOIN mactable m USING (host, portname )
    LEFT JOIN arptable a USING ( mac );

GRANT SELECT ON v_search_outlet TO swcgi;


----------------------------------------------------------------------------
-- Search Tool query to be used when only switchport/host are specified.
-- The _raw variant is the base query without any search, not to be used
-- directly.
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_search_status_raw;

CREATE OR REPLACE VIEW v_search_status_raw AS
  SELECT
    COALESCE(p.site, substring(host from 1 for 3)) as site,
    host, portname, cp, outlet, descr,
    status, adminstatus, flags, duplex, rate,
    location, vlan, p.chg_who AS chg_who,
    date_trunc('second', p.chg_when) AS chg_when,
    extract(epoch from (lastchk - lastchg)) AS inact,
    fmt_inactivity(lastchk - lastchg) AS inact_fmt
  FROM
    status s 
    LEFT JOIN porttable p USING ( host, portname )
    LEFT JOIN out2cp o USING ( cp, site );

GRANT SELECT ON v_search_status_raw TO swcgi;


----------------------------------------------------------------------------
-- Derivation of previous view with sorting applied for non-modular switches
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_search_status;

CREATE OR REPLACE VIEW v_search_status AS
  SELECT * FROM v_search_status_raw
  ORDER BY 
    host,
    substring(portname from '^[a-zA-Z]+'),
    port_order(portname);

GRANT SELECT ON v_search_status TO swcgi;


----------------------------------------------------------------------------
-- Derivation of previous view with sorting applied for non-modular switches
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_search_status_mod;

CREATE OR REPLACE VIEW v_search_status_mod AS
  SELECT * FROM v_search_status_raw
  ORDER BY
    host, 
    port_order(portname);

GRANT SELECT ON v_search_status_mod TO swcgi;


----------------------------------------------------------------------------
-- Search Tool query to be used when searching by mac only
----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_search_mac;

CREATE OR REPLACE VIEW v_search_mac AS
  SELECT
    site, host, portname, cp, flags, status, duplex, rate, descr,
    extract(epoch from (s.lastchk - s.lastchg)) AS inact,
    fmt_inactivity(s.lastchk - s.lastchg) AS inact_fmt,
    outlet, coords, location, vlan,
    p.chg_who AS chg_who,
    date_trunc('second', p.chg_when) AS chg_when,
    mac, ip
  FROM
    mactable m
    LEFT JOIN arptable a USING ( mac )
    LEFT JOIN status s USING ( host, portname )
    LEFT JOIN porttable p USING ( host, portname )
    LEFT JOIN out2cp o USING ( cp, site );

GRANT SELECT ON v_search_mac TO swcgi;


