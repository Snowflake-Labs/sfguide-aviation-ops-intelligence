-- =============================================================================
-- DERIVED ANALYTICS: Install Audit + ADSB_DATA_LOCAL
-- Database: ${DATABASE}.${SCHEMA}
-- =============================================================================

    return f"""-- =============================================================================
-- DERIVED ANALYTICS FOR ${AIRPORT_NAME} (${AIRPORT_IATA})
-- Database: ${DATABASE}.${SCHEMA}
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Install audit (versioning / provenance)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_INSTALL_AUDIT (
  installed_at TIMESTAMP_NTZ,
  installer_git_sha STRING,
  installer_generated_at TIMESTAMP_NTZ,
  airport_code STRING,
  database_name STRING,
  schema_name STRING,
  notes STRING
);

INSERT INTO ${DATABASE}.${SCHEMA}.HELPER_INSTALL_AUDIT
SELECT
  CURRENT_TIMESTAMP(),
  '${INSTALLER_SHA}',
  TO_TIMESTAMP_NTZ('${INSTALLER_GENERATED_AT}'),
  '${AIRPORT_IATA}',
  '${DATABASE}',
  '${SCHEMA}',
  'derived install';

-- -----------------------------------------------------------------------------
-- Dashboard prerequisites (ensure objects exist even in troubleshooting mode)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.PROPERTIES_GATES (gate_id STRING, gate_name STRING, gate_geom GEOGRAPHY);
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS (
  runway_id STRING,
  runway_geog GEOGRAPHY
);

-- PROPERTIES_RUNWAYS is the only runway object we need (single unioned GEOGRAPHY row).

-- -----------------------------------------------------------------------------
-- Prerequisites
-- PROPERTIES_RUNWAYS is created as exactly one row during base install, with fallback to airport centroid.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 0. ADSB_DATA_LOCAL (airport-relevant points only)
-- A point is included if its flight-day is either:
--   - Local O/D (schedule enrichment says origin or destination is this airport), OR
--   - "Touched airport": any near-airport ground-like point that day (alt<=50ft, speed<=40kts, within 5km)
-- This is a derived convenience layer for dashboards; ADSB_DATA remains the raw point truth.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = ${WAREHOUSE}
AS
WITH airport AS (
  SELECT
    UPPER(airport_code) AS airport_code,
    COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid,
    geometry AS airport_geom
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  -- LIMIT 1 removed: breaks change tracking; table has only 1 row
),
pts AS (
  SELECT
    a.*,
    TO_DATE(CONVERT_TIMEZONE('UTC', airport.airport_tzid, a.TIMESTAMP)) AS service_date,
    COALESCE(NULLIF(TRIM(a.FLIGHT), ''), a.ICAO_HEX) AS flight_id
  FROM ${DATABASE}.${SCHEMA}.ADSB_DATA a
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
    -- Add VEHICLE_CATEGORY
    CASE 
      -- Helicopters (A7)
      WHEN p.CATEGORY = 'A7' THEN 'HELICOPTER'
      -- Heavy Aircraft (A5 - wide-body)
      WHEN p.CATEGORY = 'A5' THEN 'HEAVY_AIRCRAFT'
      -- Large Airliners (A3 - narrow-body jets)
      WHEN p.CATEGORY = 'A3' THEN 'LARGE_AIRLINER'
      -- Small Commuter (A2 - regional)
      WHEN p.CATEGORY = 'A2' THEN 'SMALL_COMMUTER'
      -- Light Aircraft (A1 - GA)
      WHEN p.CATEGORY = 'A1' THEN 'LIGHT_AIRCRAFT'
      -- Medium Aircraft (A0 - catch-all)
      WHEN p.CATEGORY = 'A0' THEN 'MEDIUM_AIRCRAFT'
      -- High Performance Military (A6)
      WHEN p.CATEGORY = 'A6' THEN 'HIGH_PERFORMANCE_MILITARY'
      -- Ultralights/Experimental (B*)
      WHEN p.CATEGORY LIKE 'B%' THEN 'ULTRALIGHT_EXPERIMENTAL'
      -- Tower vehicles
      WHEN p.TYPE = 'TWR' THEN 'TOWER'
      -- Service vehicles
      WHEN p.TYPE IN ('SERV', 'CAR') THEN 'SERVICE_VEHICLE'
      -- Light surface vehicles (C1)
      WHEN p.CATEGORY = 'C1' THEN 'LIGHT_SURFACE_VEHICLE'
      -- Ground vehicles (C2 non-service)
      WHEN p.CATEGORY = 'C2' AND COALESCE(p.TYPE, '') NOT IN ('TWR', 'SERV', 'CAR') THEN 'GROUND_VEHICLE'
      -- Unknown surface (C0)
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
  -- NULL out airline fields for ground vehicles to prevent incorrect airline matching
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

ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'analytics';

-- NOTE: Gate Analysis, Flight Traffic, Flight Tracker, Runway Crossings, and
-- HELPER_LANDING_LIVE_TIMETABLE are now created by the modular DWELL_CORE layer
-- (06_dwell_core.sql) via sql/compat/*.sql templates. They are no longer
-- defined inline here.
