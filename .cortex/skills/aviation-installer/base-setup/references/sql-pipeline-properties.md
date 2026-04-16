# sql-pipeline-properties.md — Airport Properties, Airline Dim, Audit
# Airport: {TARGET_DB} (e.g., AIRPORT_SAN)
# Schema: {SCHEMA} (PUBLIC)
# Overture Airport ID: {AIRPORT_ID}
# IATA: {IATA}, ICAO: {ICAO}

## Step 4: Create PROPERTIES_AIRPORT

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH g AS (
  SELECT i.geometry AS geometry
  FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
  WHERE i.id = '{AIRPORT_ID}'
    AND i.class IN ('international_airport','airport','regional_airport','municipal_airport','military_airport','private_airport','seaplane_airport','airstrip')
    AND i.subtype ILIKE '%airport%'
    AND ST_ASGEOJSON(i.geometry):type::STRING <> 'Point'
  LIMIT 1
)
SELECT
  '{AIRPORT_NAME}'::STRING AS airport_name,
  '{IATA}'::STRING AS airport_code,
  '{ICAO}'::STRING AS airport_icao,
  g.geometry AS geometry,
  ST_YMIN(g.geometry) AS min_lat,
  ST_YMAX(g.geometry) AS max_lat,
  ST_XMIN(g.geometry) AS min_lon,
  ST_XMAX(g.geometry) AS max_lon,
  ST_Y(ST_CENTROID(g.geometry)) AS center_lat,
  ST_X(ST_CENTROID(g.geometry)) AS center_lon,
  {TARGET_DB}.{SCHEMA}.UDF_TZID_FROM_LATLON(
    ST_Y(ST_CENTROID(g.geometry)),
    ST_X(ST_CENTROID(g.geometry))
  ) AS airport_tzid,
  TO_GEOGRAPHY(
    '{"type":"Polygon","coordinates":[[['
    || ST_XMIN(g.geometry) || ',' || ST_YMIN(g.geometry) || '],['
    || ST_XMAX(g.geometry) || ',' || ST_YMIN(g.geometry) || '],['
    || ST_XMAX(g.geometry) || ',' || ST_YMAX(g.geometry) || '],['
    || ST_XMIN(g.geometry) || ',' || ST_YMAX(g.geometry) || '],['
    || ST_XMIN(g.geometry) || ',' || ST_YMIN(g.geometry)
    || ']]]}') AS airport_bbox
FROM g;

ALTER TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'properties';
```

## Step 5: Create PROPERTIES_INFRASTRUCTURE

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_INFRASTRUCTURE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH airport AS (
  SELECT geometry FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT LIMIT 1
),
raw_infra AS (
  SELECT
    o.id,
    o.class,
    o.subtype,
    o.names:primary::STRING AS primary_name,
    o.names AS names,
    IFF(IS_OBJECT(o.source_tags), o.source_tags, TRY_PARSE_JSON(o.source_tags)) AS source_tags,
    o.geometry,
    ST_ASGEOJSON(o.geometry):type::STRING AS geometry_type
  FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE o
  INNER JOIN airport a ON ST_INTERSECTS(o.geometry, a.geometry)
),
tags_flat AS (
  SELECT
    r.id,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'aeroway', kv.value:"value"::STRING, NULL)) AS osm_aeroway,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'ref', kv.value:"value"::STRING, NULL)) AS osm_ref,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'name', kv.value:"value"::STRING, NULL)) AS osm_name,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'width', TRY_TO_DOUBLE(kv.value:"value"::STRING), NULL)) AS osm_width,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'surface', kv.value:"value"::STRING, NULL)) AS osm_surface,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'length', TRY_TO_DOUBLE(kv.value:"value"::STRING), NULL)) AS osm_length,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'building', kv.value:"value"::STRING, NULL)) AS osm_building,
    MAX(IFF(LOWER(kv.value:"key"::STRING) = 'landuse', kv.value:"value"::STRING, NULL)) AS osm_landuse
  FROM raw_infra r
  , LATERAL FLATTEN(input => r.source_tags:"key_value", OUTER => TRUE) kv
  GROUP BY r.id
)
SELECT
  r.id AS infrastructure_id,
  r.class,
  r.subtype,
  r.primary_name,
  t.osm_aeroway,
  t.osm_ref,
  t.osm_name,
  t.osm_width,
  t.osm_surface,
  t.osm_length,
  t.osm_building,
  t.osm_landuse,
  r.names AS names_json,
  r.source_tags AS source_tags_json,
  r.geometry_type,
  r.geometry
FROM raw_infra r
LEFT JOIN tags_flat t ON r.id = t.id;

ALTER TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_INFRASTRUCTURE
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'properties';
```

