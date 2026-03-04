-- =============================================================================
-- ADS-B INGESTION & ENRICHMENT TASKS
-- Database: ${DATABASE}.${SCHEMA}
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Ingestion Procedure
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_INGEST_ADSB_REALTIME()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'ingest'
EXTERNAL_ACCESS_INTEGRATIONS = (${EAI_ADSB_LOL})
AS
$$
import requests
from datetime import datetime

def ingest(session):
    # API endpoint for aircraft within bounding box
    url = "${API_URL}"
    
    try:
        resp = requests.get(url, timeout=30)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        return "API Error: " + str(e)
    
    aircraft = data.get('ac', [])
    if not aircraft:
        return "No aircraft data"
    
    now = datetime.utcnow()
    rows = []
    
    for ac in aircraft:
        if not ac.get('lat') or not ac.get('lon'):
            continue
        
        hex_code = ac.get('hex', '')
        flight = (ac.get('flight') or '').strip()
        
        # Handle 'ground' altitude
        alt_baro = ac.get('alt_baro')
        if alt_baro == 'ground':
            alt_baro = 0
        elif alt_baro is not None:
            try:
                alt_baro = int(alt_baro)
            except:
                alt_baro = None

        rows.append([
            hex_code,
            flight,
            ac.get('r', ''),
            ac.get('t', ''),
            ac.get('desc'),
            float(ac.get('lat')),
            float(ac.get('lon')),
            alt_baro,
            ac.get('alt_geom'),
            ac.get('gs'),
            ac.get('track'),
            ac.get('true_heading'),
            ac.get('baro_rate'),
            ac.get('squawk'),
            ac.get('category'),
            now,
            now
        ])
    
    if rows:
        from snowflake.snowpark.types import StructType, StructField, StringType, FloatType, IntegerType, TimestampType
        schema = StructType([
            StructField("HEX", StringType()),
            StructField("FLIGHT", StringType()),
            StructField("REGISTRATION", StringType()),
            StructField("AIRCRAFT_TYPE", StringType()),
            StructField("AIRCRAFT_DESC", StringType()),
            StructField("LAT", FloatType()),
            StructField("LON", FloatType()),
            StructField("ALT_BARO", IntegerType()),
            StructField("ALT_GEOM", IntegerType()),
            StructField("GROUND_SPEED", FloatType()),
            StructField("TRACK", FloatType()),
            StructField("TRUE_HEADING", FloatType()),
            StructField("VERTICAL_RATE", IntegerType()),
            StructField("SQUAWK", StringType()),
            StructField("CATEGORY", StringType()),
            StructField("TIMESTAMP", TimestampType()),
            StructField("INGESTED_AT", TimestampType())
        ])
        df = session.create_dataframe(rows, schema=schema)
        df.write.mode('append').save_as_table('${ADSB_RAW_TABLE}')
    
    return "Inserted " + str(len(rows)) + " records"
$$;

