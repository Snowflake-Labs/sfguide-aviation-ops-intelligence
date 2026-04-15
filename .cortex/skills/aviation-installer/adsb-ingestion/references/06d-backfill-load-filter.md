# Historical Backfill Infrastructure

> **Placeholders** (replaced by the skill at generation time):
> - `{TARGET_DB}` — Snowflake database, e.g. `AIRPORT_SAN`
> - `{SCHEMA}` — Schema, e.g. `PUBLIC`
> - `{WAREHOUSE}` — Warehouse name
> - `{EAI_ADSB_LOL}` — External Access Integration name for adsb.lol (e.g. `AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI`)
> - `{EAI_GITHUB}` — External Access Integration name for GitHub (e.g. `AIRPORT_SAN_PUBLIC_GITHUB_EAI`)
> - `{API_URL}` — adsb.lol API endpoint with lat/lon/radius (e.g. `https://api.adsb.lol/v2/point/32.7336/-117.1897/27`)
> - `{BACKFILL_DAYS}` — Number of historical days to backfill (e.g. `7`)
> - `{IATA}` — Airport IATA code (e.g. `SAN`)

The **COMMENT tag** used on every `CREATE` statement:
```
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
```


---

### PROC_LOAD_NDJSON_TO_INTERIM

```sql
-- =============================================================================
-- Procedure: Load individual JSON files to interim table
-- Uses COPY INTO with COMPRESSION=AUTO - Snowflake handles gzip decompression
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_LOAD_NDJSON_TO_INTERIM(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'load_json_files'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
def load_json_files(session, p_date):
    '''Load batched NDJSON (.ndjson.gz) files using COPY INTO.
    
    Snowflake handles gzip decompression and JSON parsing; each NDJSON line becomes one VARIANT row.
    '''
    # Clear any existing data for this date
    session.sql(f"DELETE FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = '{p_date}'").collect()
    
    stage_dir = f"@{TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE/{p_date}/ndjson/"

    try:
        listed = session.sql(f"LIST {stage_dir} PATTERN='.*\\.ndjson\\.gz'").collect()
    except Exception as e:
        return f"Error listing ndjson batches: {str(e)[:200]}"

    if not listed:
        msg = f"No NDJSON batch files found under {stage_dir}"
        try:
            session.sql(f'''
                UPDATE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
                SET download_status = 'load_failed',
                    error_message = '{msg[:200]}'
                WHERE data_date = '{p_date}'
            ''').collect()
        except Exception:
            pass
        return msg
    
    try:
        copy_sql = f'''
            COPY INTO {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM (data_date, raw_json, loaded_at)
            FROM (
                SELECT 
                    '{p_date}'::DATE,
                    $1,
                    CURRENT_TIMESTAMP()
                FROM {stage_dir}
            )
            FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP)
            PATTERN = '.*\\.ndjson\\.gz'
            ON_ERROR = CONTINUE
        '''
        session.sql(copy_sql).collect()

        rows_loaded = session.sql(
            f"SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = '{p_date}'::DATE"
        ).collect()[0][0]

        try:
            session.sql(f'''
                UPDATE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
                SET loaded_at = CURRENT_TIMESTAMP(),
                    rows_loaded = {rows_loaded},
                    download_status = IFF(download_status = 'extracted', 'loaded', download_status)
                WHERE data_date = '{p_date}'
            ''').collect()
        except Exception:
            pass

        return f"Loaded {rows_loaded} aircraft to interim table from NDJSON batches"
    except Exception as e:
        try:
            session.sql(f'''
                UPDATE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
                SET download_status = 'load_failed',
                    error_message = '{str(e)[:200]}'
                WHERE data_date = '{p_date}'
            ''').collect()
        except Exception:
            pass
        return f"Error loading JSON files: {str(e)[:200]}"
$$;
```

### PROC_FILTER_AND_INSERT_SQL

