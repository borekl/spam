------------------------------------------------------------------------------
-- This table attaches an independent description to modular switches' line
-- cards. This is intended to be used as information on where the remote
-- patchpanel for that linecard is located.
------------------------------------------------------------------------------

DROP TABLE IF EXISTS modwire;

CREATE TABLE modwire (
  host       character varying(16) NOT NULL,  -- switch hostname (lowercase)
  m          smallint              NOT NULL,  -- switch number (0 if not VSS)
  n          smallint              NOT NULL,  -- linecard number
  location   character varying(24),           -- free form description
  PRIMARY KEY (host, n)
);

GRANT SELECT ON modwire TO swcgi;
