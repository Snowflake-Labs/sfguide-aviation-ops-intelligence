# Views, Monitoring Tables, and Placeholder Objects

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## HELPER_LANDING_LIVE_TIMETABLE (View)

Live timetable view for dashboard landing page — joins latest ADS-B positions with FLIGHT_SCHEDULE enrichment, planned and actual gates.

```sql
CREATE OR REPLACE VIEW {TARGET_DB}.{SCHEMA}.HELPER_LANDING_LIVE_TIMETABLE AS
WITH airport AS (
  SELECT
    UPPER(airport_code) AS airport_code,
    UPPER(airport_icao) AS airport_icao
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
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
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  WHERE TIMESTAMP >= DATEADD('minute', -10, TO_TIMESTAMP_NTZ(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())))
    AND LOCATION IS NOT NULL
    AND FLIGHT IS NOT NULL
),
live_latest AS (
  SELECT *
  FROM live
  WHERE rn = 1
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
nearest_gate AS (
  SELECT
    i.flight,
    g.gate_name AS nearest_gate,
    ST_DISTANCE(TO_GEOGRAPHY(ST_POINT(i.lon, i.lat)), g.gate_geom) AS nearest_gate_dist_m
  FROM ids i
  JOIN {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES g
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
  JOIN {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE s
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
  FROM {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME
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
```

---

## Monitoring Tables

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH (
  table_name STRING,
  last_refreshed_at TIMESTAMP_NTZ,
  row_count_24h NUMBER(38,0),
  max_ts TIMESTAMP_NTZ,
  status STRING,
  details STRING
);

CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_QA_COUNTS_DAILY (
  metric_date DATE,
  metric_name STRING,
  metric_value NUMBER(38,0)
);

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS row_count_24h NUMBER(38,0);
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS max_ts TIMESTAMP_NTZ;
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS status STRING;
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS details STRING;
```

## Store config: backfill days

```sql
MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH t
USING (SELECT 'CONFIG_ADSB_BACKFILL_DAYS' AS table_name, {BACKFILL_DAYS} AS row_count_24h) s
ON t.table_name = s.table_name
WHEN MATCHED THEN UPDATE SET row_count_24h = s.row_count_24h, last_refreshed_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (table_name, row_count_24h, last_refreshed_at) 
                      VALUES (s.table_name, s.row_count_24h, CURRENT_TIMESTAMP());
```

## HELPER_INGEST_AUDIT

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_INGEST_AUDIT (
  run_id STRING,
  airport_code STRING,
  window_start TIMESTAMP_NTZ,
  window_end TIMESTAMP_NTZ,
  rows_raw NUMBER(38,0),
  rows_inserted NUMBER(38,0),
  rows_deduped NUMBER(38,0),
  status STRING,
  error_message STRING,
  created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

---

## Ops/Performance Placeholder Tables and Views

### H2H_CONFLICT_PAIRS

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.H2H_CONFLICT_PAIRS (
  event_a_id STRING,
  event_b_id STRING,
  flight_a STRING,
  flight_b STRING,
  aircraft_a STRING,
  aircraft_b STRING,
  op_a STRING,
  op_b STRING,
  runway_mode STRING,
  a_start TIMESTAMP_NTZ,
  a_end TIMESTAMP_NTZ,
  b_start TIMESTAMP_NTZ,
  b_end TIMESTAMP_NTZ,
  min_gap_seconds NUMBER(38,0)
);
```

### V_AIR_OPS_TIMELINE (placeholder)

```sql
CREATE OR REPLACE VIEW {TARGET_DB}.{SCHEMA}.V_AIR_OPS_TIMELINE AS
SELECT CAST(NULL AS DATE) AS service_date, CAST(NULL AS STRING) AS airline_name
WHERE 1=0;
```

### V_AIR_OPS_DAILY_KPIS (placeholder)

```sql
CREATE OR REPLACE VIEW {TARGET_DB}.{SCHEMA}.V_AIR_OPS_DAILY_KPIS AS
SELECT
  CAST(NULL AS DATE) AS service_date,
  CAST(NULL AS STRING) AS airline_name,
  CAST(NULL AS NUMBER(38,0)) AS ops,
  CAST(NULL AS FLOAT) AS med_taxi_out_min,
  CAST(NULL AS FLOAT) AS med_taxi_in_min,
  CAST(NULL AS FLOAT) AS med_dep_runway_occ_min,
  CAST(NULL AS FLOAT) AS med_arr_runway_occ_min,
  CAST(NULL AS FLOAT) AS on_time_dep_out_15m_rate,
  CAST(NULL AS FLOAT) AS on_time_arr_in_15m_rate,
  CAST(NULL AS BOOLEAN) AS head_to_head
WHERE 1=0;
```