## Step 6: Create PROPERTIES_GATES

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
WITH airport AS (
  SELECT geometry FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT LIMIT 1
),
gates AS (
  SELECT
    i.id,
    ST_ASGEOJSON(i.geometry) AS gate_geojson,
    i.names:primary::STRING AS primary_name,
    IFF(IS_OBJECT(i.source_tags), i.source_tags, TRY_PARSE_JSON(i.source_tags)) AS tags
  FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
  JOIN airport a ON ST_DWITHIN(a.geometry, i.geometry, 2000)
  WHERE i.class ILIKE '%airport_gate%'
),
tags_kv AS (
  SELECT
    g.id,
    g.gate_geojson,
    g.primary_name,
    kv.value:"key"::STRING AS k,
    kv.value:"value"::STRING AS v
  FROM gates g
  , LATERAL FLATTEN(input => g.tags:"key_value", OUTER => TRUE) kv
),
picked AS (
  SELECT
    id,
    gate_geojson,
    MAX(NULLIF(TRIM(primary_name), '')) AS primary_name_any,
    MAX(IFF(LOWER(k) = 'ref',      NULLIF(TRIM(v), ''), NULL)) AS ref_value,
    MAX(IFF(LOWER(k) = 'ref:gate', NULLIF(TRIM(v), ''), NULL)) AS ref_gate_value,
    MAX(IFF(LOWER(k) = 'gate_ref', NULLIF(TRIM(v), ''), NULL)) AS gate_ref_value,
    MAX(IFF(LOWER(k) = 'name',     NULLIF(TRIM(v), ''), NULL)) AS name_value
  FROM tags_kv
  GROUP BY 1,2
)
SELECT
  id AS gate_id,
  COALESCE(primary_name_any, ref_value, ref_gate_value, gate_ref_value, name_value, id) AS gate_name,
  TRY_TO_GEOGRAPHY(gate_geojson) AS gate_geom
FROM picked
WHERE gate_geojson IS NOT NULL;

ALTER TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'properties';
```

## Step 7: Create PROPERTIES_RUNWAYS (multi-step)

### 7a — Extract runway segments with buffer radius

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_SEGMENTS AS
WITH airport AS (
  SELECT geometry FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT LIMIT 1
),
runways AS (
  SELECT
    i.id,
    i.geometry AS runway_geog,
    IFF(IS_OBJECT(i.source_tags), i.source_tags, TRY_PARSE_JSON(i.source_tags)) AS tags
  FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
  JOIN airport a ON ST_INTERSECTS(a.geometry, i.geometry)
  WHERE (i.subtype ILIKE 'runway' OR i.class ILIKE 'runway' OR i.source_tags ILIKE '%runway%')
    AND i.geometry IS NOT NULL
),
tags_kv AS (
  SELECT
    r.id,
    kv.value:"key"::STRING AS k,
    kv.value:"value"::STRING AS v
  FROM runways r
  , LATERAL FLATTEN(input => r.tags:"key_value", OUTER => TRUE) kv
),
widths AS (
  SELECT id, MAX(IFF(LOWER(k) = 'width', TRY_TO_DOUBLE(v), NULL)) AS width_m
  FROM tags_kv
  GROUP BY 1
)
SELECT
  r.id,
  r.runway_geog,
  w.width_m,
  COALESCE(w.width_m / 2.0, 30.0) AS buffer_radius_m
FROM runways r
LEFT JOIN widths w USING (id);
```

### 7b — Convert to EPSG:3857

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_GEOM_3857 AS
SELECT
  id AS runway_id,
  ST_TRANSFORM(TO_GEOMETRY(runway_geog), 3857) AS runway_geom_3857,
  buffer_radius_m
