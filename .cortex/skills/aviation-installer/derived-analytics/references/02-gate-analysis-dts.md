# Gate Analysis Dynamic Tables (6 DTs)

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## 1. GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS

Detects continuous on-ground periods per aircraft using LAG-based state change detection.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
),
ground AS (
  SELECT
    ICAO_HEX,
    REGISTRATION,
    TO_DATE(CONVERT_TIMEZONE('UTC', ap.airport_tzid, TIMESTAMP)) AS service_date,
    TIMESTAMP AS ts,
    LOCATION,
    VELOCITY,
    ALTITUDE_BARO,
    VEHICLE_CATEGORY
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  CROSS JOIN ap
  WHERE ICAO_HEX IS NOT NULL
    AND TIMESTAMP IS NOT NULL
    AND LOCATION IS NOT NULL
    AND ALTITUDE_BARO IS NOT NULL
    AND ALTITUDE_BARO <= 50
    AND COALESCE(VELOCITY, 0) <= 40
),
lagged AS (
  SELECT
    *,
    DATEDIFF('minute', LAG(ts) OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts), ts) AS gap_min
  FROM ground
),
sessioned AS (
  SELECT
    *,
    SUM(IFF(COALESCE(gap_min, 999999) > 20, 1, 0))
      OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts ROWS UNBOUNDED PRECEDING) AS session_seq
  FROM lagged
),
agg AS (
  SELECT
    ICAO_HEX,
    service_date,
    session_seq,
    MD5(CONCAT(ICAO_HEX, ':', TO_VARCHAR(service_date), ':', TO_VARCHAR(session_seq))) AS ground_session_id,
    MIN(ts) AS start_ts,
    MAX(ts) AS end_ts,
    DATEDIFF('second', MIN(ts), MAX(ts)) AS dwell_seconds,
    MAX(REGISTRATION) AS registration,
    MAX(VEHICLE_CATEGORY) AS VEHICLE_CATEGORY,
    COUNT(*) AS points
  FROM sessioned
  GROUP BY 1, 2, 3
)
SELECT * FROM agg;
```

### Tag

```sql
ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'analytics';
```

---

## 2. GATE_ANALYSIS_ADSB_GROUND_POINTS

Filters ground-phase ADS-B points with session assignment and nearest gate join.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH ap AS (
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS airport_tzid
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
),
ground AS (
  SELECT
    flight_key,
    ICAO_HEX,
    REGISTRATION,
    FLIGHT,
    TO_DATE(CONVERT_TIMEZONE('UTC', ap.airport_tzid, TIMESTAMP)) AS service_date,
    TIMESTAMP AS ts,
    LOCATION,
    VELOCITY,
    ALTITUDE_BARO,
    VEHICLE_CATEGORY
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  CROSS JOIN ap
  WHERE timestamp IS NOT NULL
    AND altitude_baro IS NOT NULL
    AND altitude_baro <= 50
    AND COALESCE(velocity, 0) <= 40
),
with_lag AS (
  SELECT *,
    TIMESTAMPDIFF('second', LAG(ts) OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts), ts) AS lag_seconds,
    DATEDIFF('minute', LAG(ts) OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts), ts) AS gap_min
  FROM ground
),
with_session AS (
  SELECT
    *,
    SUM(IFF(COALESCE(gap_min, 999999) > 20, 1, 0))
      OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts ROWS UNBOUNDED PRECEDING) AS session_seq
  FROM with_lag
)
SELECT
  MD5(CONCAT(w.ICAO_HEX, ':', TO_VARCHAR(w.service_date), ':', TO_VARCHAR(w.session_seq))) AS ground_session_id,
  MD5(CONCAT(w.ICAO_HEX, ':', TO_VARCHAR(w.service_date))) AS aircraft_day_id,
  w.service_date,
  w.session_seq,
  w.ICAO_HEX,
  w.REGISTRATION,
  w.flight_key,
  w.flight,
  w.ts,
  w.LOCATION,
  w.velocity,
  COALESCE(w.lag_seconds, 0) AS lag_seconds,
  w.VEHICLE_CATEGORY,
  g.gate_name AS closest_gate_name
FROM with_session w
LEFT JOIN {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES g ON ST_DWITHIN(w.LOCATION, g.gate_geom, 120)
QUALIFY ROW_NUMBER() OVER (PARTITION BY w.ICAO_HEX, w.service_date, w.ts ORDER BY ST_DISTANCE(w.LOCATION, g.gate_geom) ASC NULLS LAST) = 1;
```

### Tag

```sql
ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'analytics';
```

---

## 3. GATE_ANALYSIS_FLIGHT_GATE_TIME

Assigns nearest gate to each ground session (picks gate with most dwell time).

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
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
  FROM {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
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
```

---

## 4. GATE_ANALYSIS_GATE_UTIL_DAILY

Daily gate utilization metrics.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_GATE_UTIL_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
SELECT
  service_date AS date,
  closest_gate_name AS gate_name,
  VEHICLE_CATEGORY,
  SUM(lag_seconds)/60.0 AS dwell_minutes,
  COUNT(DISTINCT ground_session_id) AS flights
FROM {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
WHERE closest_gate_name IS NOT NULL
GROUP BY date, gate_name, VEHICLE_CATEGORY;
```

---

## 5. GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY

Dwell minutes per gate per airline per day with full airline dimension lookup.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH dim_icao AS (
  SELECT
    TRIM(UPPER(AIRLINE_ICAO)) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_IATA), '')) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
  WHERE AIRLINE_ICAO IS NOT NULL AND TRIM(AIRLINE_ICAO) <> ''
  GROUP BY 1
),
dim_iata AS (
  SELECT
    TRIM(UPPER(AIRLINE_IATA)) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_ICAO), '')) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
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
  FROM {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS g
  LEFT JOIN {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL a
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
```

---

## 6. GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE

Per-flight gate dwell enriched with airline name (pre-joined for dashboard performance).

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH dim_icao AS (
  SELECT
    TRIM(UPPER(AIRLINE_ICAO)) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_IATA), '')) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
  WHERE AIRLINE_ICAO IS NOT NULL AND TRIM(AIRLINE_ICAO) <> ''
  GROUP BY 1
),
dim_iata AS (
  SELECT
    TRIM(UPPER(AIRLINE_IATA)) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_ICAO), '')) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
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
  FROM {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS
  WHERE closest_gate_name IS NOT NULL
  GROUP BY 1, 2, 3
),
gate AS (
  SELECT 
    ground_session_id, 
    gate_name, 
    dwell_seconds, 
    flight_number
  FROM {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME
),
airline AS (
  SELECT
    ICAO_HEX,
    service_date,
    MAX(NULLIF(TRIM(AIRLINE_ICAO), '')) AS airline_icao,
    MAX(NULLIF(TRIM(AIRLINE_IATA), '')) AS airline_iata,
    MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
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
```
