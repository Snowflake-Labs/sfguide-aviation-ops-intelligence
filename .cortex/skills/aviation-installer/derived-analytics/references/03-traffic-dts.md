# Traffic Fact Dynamic Tables (5 DTs + Flight Tracker)

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## 1. FLIGHT_TRAFFIC_FACT_ADSB_DAILY

Daily arrival/departure counts per VEHICLE_CATEGORY.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
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
FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
CROSS JOIN ap
GROUP BY date, VEHICLE_CATEGORY;
```

---

## 2. FLIGHT_TRAFFIC_FACT_ADSB_HOURLY

Hourly traffic volume by hour-of-day.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
SELECT
  DATE_TRUNC('HOUR', TIMESTAMP) AS hour,
  VEHICLE_CATEGORY,
  COUNT(DISTINCT ICAO_HEX) AS aircraft_count,
  COUNT(*) AS data_points
FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
GROUP BY hour, VEHICLE_CATEGORY;
```

---

## 3. FLIGHT_TRACKER_FLIGHT_LIST

Deduplicated flight list for tracker page dropdown — precomputes per-flight-per-day header fields.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRACKER_FLIGHT_LIST
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH airport AS (
  SELECT
    UPPER(airport_code) AS airport_code,
    COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid,
    geometry AS airport_geom
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
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
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
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
```

---

## 4. FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY

Per-airline daily traffic breakdown (aircraft only, not ground vehicles).

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
)
SELECT
  TO_DATE(CONVERT_TIMEZONE('UTC', ap.airport_tzid, TIMESTAMP)) AS date,
  SUBSTR(FLIGHT, 1, 3) AS airline_code,
  VEHICLE_CATEGORY,
  COUNT(DISTINCT ICAO_HEX) AS aircraft_count,
  COUNT(DISTINCT FLIGHT) AS flight_count,
  COUNT(*) AS data_points
FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
CROSS JOIN ap
WHERE FLIGHT IS NOT NULL
  AND VEHICLE_CATEGORY IN ('HELICOPTER','HEAVY_AIRCRAFT','LARGE_AIRLINER','MEDIUM_AIRCRAFT','SMALL_COMMUTER','LIGHT_AIRCRAFT','HIGH_PERFORMANCE_MILITARY','ULTRALIGHT_EXPERIMENTAL')
GROUP BY date, airline_code, VEHICLE_CATEGORY;
```

---

## 5. FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY

Schedule-vs-actual delay rollup with HELPER_FLIGHT_LEG fallback for actual departure times.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
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
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
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
  FROM {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE
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
  FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG l
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
```
