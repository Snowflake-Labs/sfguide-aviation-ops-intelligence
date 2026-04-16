# Realtime Ingestion Procedures

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

## Step 5: Realtime Ingestion

### PROC_INGEST_ADSB_REALTIME

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_INGEST_ADSB_REALTIME()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'ingest'
EXTERNAL_ACCESS_INTEGRATIONS = ({EAI_ADSB_LOL})
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
import requests
from datetime import datetime

def ingest(session):
    # API endpoint for aircraft within bounding box
    url = "{API_URL}"
    
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
        df.write.mode('append').save_as_table('{TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW')
    
    return "Inserted " + str(len(rows)) + " records"
$$;

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_INGEST_ADSB_REALTIME()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### PROC_ETL_ADSB_TO_DATA

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ETL_ADSB_TO_DATA()
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
BEGIN
    -- Use MERGE to make ADSB_DATA duplicate-proof even under repeated calls.
    MERGE INTO {TARGET_DB}.{SCHEMA}.ADSB_DATA s
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
        FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW
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
    UPDATE {TARGET_DB}.{SCHEMA}.ADSB_DATA
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

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ETL_ADSB_TO_DATA()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### PROC_DEDUP_ADSB_DATA

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_DEDUP_ADSB_DATA(p_days_back INT)
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
DECLARE
  v_days INT;
  v_rows NUMBER(38,0);
BEGIN
  v_days := COALESCE(:p_days_back, 2);

  DELETE FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
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
      FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
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

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_DEDUP_ADSB_DATA(INT)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### PROC_ADSB_INGEST_AND_ETL

```sql
-- Wrapper procedure for task (combines ingest + ETL)
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ADSB_INGEST_AND_ETL()
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
BEGIN
    CALL {TARGET_DB}.{SCHEMA}.PROC_INGEST_ADSB_REALTIME();
    CALL {TARGET_DB}.{SCHEMA}.PROC_ETL_ADSB_TO_DATA();
    -- Extra safety: keep latest data duplicate-free so downstream MERGEs (enrichment) can't fail.
    CALL {TARGET_DB}.{SCHEMA}.PROC_DEDUP_ADSB_DATA(2);
    RETURN 'Ingest and ETL complete';
END;
$$;

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ADSB_INGEST_AND_ETL()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

---

