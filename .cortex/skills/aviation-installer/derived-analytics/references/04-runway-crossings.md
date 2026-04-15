# Runway Crossings Dynamic Table

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## RUNWAY_CROSSINGS_DETAILED

Detects aircraft crossing runway polygons using ST_INTERSECTS, with entry/exit event detection and enrichment.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.RUNWAY_CROSSINGS_DETAILED
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH runway_union AS (
  SELECT
    runway_id,
    runway_geog AS rw
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS
  WHERE runway_geog IS NOT NULL
),
pts AS (
  SELECT 
    flight_key, 
    ICAO_HEX,
    FLIGHT,
    VEHICLE_CATEGORY,
    TO_DATE(CONVERT_TIMEZONE('UTC', 
      (SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') 
       FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT), 
      TIMESTAMP)) AS service_date,
    TIMESTAMP AS ts, 
    LOCATION AS geom, 
    VELOCITY, 
    ALTITUDE_BARO
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  WHERE TIMESTAMP >= DATEADD('day', -30, SYSDATE())
    AND LOCATION IS NOT NULL AND ALTITUDE_BARO IS NOT NULL
),
pts_tagged AS (
  SELECT
    p.*,
    r.runway_id,
    IFF(ST_INTERSECTS(p.geom, r.rw), TRUE, FALSE) AS inside_runway,
    LAG(IFF(ST_INTERSECTS(p.geom, r.rw), TRUE, FALSE))
      OVER (PARTITION BY p.flight_key, r.runway_id ORDER BY p.ts) AS prev_inside,
    LEAD(IFF(ST_INTERSECTS(p.geom, r.rw), TRUE, FALSE))
      OVER (PARTITION BY p.flight_key, r.runway_id ORDER BY p.ts) AS next_inside
  FROM pts p CROSS JOIN runway_union r
),
grouped AS (
  SELECT *, SUM(IFF(inside_runway AND NVL(prev_inside, FALSE) = FALSE, 1, 0))
            OVER (PARTITION BY flight_key, runway_id ORDER BY ts ROWS UNBOUNDED PRECEDING) AS grp_raw
  FROM pts_tagged
),
inside_labeled AS (
  SELECT *, IFF(inside_runway, grp_raw, NULL) AS inside_grp,
    ROW_NUMBER() OVER (PARTITION BY flight_key, runway_id, IFF(inside_runway, grp_raw, NULL) ORDER BY ts) AS rn_asc,
    ROW_NUMBER() OVER (PARTITION BY flight_key, runway_id, IFF(inside_runway, grp_raw, NULL) ORDER BY ts DESC) AS rn_desc
  FROM grouped WHERE inside_runway
),
entry_rows AS (
  SELECT runway_id, flight_key, inside_grp AS event_id, ts AS t_entry, geom AS entry_geom
  FROM inside_labeled
  WHERE rn_asc = 1 AND COALESCE(prev_inside, FALSE) = FALSE
),
exit_rows AS (
  SELECT runway_id, flight_key, inside_grp AS event_id, ts AS t_exit, geom AS exit_geom
  FROM inside_labeled
  WHERE rn_desc = 1 AND COALESCE(next_inside, FALSE) = FALSE
),
stats AS (
  SELECT runway_id, flight_key, inside_grp AS event_id,
    MAX(COALESCE(VELOCITY, 0)) AS max_speed_kts,
    COUNT(*) AS inside_points
  FROM inside_labeled
  GROUP BY 1, 2, 3
),
events AS (
  SELECT e.runway_id, e.flight_key, e.event_id, e.t_entry, x.t_exit, e.entry_geom, x.exit_geom,
    ST_DISTANCE(e.entry_geom, x.exit_geom) AS chord_m,
    DATEDIFF('second', e.t_entry, x.t_exit) AS duration_s,
    s.max_speed_kts, s.inside_points,
    CASE WHEN (ST_Y(x.exit_geom) - ST_Y(e.entry_geom)) > 0.00005 THEN 'S→N'
         WHEN (ST_Y(x.exit_geom) - ST_Y(e.entry_geom)) < -0.00005 THEN 'N→S'
         ELSE 'uncertain' END AS direction,
    ST_CENTROID(ST_MAKELINE(e.entry_geom, x.exit_geom)) AS midpoint_geom
  FROM entry_rows e
  JOIN exit_rows x USING (runway_id, flight_key, event_id)
  JOIN stats s USING (runway_id, flight_key, event_id)
),
pts_metadata AS (
  SELECT DISTINCT
    flight_key,
    FIRST_VALUE(ICAO_HEX) OVER (PARTITION BY flight_key ORDER BY ts) AS icao_hex,
    FIRST_VALUE(service_date) OVER (PARTITION BY flight_key ORDER BY ts) AS service_date,
    FIRST_VALUE(FLIGHT) OVER (PARTITION BY flight_key ORDER BY ts) AS flight,
    FIRST_VALUE(VEHICLE_CATEGORY) OVER (PARTITION BY flight_key ORDER BY ts) AS VEHICLE_CATEGORY
  FROM pts
),
enriched AS (
  SELECT 
    e.*,
    pm.icao_hex,
    pm.service_date,
    pm.flight AS flight_number,
    pm.VEHICLE_CATEGORY,
    SUBSTR(pm.flight, 1, 3) AS airline_code,
    a.AIRLINE_NAME AS airline_name
  FROM events e
  LEFT JOIN pts_metadata pm ON pm.flight_key = e.flight_key
  LEFT JOIN {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL a
    ON a.FLIGHT_KEY = e.flight_key
  QUALIFY ROW_NUMBER() OVER (PARTITION BY e.flight_key ORDER BY a.TIMESTAMP) = 1
)
SELECT * FROM enriched
WHERE max_speed_kts <= 80 AND duration_s <= 300 AND chord_m <= 500 AND direction <> 'uncertain';
```
