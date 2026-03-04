-- =============================================================================
-- Backward Compatibility: Gate Analysis PUBLIC dynamic tables
--
-- These dynamic tables keep the same names, columns, and semantics as before.
-- Where possible, they SELECT FROM DWELL_CORE objects so that policy-driven
-- thresholds take effect. The dashboard queries these objects unchanged.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS
-- Reads from DWELL_CORE.DWELL_SESSION (policy-parameterized).
-- Output columns match existing schema exactly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
SELECT
  ds.asset_id                   AS ICAO_HEX,
  ds.service_date_local         AS service_date,
  ds.session_seq                AS session_seq,
  ds.session_id                 AS ground_session_id,
  ds.start_ts_utc               AS start_ts,
  ds.end_ts_utc                 AS end_ts,
  ds.dwell_seconds              AS dwell_seconds,
  ds.attrs:registration::STRING AS registration,
  ds.asset_category             AS VEHICLE_CATEGORY,
  ds.points                     AS points
FROM ${DATABASE}.DWELL_CORE.DWELL_SESSION ds;

ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'analytics';

-- ---------------------------------------------------------------------------
-- GATE_ANALYSIS_ADSB_GROUND_POINTS
-- Reads from DWELL_CORE.ZONE_ASSIGNMENT + PRESENCE_POINT.
-- Output columns match existing schema exactly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = ${WAREHOUSE}
AS
SELECT
  za.session_id                        AS ground_session_id,
  MD5(CONCAT(za.asset_id, ':', TO_VARCHAR(za.service_date_local)))
                                       AS aircraft_day_id,
  za.service_date_local                AS service_date,
  za.session_seq                       AS session_seq,
  za.asset_id                          AS ICAO_HEX,
  pp.attrs:registration::STRING        AS REGISTRATION,
  pp.attrs:flight_key::STRING          AS flight_key,
  pp.attrs:callsign::STRING            AS flight,
  za.observed_ts_utc                   AS ts,
  pp.location                          AS LOCATION,
  pp.speed                             AS velocity,
  za.lag_seconds                       AS lag_seconds,
  za.asset_category                    AS VEHICLE_CATEGORY,
  za.zone_name                         AS closest_gate_name
FROM ${DATABASE}.DWELL_CORE.ZONE_ASSIGNMENT za
JOIN ${DATABASE}.DWELL_CORE.PRESENCE_POINT pp
  ON pp.site_id = za.site_id
 AND pp.asset_id = za.asset_id
 AND pp.observed_ts_utc = za.observed_ts_utc;

ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'analytics';

-- ---------------------------------------------------------------------------
-- GATE_ANALYSIS_FLIGHT_GATE_TIME
-- Per-session dominant gate assignment. Reads from compat ground points.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = ${WAREHOUSE}
AS
WITH per_gate AS (
  SELECT
    ground_session_id,
    aircraft_day_id,
    service_date,
    ICAO_HEX,
    MAX(flight) AS flight_number,
    MAX(VEHICLE_CATEGORY) AS VEHICLE_CATEGORY,
    closest_gate_name AS gate_name,
    SUM(lag_seconds) AS dwell_seconds
  FROM ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
  WHERE closest_gate_name IS NOT NULL
  GROUP BY 1, 2, 3, 4, closest_gate_name
)
SELECT
  ground_session_id AS flight_key,
  ground_session_id,
  aircraft_day_id,
  service_date,
  ICAO_HEX,
  flight_number,
  gate_name,
  dwell_seconds,
  VEHICLE_CATEGORY
FROM per_gate
QUALIFY ROW_NUMBER() OVER (PARTITION BY ground_session_id ORDER BY dwell_seconds DESC) = 1;

-- ---------------------------------------------------------------------------
-- GATE_ANALYSIS_GATE_UTIL_DAILY
-- Reads from DWELL_CORE.ZONE_DWELL_FACT for policy-driven dwell.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_GATE_UTIL_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
SELECT
  service_date_local     AS date,
  zone_name              AS gate_name,
  asset_category         AS VEHICLE_CATEGORY,
  dwell_minutes          AS dwell_minutes,
  distinct_sessions      AS flights
