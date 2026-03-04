-- =============================================================================
-- Backward Compatibility: Flight Tracker + Live Timetable
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

-- ---------------------------------------------------------------------------
-- HELPER_LANDING_LIVE_TIMETABLE (VIEW, not dynamic table)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ${DATABASE}.${SCHEMA}.HELPER_LANDING_LIVE_TIMETABLE AS
WITH airport AS (
  SELECT
    UPPER(airport_code) AS airport_code,
    UPPER(airport_icao) AS airport_icao
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
),
live AS (
  SELECT
    FLIGHT,
    ICAO_HEX,
    REGISTRATION,
    AIRCRAFT_DESC,
    TIMESTAMP AS last_seen,
    ST_Y(LOCATION) AS lat,
    ST_X(LOCATION) AS lon,
    ALTITUDE_BARO,
    VELOCITY,
    TRACK,
    ROW_NUMBER() OVER (PARTITION BY FLIGHT ORDER BY TIMESTAMP DESC) AS rn
  FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
  WHERE TIMESTAMP >= DATEADD('minute', -10, TO_TIMESTAMP_NTZ(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())))
    AND LOCATION IS NOT NULL
    AND FLIGHT IS NOT NULL
),
live_latest AS (
  SELECT * FROM live WHERE rn = 1
),
ids AS (
  SELECT
    l.*,
    UPPER(TRIM(l.flight)) AS flight_norm,
    REGEXP_SUBSTR(UPPER(TRIM(l.flight)), '^[A-Z]{2,3}') AS prefix,
    REGEXP_SUBSTR(UPPER(TRIM(l.flight)), '[0-9]+') AS flight_num
  FROM live_latest l
),
dim_icao AS (
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
nearest_gate AS (
  SELECT
    i.flight,
    g.gate_name AS nearest_gate,
    ST_DISTANCE(TO_GEOGRAPHY(ST_POINT(i.lon, i.lat)), g.gate_geom) AS nearest_gate_dist_m
  FROM ids i
  JOIN ${DATABASE}.${SCHEMA}.PROPERTIES_GATES g
    ON ST_DWITHIN(TO_GEOGRAPHY(ST_POINT(i.lon, i.lat)), g.gate_geom, 300)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY i.flight
    ORDER BY ST_DISTANCE(TO_GEOGRAPHY(ST_POINT(i.lon, i.lat)), g.gate_geom) ASC NULLS LAST
  ) = 1
),
sched_candidates AS (
  SELECT
    i.flight AS flight,
    s.*,
    IFF(UPPER(TRIM(s.FLIGHT_ICAO)) = i.flight_norm, 0,
        IFF(UPPER(TRIM(s.FLIGHT_IATA)) = i.flight_norm, 1, 2)
    ) AS match_rank,
    ABS(DATEDIFF('day', s.FLIGHT_DATE, CURRENT_DATE())) AS date_diff
  FROM ids i
  JOIN ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE s
    ON s.FLIGHT_DATE BETWEEN DATEADD('day', -1, CURRENT_DATE()) AND DATEADD('day', 1, CURRENT_DATE())
   AND (
        UPPER(TRIM(s.FLIGHT_ICAO)) = i.flight_norm
     OR UPPER(TRIM(s.FLIGHT_IATA)) = i.flight_norm
     OR (
          i.flight_num IS NOT NULL
      AND s.FLIGHT_NUMBER = i.flight_num
      AND (
            (LENGTH(i.prefix) = 3 AND UPPER(TRIM(s.AIRLINE_ICAO)) = i.prefix)
         OR (LENGTH(i.prefix) = 2 AND UPPER(TRIM(s.AIRLINE_IATA)) = i.prefix)
      )
     )
   )
),
sched_best AS (
  SELECT
    flight,
    FLIGHT_DATE,
    FLIGHT_STATUS,
    DEPARTURE_AIRPORT,
    ARRIVAL_AIRPORT,
    DEPARTURE_SCHEDULED,
    DEPARTURE_ESTIMATED,
    DEPARTURE_ACTUAL,
    DEPARTURE_TERMINAL,
    DEPARTURE_GATE,
    ARRIVAL_SCHEDULED,
    ARRIVAL_ESTIMATED,
    ARRIVAL_ACTUAL,
    ARRIVAL_TERMINAL,
    ARRIVAL_GATE,
    AIRLINE_NAME,
    AIRLINE_IATA,
    AIRLINE_ICAO,
    FLIGHT_NUMBER,
    FLIGHT_IATA,
    FLIGHT_ICAO,
    UPDATED_AT,
    IFF(
      UPPER(DEPARTURE_AIRPORT) IN (a.airport_code, a.airport_icao),
      'departure',
      IFF(UPPER(ARRIVAL_AIRPORT) IN (a.airport_code, a.airport_icao), 'arrival', 'unknown')
    ) AS direction
  FROM sched_candidates c
  CROSS JOIN airport a
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY flight
    ORDER BY match_rank ASC, date_diff ASC, UPDATED_AT DESC
  ) = 1
),
gate_actual AS (
  SELECT
    service_date,
    UPPER(TRIM(flight_number)) AS flight_number_norm,
    gate_name AS actual_gate,
    dwell_seconds
  FROM ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME
  WHERE flight_number IS NOT NULL
)
SELECT
  i.flight AS flight,
  i.icao_hex AS icao_hex,
  i.registration AS registration,
  i.aircraft_desc AS aircraft_desc,
  i.last_seen AS last_seen,
  i.lat AS lat,
  i.lon AS lon,
  i.altitude_baro AS altitude_baro,
  i.velocity AS velocity,
  i.track AS track,
  sb.direction AS direction,
  COALESCE(sb.airline_name, di.airline_name, dj.airline_name) AS airline_name,
  COALESCE(sb.airline_iata, di.airline_iata, dj.airline_iata) AS airline_iata,
  COALESCE(sb.airline_icao, di.airline_icao, dj.airline_icao) AS airline_icao,
  sb.departure_airport AS departure_airport,
  sb.arrival_airport AS arrival_airport,
  sb.departure_scheduled AS departure_scheduled,
  sb.departure_estimated AS departure_estimated,
  sb.departure_actual AS departure_actual,
  sb.arrival_scheduled AS arrival_scheduled,
  sb.arrival_estimated AS arrival_estimated,
  sb.arrival_actual AS arrival_actual,
  sb.departure_terminal AS departure_terminal,
  sb.departure_gate AS departure_gate_planned,
  sb.arrival_terminal AS arrival_terminal,
  sb.arrival_gate AS arrival_gate_planned,
  IFF(sb.direction = 'departure', sb.departure_gate, IFF(sb.direction = 'arrival', sb.arrival_gate, NULL)) AS planned_gate,
  IFF(sb.direction = 'departure', sb.departure_terminal, IFF(sb.direction = 'arrival', sb.arrival_terminal, NULL)) AS planned_terminal,
  ng.nearest_gate AS nearest_gate,
  ng.nearest_gate_dist_m AS nearest_gate_dist_m,
  ga.actual_gate AS actual_gate,
  ga.dwell_seconds AS actual_gate_dwell_seconds,
  sb.flight_number AS schedule_flight_number,
  sb.flight_iata AS schedule_flight_iata,
  sb.flight_icao AS schedule_flight_icao,
  sb.flight_date AS schedule_flight_date,
  sb.flight_status AS schedule_status
FROM ids i
LEFT JOIN sched_best sb
  ON sb.flight = i.flight
LEFT JOIN dim_icao di
  ON LENGTH(i.prefix) = 3 AND di.airline_icao = i.prefix
LEFT JOIN dim_iata dj
  ON LENGTH(i.prefix) = 2 AND dj.airline_iata = i.prefix
LEFT JOIN nearest_gate ng
  ON ng.flight = i.flight
LEFT JOIN gate_actual ga
  ON ga.service_date = COALESCE(sb.flight_date, i.last_seen::DATE)
 AND ga.flight_number_norm = UPPER(TRIM(i.flight));
