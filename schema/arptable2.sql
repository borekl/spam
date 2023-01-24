-- this table holds ARP tables from routers

CREATE TABLE arptable2 (
  source  character varying(64) NOT NULL,
  mac     macaddr,
  ip      inet NOT NULL,
  lastchk timestamp with time zone DEFAULT current_timestamp,
  dnsname character varying(64),
  PRIMARY KEY (source, ip)
);

CREATE INDEX arp_mac ON arptable2 (mac);

GRANT SELECT, INSERT, UPDATE, DELETE ON arptable2 TO swcoll;
GRANT SELECT ON arptable2 TO swcgi;
