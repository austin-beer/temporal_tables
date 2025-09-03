-- version 1.2.0

CREATE OR REPLACE FUNCTION versioning()
RETURNS TRIGGER AS $$
DECLARE
  sys_period text;
  history_table text;
  manipulate jsonb;
  version_column_name text;
  commonColumns text[];
  time_stamp_to_use timestamptz;
  range_lower timestamptz;
  existing_range tstzrange;
  existing_version integer;
  newVersion record;
  oldVersion record;
  record_exists bool;
BEGIN
  history_table := TG_ARGV[0];
  sys_period := 'timeValid';
  version_column_name := 'version';
  time_stamp_to_use := CURRENT_TIMESTAMP;

  -- ignore unchanged values
  IF TG_OP = 'UPDATE' THEN
    IF NEW IS NOT DISTINCT FROM OLD THEN
      RETURN OLD;
    END IF;
  END IF;

  IF TG_OP = 'INSERT' THEN
    existing_version := 0;
  END IF;

  IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
    -- Ignore rows already modified in the current transaction
    IF OLD.xmin::text = (txid_current() % (2^32)::bigint)::text THEN
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END IF;

    EXECUTE format('SELECT $1.%I', sys_period) USING OLD INTO existing_range;

    range_lower := lower(existing_range);

    -- mitigate update conflicts
    IF range_lower >= time_stamp_to_use THEN
      time_stamp_to_use := range_lower + interval '1 microseconds';
    END IF;

    EXECUTE format('SELECT $1.%I', version_column_name) USING OLD INTO existing_version;

    WITH history AS
      (SELECT attname
      FROM   pg_attribute
      WHERE  attrelid = history_table::regclass
      AND    attnum > 0
      AND    NOT attisdropped),
      main AS
      (SELECT attname
      FROM   pg_attribute
      WHERE  attrelid = TG_RELID
      AND    attnum > 0
      AND    NOT attisdropped)
    SELECT array_agg(quote_ident(history.attname)) INTO commonColumns
      FROM history
      INNER JOIN main
      ON history.attname = main.attname
      AND history.attname != sys_period
      AND history.attname != version_column_name;

    -- skip version if it would be identical to the previous version
    IF TG_OP = 'UPDATE' THEN
      EXECUTE 'SELECT ROW($1.' || array_to_string(commonColumns , ', $1.') || ')'
        USING NEW
        INTO newVersion;
      EXECUTE 'SELECT ROW($1.' || array_to_string(commonColumns , ', $1.') || ')'
        USING OLD
        INTO oldVersion;
      IF newVersion IS NOT DISTINCT FROM oldVersion THEN
        RETURN NEW;
      END IF;
    END IF;

    EXECUTE ('INSERT INTO ' ||
    history_table ||
    '(' ||
    array_to_string(commonColumns , ',') ||
    ',' ||
    quote_ident(sys_period) ||
    ',' ||
    quote_ident(version_column_name) ||
    ') VALUES ($1.' ||
    array_to_string(commonColumns, ',$1.') ||
    ',tstzrange($2, $3, ''[)''), $4)')
      USING OLD, range_lower, time_stamp_to_use, existing_version;
  END IF;

  IF TG_OP = 'UPDATE' OR TG_OP = 'INSERT' THEN
    manipulate := jsonb_set('{}'::jsonb, ('{' || sys_period || '}')::text[], to_jsonb(tstzrange(time_stamp_to_use, null, '[)')));

    manipulate := jsonb_set(manipulate, ('{' || version_column_name || '}')::text[], to_jsonb(existing_version + 1));

    RETURN jsonb_populate_record(NEW, manipulate);
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;