ALTER PROCEDURE ${DATABASE}.${SCHEMA}.PROC_INGEST_ADSB_REALTIME()
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- ETL to ADSB_DATA (canonical)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_ETL_ADSB_TO_DATA()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Use MERGE to make ADSB_DATA duplicate-proof even under repeated calls.
    MERGE INTO ${DATABASE}.${SCHEMA}.ADSB_DATA s
    USING (
        SELECT
            -- CONCAT returns NULL if any input is NULL; historical data often has missing flight callsign.
            -- Make FLIGHT_KEY always non-null (stable per aircraft + (optional) flight + hour bucket).
            MD5(CONCAT(
                COALESCE(UPPER(hex), ''),
                ':',
                COALESCE(UPPER(TRIM(flight)), ''),
                ':',
                TO_VARCHAR(timestamp, 'YYYYMMDDHH24')
            )) AS FLIGHT_KEY,
            UPPER(hex) AS ICAO_HEX,
            UPPER(registration) AS REGISTRATION,
            aircraft_type AS TYPE,
            aircraft_desc AS AIRCRAFT_DESC,
            UPPER(TRIM(flight)) AS FLIGHT,
            timestamp AS TIMESTAMP,
            ST_MAKEPOINT(lon, lat) AS LOCATION,
            track AS TRACK,
            true_heading AS TRUE_HEADING,
            ground_speed AS VELOCITY,
            alt_baro AS ALTITUDE_BARO,
            alt_geom AS ALTITUDE_GEOM,
            vertical_rate AS VERTICAL_RATE,
            squawk AS SQUAWK,
            category AS CATEGORY,
            'ADSB_LOL' AS SOURCE,
            ingested_at AS INGESTED_AT
        FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_LOL_RAW
        WHERE hex IS NOT NULL AND timestamp IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(hex), timestamp
          ORDER BY ingested_at DESC
        ) = 1
    ) r
    ON s.ICAO_HEX = r.ICAO_HEX
   AND s.TIMESTAMP = r.TIMESTAMP
    WHEN MATCHED AND s.FLIGHT_KEY IS NULL THEN UPDATE SET
        FLIGHT_KEY = r.FLIGHT_KEY
    WHEN NOT MATCHED THEN INSERT (
        FLIGHT_KEY, ICAO_HEX, REGISTRATION, TYPE, AIRCRAFT_DESC, FLIGHT, TIMESTAMP, LOCATION, TRACK, TRUE_HEADING,
        VELOCITY, ALTITUDE_BARO, ALTITUDE_GEOM, VERTICAL_RATE, SQUAWK, CATEGORY, SOURCE, INGESTED_AT
    ) VALUES (
        r.FLIGHT_KEY, r.ICAO_HEX, r.REGISTRATION, r.TYPE, r.AIRCRAFT_DESC, r.FLIGHT, r.TIMESTAMP, r.LOCATION, r.TRACK, r.TRUE_HEADING,
        r.VELOCITY, r.ALTITUDE_BARO, r.ALTITUDE_GEOM, r.VERTICAL_RATE, r.SQUAWK, r.CATEGORY, r.SOURCE, r.INGESTED_AT
    );

    -- Backfill safety: if older loads produced NULL FLIGHT_KEY (because flight/callsign was missing),
    -- compute it directly in-place.
    UPDATE ${DATABASE}.${SCHEMA}.ADSB_DATA
    SET FLIGHT_KEY = MD5(CONCAT(
        COALESCE(ICAO_HEX, ''),
        ':',
        COALESCE(UPPER(TRIM(FLIGHT)), ''),
        ':',
        TO_VARCHAR(TIMESTAMP, 'YYYYMMDDHH24')
    ))
    WHERE FLIGHT_KEY IS NULL
      AND ICAO_HEX IS NOT NULL
      AND TIMESTAMP IS NOT NULL;

    RETURN 'ETL Complete';
END;
$$;

ALTER PROCEDURE ${DATABASE}.${SCHEMA}.PROC_ETL_ADSB_TO_DATA()
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- Cleanup helper: remove accidental duplicates in ADSB_DATA by (ICAO_HEX,TIMESTAMP)
-- This is safe: it retains the newest INGESTED_AT per key within the specified window.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_DEDUP_ADSB_DATA(p_days_back INT)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  v_days INT;
  v_rows NUMBER(38,0);
BEGIN
  v_days := COALESCE(:p_days_back, 2);

  DELETE FROM ${DATABASE}.${SCHEMA}.ADSB_DATA
  WHERE (ICAO_HEX, TIMESTAMP, INGESTED_AT) IN (
    SELECT ICAO_HEX, TIMESTAMP, INGESTED_AT
    FROM (
      SELECT
        ICAO_HEX,
        TIMESTAMP,
        INGESTED_AT,
        ROW_NUMBER() OVER (
          PARTITION BY ICAO_HEX, TIMESTAMP
          ORDER BY INGESTED_AT DESC
        ) AS rn
      FROM ${DATABASE}.${SCHEMA}.ADSB_DATA
      WHERE TIMESTAMP::DATE >= DATEADD('day', -:v_days, CURRENT_DATE())
        AND ICAO_HEX IS NOT NULL
        AND TIMESTAMP IS NOT NULL
    )
    WHERE rn > 1
  );

  v_rows := SQLROWCOUNT;
  RETURN 'Deduped ADSB_DATA for last ' || v_days || ' days (deleted_rows=' || v_rows || ')';