FROM {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_SEGMENTS
WHERE runway_geog IS NOT NULL;
```

### 7c — Buffer in meters

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_BUFFER_3857 AS
SELECT
  runway_id,
  ST_BUFFER(runway_geom_3857, COALESCE(buffer_radius_m, 30.0)) AS runway_buffer_3857
FROM {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_GEOM_3857
WHERE runway_geom_3857 IS NOT NULL;
```

### 7d — Reproject to WGS84 and union

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS AS
SELECT
  'RWY_001' AS runway_id,
  ST_UNION_AGG(TO_GEOGRAPHY(ST_TRANSFORM(runway_buffer_3857, 4326))) AS runway_geog
FROM {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_BUFFER_3857;
```

### 7e — Split MultiPolygon into individual runway rows

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_POLYGONS AS
SELECT
  CONCAT('RWY_', LPAD(TO_VARCHAR(ROW_NUMBER() OVER (ORDER BY TO_VARCHAR(p.POLYGON))), 3, '0')) AS runway_id,
  TO_GEOGRAPHY(p.POLYGON) AS runway_geog
FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS r,
TABLE ({TARGET_DB}.{SCHEMA}.ST_GETPOLYGONS(ST_ASGEOJSON(r.runway_geog))) p
WHERE r.runway_geog IS NOT NULL;

CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS AS
SELECT runway_id, runway_geog
FROM {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_POLYGONS
WHERE runway_geog IS NOT NULL;

ALTER TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'properties';
```

### 7f — Drop temp tables

```sql
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_SEGMENTS;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_GEOM_3857;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_BUFFER_3857;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_POLYGONS;
```

## Step 8: Create File Format and Airline Dimension

```sql
CREATE OR REPLACE FILE FORMAT {TARGET_DB}.{SCHEMA}.FF_AIRLINES_CSV
  TYPE = CSV
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('\\N', 'N/A', '-', '')
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM (
  AIRLINE_ID INT,
  AIRLINE_NAME STRING,
  AIRLINE_IATA STRING,
  AIRLINE_ICAO STRING,
  AIRLINE_CALLSIGN STRING,
  COUNTRY STRING,
  IS_ACTIVE STRING
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

TRUNCATE TABLE {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM;

INSERT INTO {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM (
  AIRLINE_ID, AIRLINE_NAME, AIRLINE_IATA, AIRLINE_ICAO, AIRLINE_CALLSIGN, COUNTRY, IS_ACTIVE
)
SELECT
  TRY_TO_NUMBER(t.$1)::INT AS airline_id,
  t.$2::STRING AS airline_name,
  t.$3::STRING AS airline_iata,
  t.$4::STRING AS airline_icao,
  t.$5::STRING AS airline_callsign,
  t.$6::STRING AS country,
  t.$7::STRING AS is_active
FROM {GIT_REPO_STAGE_BASE}/installer/airlines.csv
  (FILE_FORMAT => {TARGET_DB}.{SCHEMA}.FF_AIRLINES_CSV) t;

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';

CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
SELECT
  UPPER(TRIM(AIRLINE_IATA)) AS airline_iata,
  UPPER(TRIM(AIRLINE_ICAO)) AS airline_icao,
  MAX(AIRLINE_NAME) AS airline_name
FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
WHERE AIRLINE_IATA IS NOT NULL AND TRIM(AIRLINE_IATA) <> ''
  AND AIRLINE_ICAO IS NOT NULL AND TRIM(AIRLINE_ICAO) <> ''
  AND LENGTH(TRIM(AIRLINE_IATA)) IN (2,3)
  AND LENGTH(TRIM(AIRLINE_ICAO)) IN (2,3)
GROUP BY 1, 2;

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

## Step 9: Create Install Audit Record

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_INSTALL_AUDIT (
  INSTALL_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  INSTALLER_VERSION STRING,
  AIRPORT_IATA STRING,
  AIRPORT_ICAO STRING,
  AIRPORT_NAME STRING,
  WAREHOUSE STRING,
  SCHEMA_NAME STRING,
  NOTES STRING
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

INSERT INTO {TARGET_DB}.{SCHEMA}.HELPER_INSTALL_AUDIT
  (INSTALLER_VERSION, AIRPORT_IATA, AIRPORT_ICAO, AIRPORT_NAME, WAREHOUSE, SCHEMA_NAME, NOTES)
VALUES
  ('1.0.0', '{IATA}', '{ICAO}', '{AIRPORT_NAME}', '{WAREHOUSE}', '{SCHEMA}', 'base-setup complete');
```

## Verify

```sql
SELECT 'PROPERTIES_AIRPORT' AS tbl, COUNT(*) AS cnt FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
UNION ALL SELECT 'PROPERTIES_INFRASTRUCTURE', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_INFRASTRUCTURE
UNION ALL SELECT 'PROPERTIES_GATES', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES
UNION ALL SELECT 'PROPERTIES_RUNWAYS', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS
UNION ALL SELECT 'HELPER_AIRLINE_DIM', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM;
```

Expected:
- `PROPERTIES_AIRPORT` -> 1 row
- `PROPERTIES_INFRASTRUCTURE` -> 100-5000 rows
- `PROPERTIES_GATES` -> 5-200 rows
- `PROPERTIES_RUNWAYS` -> 1-10 rows
- `HELPER_AIRLINE_DIM` -> ~1200 rows