```sql
-- =============================================================================
-- Procedure: Filter and insert using SQL ST_DWITHIN (parallel processing)
-- This is where the magic happens - Snowflake parallelizes the filtering
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_FILTER_AND_INSERT_SQL(p_date VARCHAR)
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
DECLARE
    v_aircraft_count INT;
    v_points_inserted INT;
BEGIN
    -- Count aircraft in interim
    SELECT COUNT(*) INTO v_aircraft_count FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = :p_date::DATE;

    -- Restart-safe processing: remove any previously inserted points for this day (user-approved).
    DELETE FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW
    WHERE timestamp::DATE = :p_date::DATE;
    
    -- Insert filtered points using ST_DWITHIN (50km = 50000 meters)
    -- This runs in parallel across all Snowflake workers
    INSERT INTO {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW (
        hex, flight, registration, aircraft_type, aircraft_desc,
        lat, lon, alt_baro, alt_geom,
        ground_speed, track, true_heading, vertical_rate,
        squawk, category, timestamp, ingested_at
    )
    WITH airport AS (
        SELECT geometry FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT LIMIT 1
    )
    SELECT 
        UPPER(i.raw_json:icao::VARCHAR) AS hex,
        -- Historical ADSB.lol "trace_full" files often do NOT have a top-level "flight".
        -- Instead, callsign/flight appears inside the per-point metadata object within the trace array
        -- (commonly at pt.value[8]:flight). Use that, and propagate within the aircraft stream.
        COALESCE(
            NULLIF(UPPER(TRIM(i.raw_json:flight::VARCHAR)), ''),
            NULLIF(UPPER(TRIM(pt.value[8]:flight::VARCHAR)), ''),
            NULLIF(
                MAX(NULLIF(UPPER(TRIM(pt.value[8]:flight::VARCHAR)), ''))
                  OVER (PARTITION BY UPPER(i.raw_json:icao::VARCHAR)),
                ''
            )
        ) AS flight,
        UPPER(TRIM(i.raw_json:r::VARCHAR)) AS registration,
        i.raw_json:t::VARCHAR AS aircraft_type,
        -- Historical schema: aircraft description is top-level "desc"
        -- Use quoted key access for robustness and normalize blanks to NULL.
        NULLIF(TRIM(COALESCE(
            i.raw_json:"desc"::VARCHAR,
            i.raw_json:desc::VARCHAR
        )), '') AS aircraft_desc,
        pt.value[1]::FLOAT AS lat,
        pt.value[2]::FLOAT AS lon,
        CASE 
            WHEN pt.value[3]::VARCHAR = 'ground' OR pt.value[3] IS NULL THEN 0
            ELSE TRY_CAST(pt.value[3]::VARCHAR AS INT)
        END AS alt_baro,
        TRY_CAST(pt.value[8]:alt_geom::VARCHAR AS INT) AS alt_geom,
        pt.value[4]::FLOAT AS ground_speed,
        COALESCE(
            TRY_CAST(pt.value[8]:track::VARCHAR AS FLOAT),
            pt.value[5]::FLOAT
        ) AS track,
        COALESCE(
            TRY_CAST(pt.value[8]:true_heading::VARCHAR AS FLOAT),
            pt.value[8]:true_heading::FLOAT
        ) AS true_heading,
        COALESCE(
            TRY_CAST(pt.value[8]:baro_rate::VARCHAR AS INT),
            TRY_CAST(pt.value[8]:geom_rate::VARCHAR AS INT),
            TRY_CAST(pt.value[7]::VARCHAR AS INT)
        ) AS vertical_rate,
        COALESCE(
            NULLIF(UPPER(TRIM(pt.value[8]:squawk::VARCHAR)), ''),
            NULLIF(
                MAX(NULLIF(UPPER(TRIM(pt.value[8]:squawk::VARCHAR)), ''))
                  OVER (PARTITION BY UPPER(i.raw_json:icao::VARCHAR)),
                ''
            )
        ) AS squawk,
        COALESCE(
            NULLIF(UPPER(TRIM(pt.value[8]:category::VARCHAR)), ''),
            NULLIF(
                MAX(NULLIF(UPPER(TRIM(pt.value[8]:category::VARCHAR)), ''))
                  OVER (PARTITION BY UPPER(i.raw_json:icao::VARCHAR)),
                ''
            )
        ) AS category,
        -- pt.value[0] is seconds (often fractional) since raw_json:timestamp epoch
        TIMESTAMPADD(
            'millisecond',
            -- pt.value[0] is VARIANT->FLOAT; ROUND() returns numeric already.
            -- Using TRY_CAST here can fail compilation depending on inferred numeric types, so use a plain CAST.
            CAST(ROUND(COALESCE(pt.value[0]::FLOAT, 0) * 1000) AS INT),
            TO_TIMESTAMP(i.raw_json:timestamp::NUMBER)
        ) AS timestamp,
        CURRENT_TIMESTAMP() AS ingested_at
    FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM i,
         LATERAL FLATTEN(input => i.raw_json:trace) pt,
         airport a
    WHERE i.data_date = :p_date::DATE
      AND i.raw_json:trace IS NOT NULL
      AND ARRAY_SIZE(i.raw_json:trace) > 0
      AND pt.value[1] IS NOT NULL
      AND pt.value[2] IS NOT NULL
      AND ST_DWITHIN(
          ST_MAKEPOINT(pt.value[2]::FLOAT, pt.value[1]::FLOAT),
          a.geometry,
          50000
      );

    -- Exact inserted row count for this run
    v_points_inserted := SQLROWCOUNT;
    
    -- Update status
    UPDATE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS 
    SET download_status = 'processed', 
        processed_at = CURRENT_TIMESTAMP(),
        aircraft_found = :v_aircraft_count,
        points_inserted = :v_points_inserted
    WHERE data_date = :p_date::DATE;
    
    -- Clean up interim table for this date
    DELETE FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM WHERE data_date = :p_date::DATE;
    
    -- Run ETL to silver
    CALL {TARGET_DB}.{SCHEMA}.PROC_ETL_ADSB_TO_DATA();
    
    RETURN 'Filtered ' || v_aircraft_count || ' aircraft, inserted ' || v_points_inserted || ' points within 50km';
END;
$$;
```

