# TSA Checkpoint Geospatial Mapping View

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{IATA}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## V_TSA_THROUGHPUT_CLEAN (View)

Normalizes the raw `TSA_THROUGHPUT` table (populated by AI_EXTRACT from FOIA PDFs) into typed, dashboard-ready columns. Parses the `MM/DD/YYYY` date string into a real `DATE`, extracts the integer hour, strips thousands separators from the passenger count, and filters out misaligned-extraction rows (where the `date` cell failed to parse, or `checkpoint` is empty / a stray numeric token > 40 chars).

> **REQUIRED**: The React dashboard's **TSA Throughput** page (`TSAThroughput.tsx`) and the Streamlit TSA page both query `V_TSA_THROUGHPUT_CLEAN` for every KPI (Total Passengers, Daily Average, Peak Hour, Checkpoints), the daily/hourly/checkpoint charts, the day-of-week × hour heatmap, and the raw data table. If this view is missing, the entire TSA page renders zeros and "No data" even when `TSA_THROUGHPUT` is fully populated. Create it in the same step as `V_TSA_CHECKPOINT_GEO`.

The view is intentionally **airport-agnostic** — it exposes `airport_code` so the dashboard can filter (`WHERE airport_code = '{IATA}'`); do not bake `{IATA}` into the view.

```sql
CREATE OR REPLACE VIEW {TARGET_DB}.{SCHEMA}.V_TSA_THROUGHPUT_CLEAN
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
SELECT
    UPPER(airport_code)                                          AS airport_code,
    date                                                         AS date,
    TRY_TO_DATE(date, 'MM/DD/YYYY')                              AS throughput_date,
    TRY_TO_NUMBER(SPLIT_PART(hour_of_day, ':', 1))               AS hour_num,
    checkpoint                                                   AS checkpoint,
    TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)    AS total_pax,
    airport_name                                                 AS airport_name,
    city                                                         AS city,
    state                                                        AS state
FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT
WHERE TRY_TO_DATE(date, 'MM/DD/YYYY') IS NOT NULL
  AND checkpoint IS NOT NULL
  AND checkpoint != ''
  AND LEN(checkpoint) < 40;
```

### Columns consumed by the dashboard

| Column | Used for |
| --- | --- |
| `airport_code` | Filter to the current airport's IATA |
| `date` | `dateRangeSql` re-parses raw `MM/DD/YYYY` to derive available min/max date |
| `throughput_date` | Date filtering + daily trend / heatmap day-of-week |
| `hour_num` | Hourly bar chart + heatmap hour axis + Peak Hour KPI |
| `checkpoint` | Checkpoint bar chart, Checkpoint Share pie, Checkpoints KPI |
| `total_pax` | All passenger sums (Total Passengers, Daily Average) |
| `airport_name`, `city`, `state` | Raw data table |

---

## V_TSA_CHECKPOINT_GEO (View)

Maps TSA checkpoint throughput data to physical terminal building geometries from `PROPERTIES_INFRASTRUCTURE`. Uses fuzzy text matching (substring containment + Jaro-Winkler similarity) to link checkpoint names to terminal polygons. Unmatched checkpoints fall back to the airport centroid.

