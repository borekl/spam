----------------------------------------------------------------------------
-- This function takes Cisco switch port designation and outputs a number
-- that can be used to order ports.
----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION port_order(portname varchar) RETURNS int AS $$

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

$$ LANGUAGE plpgsql;


----------------------------------------------------------------------------
--- Function to format inactivity time; it receives the difference
--- between lastchk and lastchg time as argument and returns formatted
--- string.
----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fmt_inactivity(i interval) RETURNS varchar AS $$

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

$$ LANGUAGE plpgsql;
