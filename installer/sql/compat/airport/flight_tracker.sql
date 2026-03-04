-- =============================================================================
-- Backward Compatibility: Flight Tracker
-- =============================================================================

-- ---------------------------------------------------------------------------
-- FLIGHT_TRACKER_FLIGHT_LIST
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRACKER_FLIGHT_LIST
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
WITH airport AS (
  SELECT
    UPPER(airport_code) AS airport_code,
    COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid,
    geometry AS airport_geom
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
),
base AS (
  SELECT
    TO_DATE(CONVERT_TIMEZONE('UTC', airport.airport_tzid, TIMESTAMP)) AS service_date,
    COALESCE(NULLIF(TRIM(FLIGHT), ''), ICAO_HEX) AS flight_id,
    ICAO_HEX,
    TIMESTAMP AS ts,
    LOCATION AS location,
    ALTITUDE_BARO AS altitude_baro,
    VELOCITY AS velocity,
    VEHICLE_CATEGORY,
    NULLIF(TRIM(SCHEDULE_FLIGHT_NUMBER), '') AS schedule_flight_number,
    NULLIF(TRIM(AIRLINE_NAME), '') AS airline_name,
    NULLIF(TRIM(ORIGIN_AIRPORT), '') AS origin_airport,
    NULLIF(TRIM(DESTINATION_AIRPORT), '') AS destination_airport,
    COALESCE(IS_LOCAL_OD, FALSE) AS is_local_od,
    COALESCE(MATCH_CONFIDENCE, -1) AS match_confidence
  FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
  CROSS JOIN airport
  WHERE ICAO_HEX IS NOT NULL
    AND TIMESTAMP IS NOT NULL
),
agg AS (
  SELECT
    service_date,
    flight_id,
    COUNT(*) AS points,
    MIN(ts) AS first_seen_ts,
    MAX(ts) AS last_seen_ts,
    MAX(IFF(is_local_od, 1, 0)) AS is_local_od_any,
    MAX(
      IFF(
        airport.airport_geom IS NOT NULL
        AND location IS NOT NULL
        AND altitude_baro IS NOT NULL AND altitude_baro <= 50
        AND COALESCE(velocity, 0) <= 40
        AND ST_DWITHIN(location, airport.airport_geom, 5000),
        1, 0
      )
    ) AS touched_airport_any
  FROM base
  CROSS JOIN airport
  GROUP BY 1, 2
),
best AS (
  SELECT
    service_date,
    flight_id,
    schedule_flight_number,
    airline_name,
    origin_airport,
    destination_airport,
    is_local_od,
    match_confidence,
    VEHICLE_CATEGORY
  FROM base
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY service_date, flight_id
    ORDER BY
      IFF(is_local_od, 1, 0) DESC,
      match_confidence DESC,
      IFF(airline_name IS NULL, 0, 1) DESC,
      IFF(origin_airport IS NULL OR destination_airport IS NULL, 0, 1) DESC,
      ts DESC
  ) = 1
)
SELECT
  a.service_date,
  a.flight_id,
  a.points,
  a.first_seen_ts,
  a.last_seen_ts,
  b.schedule_flight_number,
  b.airline_name,
  b.origin_airport,
  b.destination_airport,
  b.match_confidence,
  b.VEHICLE_CATEGORY,
  IFF(a.is_local_od_any = 1, TRUE, FALSE) AS is_local_od,
  IFF(a.touched_airport_any = 1, TRUE, FALSE) AS touched_airport
FROM agg a
LEFT JOIN best b
  ON b.service_date = a.service_date
 AND b.flight_id = a.flight_id
WHERE a.is_local_od_any = 1 OR a.touched_airport_any = 1;