```sql
CREATE OR REPLACE VIEW {TARGET_DB}.{SCHEMA}.V_TSA_CHECKPOINT_GEO
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH terminal_candidates AS (
    SELECT
        infrastructure_id,
        COALESCE(osm_name, osm_ref, primary_name) AS terminal_name,
        geometry AS terminal_geom,
        ST_Y(ST_CENTROID(geometry)) AS terminal_lat,
        ST_X(ST_CENTROID(geometry)) AS terminal_lon,
        ST_ASGEOJSON(geometry) AS terminal_geojson,
        CASE
            WHEN osm_aeroway = 'terminal' THEN 1
            WHEN osm_building = 'terminal' THEN 2
            WHEN class IN ('information', 'building') THEN 3
            WHEN geometry_type = 'Polygon' THEN 4
            ELSE 5
        END AS source_priority
    FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_INFRASTRUCTURE
    WHERE (
        osm_aeroway = 'terminal'
        OR osm_building = 'terminal'
        OR (
            CONTAINS(UPPER(COALESCE(osm_name, primary_name, '')), 'TERMINAL')
            AND class NOT IN ('bus_stop', 'bridge')
        )
    )
      AND geometry IS NOT NULL
      AND geometry_type IN ('Polygon', 'MultiPolygon', 'Point')
),
terminals AS (
    SELECT *
    FROM terminal_candidates
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY terminal_name
        ORDER BY source_priority ASC
    ) = 1
),
airport AS (
    SELECT center_lat, center_lon
    FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
    LIMIT 1
),
tsa_checkpoints AS (
    SELECT DISTINCT
        checkpoint
    FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{IATA}'
      AND checkpoint IS NOT NULL AND checkpoint != ''
      AND LEN(checkpoint) < 40
),
checkpoint_terminal_match AS (
    SELECT
        c.checkpoint,
        t.infrastructure_id,
        t.terminal_name,
        t.terminal_lat,
        t.terminal_lon,
        t.terminal_geojson,
        ROW_NUMBER() OVER (
            PARTITION BY c.checkpoint
            ORDER BY
                t.source_priority ASC,
                CASE WHEN CONTAINS(UPPER(c.checkpoint), UPPER(t.terminal_name)) THEN 0
                     WHEN CONTAINS(UPPER(t.terminal_name), UPPER(c.checkpoint)) THEN 1
                     ELSE 2 END,
                JAROWINKLER_SIMILARITY(UPPER(c.checkpoint), UPPER(COALESCE(t.terminal_name, ''))) DESC
        ) AS match_rank
    FROM tsa_checkpoints c
    LEFT JOIN terminals t
        ON CONTAINS(UPPER(c.checkpoint), UPPER(t.terminal_name))
        OR CONTAINS(UPPER(t.terminal_name), UPPER(c.checkpoint))
        OR JAROWINKLER_SIMILARITY(UPPER(c.checkpoint), UPPER(COALESCE(t.terminal_name, ''))) > 75
),
best_match AS (
    SELECT *
    FROM checkpoint_terminal_match
    WHERE match_rank = 1
),
tsa_daily AS (
    SELECT
        TRY_TO_DATE(date, 'MM/DD/YYYY') AS throughput_date,
        checkpoint,
        TRY_TO_NUMBER(SPLIT_PART(hour_of_day, ':', 1)) AS hour_of_day,
        TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0) AS passengers
    FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{IATA}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') IS NOT NULL
      AND LEN(checkpoint) < 40
)
SELECT
    td.throughput_date,
    td.checkpoint,
    td.hour_of_day,
    td.passengers,
    bm.terminal_name,
    bm.infrastructure_id,
    COALESCE(bm.terminal_lat, a.center_lat) AS lat,
    COALESCE(bm.terminal_lon, a.center_lon) AS lon,
    bm.terminal_geojson,
    CASE WHEN bm.terminal_lat IS NOT NULL THEN 'matched' ELSE 'centroid' END AS match_type
FROM tsa_daily td
LEFT JOIN best_match bm
    ON bm.checkpoint = td.checkpoint
CROSS JOIN airport a;
```

### Usage

This view is consumed by the TSA Throughput dashboard pages to render a map showing:
- Terminal building polygons colored/sized by passenger throughput
- Scatter dots at terminal centroids (or airport centroid for unmatched checkpoints)
- Tooltip with checkpoint name, passenger count, and match type

### Aggregation Queries for Map

**Checkpoint-level aggregation (for map dots):**
```sql
SELECT
    checkpoint,
    terminal_name,
    lat,
    lon,
    terminal_geojson,
    match_type,
    SUM(passengers) AS total_passengers,
    COUNT(DISTINCT throughput_date) AS num_days,
    ROUND(SUM(passengers) / NULLIF(COUNT(DISTINCT throughput_date), 0)) AS daily_avg_passengers
FROM {TARGET_DB}.{SCHEMA}.V_TSA_CHECKPOINT_GEO
WHERE throughput_date BETWEEN '{START_DATE}' AND '{END_DATE}'
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY total_passengers DESC;
```
