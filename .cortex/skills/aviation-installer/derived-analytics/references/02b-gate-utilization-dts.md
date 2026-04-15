# Gate Analysis Dynamic Tables — Utilization and Dwell (DTs 4-6)

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

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
