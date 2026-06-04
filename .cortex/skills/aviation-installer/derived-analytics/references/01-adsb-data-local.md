# ADSB_DATA_LOCAL — Foundation Dynamic Table

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## Install audit (versioning / provenance)

Table is created by base-setup (canonical schema). Insert a row to record the derived-analytics install.

```sql
INSERT INTO {TARGET_DB}.{SCHEMA}.HELPER_INSTALL_AUDIT
  (INSTALL_TS, INSTALLER_VERSION, AIRPORT_IATA, AIRPORT_ICAO, AIRPORT_NAME, WAREHOUSE, SCHEMA_NAME, NOTES)
SELECT
  CURRENT_TIMESTAMP(),
  '1.0.0',
  '{IATA}',
  NULL,
  NULL,
  '{WAREHOUSE}',
  '{SCHEMA}',
  'derived-analytics install';
```

## Dashboard prerequisites

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES (gate_id STRING, gate_name STRING, gate_geom GEOGRAPHY)
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS (
  runway_id STRING,
  runway_geog GEOGRAPHY
)
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## FLIGHT_SCHEDULE stub (ensures DTs/views compile when flight-schedules sub-skill is skipped)

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE (
  FLIGHT_KEY VARCHAR(64),
  FLIGHT_DATE DATE,
  FLIGHT_STATUS VARCHAR(20),
  AIRLINE_IATA VARCHAR(3),
  AIRLINE_ICAO VARCHAR(4),
  AIRLINE_NAME VARCHAR(200),
  FLIGHT_IATA VARCHAR(10),
  FLIGHT_ICAO VARCHAR(10),
  FLIGHT_NUMBER VARCHAR(10),
  AIRCRAFT_REGISTRATION VARCHAR(16),
  DEPARTURE_AIRPORT VARCHAR(10),
  DEPARTURE_SCHEDULED TIMESTAMP_NTZ,
  DEPARTURE_ESTIMATED TIMESTAMP_NTZ,
  DEPARTURE_ACTUAL TIMESTAMP_NTZ,
  DEPARTURE_DELAY INT,
  DEPARTURE_TERMINAL VARCHAR(20),
  DEPARTURE_GATE VARCHAR(20),
  ARRIVAL_AIRPORT VARCHAR(10),
  ARRIVAL_SCHEDULED TIMESTAMP_NTZ,
  ARRIVAL_ESTIMATED TIMESTAMP_NTZ,
  ARRIVAL_ACTUAL TIMESTAMP_NTZ,
  ARRIVAL_DELAY INT,
  ARRIVAL_TERMINAL VARCHAR(20),
  ARRIVAL_GATE VARCHAR(20),
  IS_CODESHARE BOOLEAN,
  UPDATED_AT TIMESTAMP_NTZ,
  RAW_PAYLOAD VARIANT,
  INSERTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

-- Non-destructive schema evolution for upgrades / installs that created the stub
-- before FLIGHT_KEY existed. Ensures PROC_ENRICH_ADSB_WITH_SCHEDULE compiles even
-- when the flight-schedules sub-skill is skipped (no Aviationstack key).
ALTER TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE ADD COLUMN IF NOT EXISTS FLIGHT_KEY VARCHAR(64);
ALTER TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE ADD COLUMN IF NOT EXISTS AIRCRAFT_REGISTRATION VARCHAR(16);
ALTER TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE ADD COLUMN IF NOT EXISTS DEPARTURE_DELAY INT;
ALTER TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE ADD COLUMN IF NOT EXISTS ARRIVAL_DELAY INT;
ALTER TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE ADD COLUMN IF NOT EXISTS IS_CODESHARE BOOLEAN;
```

## ADSB_DATA_LOCAL Dynamic Table

Filters ADSB_DATA to airport-relevant flights only (local O/D or touched-airport) and adds the critical `VEHICLE_CATEGORY` computed column. All other DTs depend on this.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH airport AS (
  SELECT
    UPPER(airport_code) AS airport_code,
    COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid,
    geometry AS airport_geom
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
),
pts AS (
  SELECT
    a.*,
    TO_DATE(CONVERT_TIMEZONE('UTC', airport.airport_tzid, a.TIMESTAMP)) AS service_date,
    COALESCE(NULLIF(TRIM(a.FLIGHT), ''), a.ICAO_HEX) AS flight_id
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA a
  CROSS JOIN airport
  WHERE a.ICAO_HEX IS NOT NULL
    AND a.TIMESTAMP IS NOT NULL
),
flags AS (
  SELECT
    p.service_date,
    p.flight_id,
    MAX(IFF(COALESCE(p.IS_LOCAL_OD, FALSE), 1, 0)) AS is_local_od_any,
    MAX(
      IFF(
        airport.airport_geom IS NOT NULL
        AND p.LOCATION IS NOT NULL
        AND ST_DWITHIN(p.LOCATION, airport.airport_geom, 5000),
        1, 0
      )
    ) AS within_airport_radius
  FROM pts p
  CROSS JOIN airport
  GROUP BY 1, 2
),
relevant AS (
  SELECT service_date, flight_id
  FROM flags
  WHERE is_local_od_any = 1 OR within_airport_radius = 1
),
pts_enriched AS (
  SELECT
    p.*,
    CASE 
      WHEN p.CATEGORY = 'A7' THEN 'HELICOPTER'
      WHEN p.CATEGORY = 'A5' THEN 'HEAVY_AIRCRAFT'
      WHEN p.CATEGORY = 'A3' THEN 'LARGE_AIRLINER'
      WHEN p.CATEGORY = 'A2' THEN 'SMALL_COMMUTER'
      WHEN p.CATEGORY = 'A1' THEN 'LIGHT_AIRCRAFT'
      WHEN p.CATEGORY = 'A0' THEN 'MEDIUM_AIRCRAFT'
      WHEN p.CATEGORY = 'A6' THEN 'HIGH_PERFORMANCE_MILITARY'
      WHEN p.CATEGORY LIKE 'B%' THEN 'ULTRALIGHT_EXPERIMENTAL'
      WHEN p.TYPE = 'TWR' THEN 'TOWER'
      WHEN p.TYPE IN ('SERV', 'CAR') THEN 'SERVICE_VEHICLE'
      WHEN p.CATEGORY = 'C1' THEN 'LIGHT_SURFACE_VEHICLE'
      WHEN p.CATEGORY = 'C2' AND COALESCE(p.TYPE, '') NOT IN ('TWR', 'SERV', 'CAR') THEN 'GROUND_VEHICLE'
      WHEN p.CATEGORY = 'C0' THEN 'UNKNOWN_SURFACE'
      ELSE 'OTHER'
    END AS VEHICLE_CATEGORY
  FROM pts p
  JOIN relevant r
    ON r.service_date = p.service_date
   AND r.flight_id = p.flight_id
)
SELECT 
  pe.FLIGHT_KEY,
  pe.ICAO_HEX,
  pe.REGISTRATION,
  pe.TYPE,
  pe.AIRCRAFT_DESC,
  pe.FLIGHT,
  pe.TIMESTAMP,
  pe.LOCATION,
  pe.TRACK,
  pe.TRUE_HEADING,
  pe.VELOCITY,
  pe.ALTITUDE_BARO,
  pe.ALTITUDE_GEOM,
  pe.VERTICAL_RATE,
  pe.SQUAWK,
  pe.CATEGORY,
  pe.SOURCE,
  pe.INGESTED_AT,
  pe.SCHEDULE_FLIGHT_KEY,
  pe.SCHEDULE_FLIGHT_NUMBER,
  CASE 
    WHEN pe.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
    THEN pe.AIRLINE_NAME
    ELSE NULL
  END AS AIRLINE_NAME,
  CASE 
    WHEN pe.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
    THEN pe.AIRLINE_IATA
    ELSE NULL
  END AS AIRLINE_IATA,
  CASE 
    WHEN pe.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
    THEN pe.AIRLINE_ICAO
    ELSE NULL
  END AS AIRLINE_ICAO,
  pe.ORIGIN_AIRPORT,
  pe.DESTINATION_AIRPORT,
  pe.IS_LOCAL_OD,
  pe.SCHEDULED_DEPARTURE,
  pe.SCHEDULED_ARRIVAL,
  pe.MATCH_METHOD,
  pe.MATCH_CONFIDENCE,
  pe.MATCHED_AT,
  pe.service_date,
  pe.flight_id,
  pe.VEHICLE_CATEGORY
FROM pts_enriched pe;
```

## Tag ADSB_DATA_LOCAL

```sql
ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'analytics';
```
