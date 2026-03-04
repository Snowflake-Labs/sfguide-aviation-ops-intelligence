-- =============================================================================
-- Backward Compatibility: Flight Traffic PUBLIC dynamic tables
--
-- These remain airport-specific (not part of the dwell core contract).
-- Extracted from inline Python for modularity; logic is preserved verbatim.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- FLIGHT_TRAFFIC_FACT_ADSB_DAILY
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
)
SELECT
  TO_DATE(CONVERT_TIMEZONE('UTC', ap.airport_tzid, TIMESTAMP)) AS date,
  VEHICLE_CATEGORY,
  COUNT(DISTINCT ICAO_HEX) AS unique_aircraft,
  COUNT(DISTINCT FLIGHT) AS unique_flights,
  COUNT(*) AS total_records,
  AVG(ALTITUDE_BARO) AS avg_altitude,
  AVG(VELOCITY) AS avg_speed
FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
CROSS JOIN ap
GROUP BY date, VEHICLE_CATEGORY;

-- ---------------------------------------------------------------------------
-- FLIGHT_TRAFFIC_FACT_ADSB_HOURLY
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
SELECT
  DATE_TRUNC('HOUR', TIMESTAMP) AS hour,
  VEHICLE_CATEGORY,
  COUNT(DISTINCT ICAO_HEX) AS aircraft_count,
  COUNT(*) AS data_points
FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
GROUP BY hour, VEHICLE_CATEGORY;

-- ---------------------------------------------------------------------------
-- FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
)
SELECT
  TO_DATE(CONVERT_TIMEZONE('UTC', ap.airport_tzid, TIMESTAMP)) AS date,
  SUBSTR(FLIGHT, 1, 3) AS airline_code,
  VEHICLE_CATEGORY,
  COUNT(DISTINCT ICAO_HEX) AS aircraft_count,
  COUNT(DISTINCT FLIGHT) AS flight_count,
  COUNT(*) AS data_points
FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
CROSS JOIN ap
WHERE FLIGHT IS NOT NULL
  AND VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
GROUP BY date, airline_code, VEHICLE_CATEGORY;

-- ---------------------------------------------------------------------------
-- FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
),
bounds AS (
  SELECT
    ap.airport_tzid AS airport_tzid,
    TO_DATE(CONVERT_TIMEZONE('UTC', ap.airport_tzid, TO_TIMESTAMP_NTZ(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())))) AS local_today
  FROM ap
),
airport AS (
  SELECT
    UPPER(airport_code) AS airport_code,
    UPPER(airport_icao) AS airport_icao
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
),
schedule AS (
  SELECT
    FLIGHT_DATE AS travel_date,
    AIRLINE_NAME AS airline,
    AIRLINE_IATA AS airline_iata,
    AIRLINE_ICAO AS airline_icao,
    FLIGHT_NUMBER AS flight_number,
    DEPARTURE_SCHEDULED AS scheduled_time,
    DEPARTURE_ACTUAL AS actual_time
  FROM ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE
  WHERE FLIGHT_DATE >= DATEADD('day', -30, (SELECT local_today FROM bounds))
    AND DEPARTURE_SCHEDULED IS NOT NULL
    AND (UPPER(DEPARTURE_AIRPORT) = (SELECT airport_code FROM airport)
         OR UPPER(DEPARTURE_AIRPORT) = (SELECT airport_icao FROM airport))
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY FLIGHT_DATE, FLIGHT_NUMBER, AIRLINE_IATA, AIRLINE_ICAO
    ORDER BY DEPARTURE_SCHEDULED
  ) = 1
),
adsb_fallback AS (
  SELECT
    l.service_date AS date,
    SUBSTR(l.callsign, 1, 3) AS airline_code,
    REGEXP_SUBSTR(l.callsign, '[0-9]+') AS flight_number,
    MIN(l.leg_start_ts) AS first_departure
  FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_LEG l
  WHERE l.service_date >= DATEADD('day', -30, (SELECT local_today FROM bounds))
    AND l.direction = 'departure'
    AND l.callsign IS NOT NULL
  GROUP BY 1, 2, 3
),
joined AS (
  SELECT
    s.travel_date AS date,
    s.airline,
    TIMESTAMPDIFF('minute', s.scheduled_time,
      COALESCE(s.actual_time, a.first_departure)) AS delay_minutes
  FROM schedule s
  LEFT JOIN adsb_fallback a
    ON s.travel_date = a.date
   AND TO_VARCHAR(s.flight_number) = TO_VARCHAR(a.flight_number)
   AND (UPPER(s.airline_iata) = UPPER(a.airline_code) OR UPPER(s.airline_icao) = UPPER(a.airline_code))
)
SELECT
  date,
  airline,
  SUM(IFF(delay_minutes > 15, delay_minutes, 0)) AS total_delay_minutes,
  SUM(IFF(delay_minutes > 15, 1, 0)) AS delayed_flights,
  SUM(IFF(delay_minutes < -15, ABS(delay_minutes), 0)) AS total_early_minutes,
  SUM(IFF(delay_minutes < -15, 1, 0)) AS early_flights
FROM joined
WHERE delay_minutes IS NOT NULL
GROUP BY date, airline;