END;
$$;

ALTER PROCEDURE ${DATABASE}.${SCHEMA}.PROC_DEDUP_ADSB_DATA(INT)
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- Wrapper procedure for task (combines ingest + ETL)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_ADSB_INGEST_AND_ETL()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    CALL ${DATABASE}.${SCHEMA}.PROC_INGEST_ADSB_REALTIME();
    CALL ${DATABASE}.${SCHEMA}.PROC_ETL_ADSB_TO_DATA();
    -- Extra safety: keep latest data duplicate-free so downstream MERGEs (enrichment) can't fail.
    CALL ${DATABASE}.${SCHEMA}.PROC_DEDUP_ADSB_DATA(2);
    RETURN 'Ingest and ETL complete';
END;
$$;

ALTER PROCEDURE ${DATABASE}.${SCHEMA}.PROC_ADSB_INGEST_AND_ETL()
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- Scheduled Task (daily batch cadence)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK ${DATABASE}.${SCHEMA}.TASK_INGEST_ADSB
  WAREHOUSE = ${WAREHOUSE}
  SCHEDULE = 'USING CRON 30 1 * * * UTC'
  ALLOW_OVERLAPPING_EXECUTION = FALSE
AS
  CALL ${DATABASE}.${SCHEMA}.PROC_ADSB_INGEST_AND_ETL();

ALTER TASK ${DATABASE}.${SCHEMA}.TASK_INGEST_ADSB
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'realtime';

-- -----------------------------------------------------------------------------
-- Task DAG: TASK_ENRICH_ADSB runs after TASK_INGEST_ADSB completes
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK ${DATABASE}.${SCHEMA}.TASK_ENRICH_ADSB
  WAREHOUSE = ${WAREHOUSE}
  AFTER ${DATABASE}.${SCHEMA}.TASK_INGEST_ADSB
AS
  CALL ${DATABASE}.${SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(2);

ALTER TASK ${DATABASE}.${SCHEMA}.TASK_ENRICH_ADSB
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'realtime';

-- Task DAG: TASK_REFRESH_DERIVED runs after TASK_ENRICH_ADSB completes
CREATE OR REPLACE TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_DERIVED
  WAREHOUSE = ${WAREHOUSE}
  AFTER ${DATABASE}.${SCHEMA}.TASK_ENRICH_ADSB
AS
  CALL ${DATABASE}.${SCHEMA}.PROC_REFRESH_DERIVED();

ALTER TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_DERIVED
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'realtime';

-- Task DAG: TASK_REFRESH_ANALYTICS runs after TASK_REFRESH_DERIVED completes
CREATE OR REPLACE TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_ANALYTICS
  WAREHOUSE = ${WAREHOUSE}
  AFTER ${DATABASE}.${SCHEMA}.TASK_REFRESH_DERIVED
AS
  CALL ${DATABASE}.${SCHEMA}.PROC_REFRESH_ANALYTICS();

ALTER TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_ANALYTICS
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'realtime';

-- Tasks are created SUSPENDED. To start:
-- ALTER TASK ${DATABASE}.${SCHEMA}.TASK_INGEST_ADSB RESUME;

-- NOTE: Do NOT run an initial ingestion call during install.
-- In Streamlit execution context this may fail transiently due to external API timing,
-- and it isn't required because the task will run once resumed.
-- To run manually later:
--   CALL ${DATABASE}.${SCHEMA}.PROC_ADSB_INGEST_AND_ETL();