FROM ${DATABASE}.DWELL_CORE.ZONE_DWELL_FACT
WHERE zone_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
-- Reads from compat ground points (preserves existing airline-join logic).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
WITH dim_icao AS (
  SELECT
    TRIM(UPPER(AIRLINE_ICAO)) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_IATA), '')) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM
  WHERE AIRLINE_ICAO IS NOT NULL AND TRIM(AIRLINE_ICAO) <> ''
  GROUP BY 1
),
dim_iata AS (
  SELECT
    TRIM(UPPER(AIRLINE_IATA)) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_ICAO), '')) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM
  WHERE AIRLINE_IATA IS NOT NULL AND TRIM(AIRLINE_IATA) <> ''
  GROUP BY 1
),
by_session AS (
  SELECT
    g.service_date AS date,
    g.ground_session_id,
    g.ICAO_HEX,
    g.closest_gate_name AS gate_name,
    g.VEHICLE_CATEGORY,
    SUM(g.lag_seconds)/60.0 AS dwell_minutes,
    CASE
      WHEN g.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
      THEN COALESCE(
        MAX(NULLIF(TRIM(a.AIRLINE_ICAO), '')),
        MAX(di.airline_icao)
      )
      ELSE NULL
    END AS airline_icao,
    CASE
      WHEN g.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
      THEN COALESCE(
        MAX(NULLIF(TRIM(a.AIRLINE_IATA), '')),
        MAX(dj.airline_iata)
      )
      ELSE NULL
    END AS airline_iata,
    CASE
      WHEN g.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
      THEN COALESCE(
        MAX(NULLIF(TRIM(a.AIRLINE_NAME), '')),
        MAX(di.airline_name),
        MAX(dj.airline_name)
      )
      ELSE NULL
    END AS airline_name
  FROM ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS g
  LEFT JOIN ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL a
    ON a.ICAO_HEX = g.ICAO_HEX
   AND a.TIMESTAMP = g.ts
  LEFT JOIN dim_icao di
    ON di.airline_icao = REGEXP_SUBSTR(UPPER(TRIM(g.flight)), '^[A-Z]{3}')
   AND g.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
  LEFT JOIN dim_iata dj
    ON dj.airline_iata = REGEXP_SUBSTR(UPPER(TRIM(g.flight)), '^[A-Z]{2}')
   AND g.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
  WHERE g.closest_gate_name IS NOT NULL
  GROUP BY
    g.service_date,
    g.ground_session_id,
    g.ICAO_HEX,
    g.closest_gate_name,
    g.VEHICLE_CATEGORY
)
SELECT
  s.date,
  s.gate_name,
  CASE
    WHEN s.VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
    THEN COALESCE(s.airline_icao, s.airline_iata, 'UNK')
    ELSE s.VEHICLE_CATEGORY
  END AS airline_code,
  MAX(s.airline_name) AS airline_name,
  s.VEHICLE_CATEGORY,
  SUM(s.dwell_minutes) AS dwell_minutes,
  COUNT(DISTINCT s.ground_session_id) AS flights
FROM by_session s
GROUP BY 1,2,3,5;

-- ---------------------------------------------------------------------------
-- GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE
-- Pre-joined dwell + airline for dashboard performance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
WITH dim_icao AS (
  SELECT
    TRIM(UPPER(AIRLINE_ICAO)) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_IATA), '')) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM
  WHERE AIRLINE_ICAO IS NOT NULL AND TRIM(AIRLINE_ICAO) <> ''
  GROUP BY 1
),
dim_iata AS (
  SELECT
    TRIM(UPPER(AIRLINE_IATA)) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_ICAO), '')) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM
  WHERE AIRLINE_IATA IS NOT NULL AND TRIM(AIRLINE_IATA) <> ''
  GROUP BY 1
),
per_session AS (
  SELECT
    ground_session_id,
    icao_hex,
    service_date,
    MAX(VEHICLE_CATEGORY) AS VEHICLE_CATEGORY,
    SUM(lag_seconds)/60.0 AS dwell_minutes
  FROM ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
  WHERE closest_gate_name IS NOT NULL
  GROUP BY 1, 2, 3
),
gate AS (
  SELECT
    ground_session_id,
    gate_name,
    dwell_seconds,
    flight_number
  FROM ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME
),
airline AS (
  SELECT
    ICAO_HEX,
    service_date,
    MAX(NULLIF(TRIM(AIRLINE_ICAO), '')) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_IATA), '')) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
  GROUP BY 1, 2
)
SELECT
  COALESCE(NULLIF(TRIM(g.flight_number), ''), p.icao_hex) AS flight_number,
  COALESCE(
    a.airline_icao,
    a.airline_iata,
    di.airline_icao,
    dj.airline_iata,
    REGEXP_SUBSTR(UPPER(TRIM(g.flight_number)), '^[A-Z]{3}'),
    REGEXP_SUBSTR(UPPER(TRIM(g.flight_number)), '^[A-Z]{2}'),
    'UNK'
  ) AS airline_code,
  COALESCE(
    a.airline_name,
    di.airline_name,
    dj.airline_name
  ) AS airline_name,
  p.service_date,
  g.gate_name,
  ROUND(p.dwell_minutes) AS dwell_minutes,
  p.VEHICLE_CATEGORY
FROM per_session p
LEFT JOIN gate g ON g.ground_session_id = p.ground_session_id
LEFT JOIN airline a ON a.icao_hex = p.icao_hex AND a.service_date = p.service_date
LEFT JOIN dim_icao di ON di.airline_icao = REGEXP_SUBSTR(UPPER(TRIM(g.flight_number)), '^[A-Z]{3}')
LEFT JOIN dim_iata dj ON dj.airline_iata = REGEXP_SUBSTR(UPPER(TRIM(g.flight_number)), '^[A-Z]{2}');
