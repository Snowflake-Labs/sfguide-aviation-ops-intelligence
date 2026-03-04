-- =============================================================================
-- AIRPORT PROPERTIES & REFERENCE DATA
-- Database: ${DATABASE}.${SCHEMA}
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. PROPERTIES_AIRPORT
-- -----------------------------------------------------------------------------
-- Timezone UDF (IANA tzid) from lat/lon.
-- We compute tzid inside Snowflake so queries don't depend on installer Python runtime.
CREATE OR REPLACE FUNCTION ${DATABASE}.${SCHEMA}.UDF_TZID_FROM_LATLON(lat DOUBLE, lon DOUBLE)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('timezonefinder')
HANDLER = 'tzid_from_latlon'
AS
$$
from timezonefinder import TimezoneFinder

_tf = TimezoneFinder()

def tzid_from_latlon(lat, lon):
    if lat is None or lon is None:
        return None
    try:
        return _tf.timezone_at(lat=float(lat), lng=float(lon))
    except Exception:
        return None
$$;

CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT AS
WITH g AS (
  SELECT i.geometry AS geometry
  FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
  WHERE i.id = '${AIRPORT_ID}'
    AND i.class ILIKE '%international_airport%'
    AND i.subtype ILIKE '%airport%'
    AND ST_ASGEOJSON(i.geometry):type::STRING <> 'Point'
  LIMIT 1
)
SELECT
  '${AIRPORT_NAME}'::STRING AS airport_name,
  '${AIRPORT_IATA}'::STRING AS airport_code,
  '${AIRPORT_ICAO}'::STRING AS airport_icao,
  g.geometry AS geometry,
  ST_YMIN(g.geometry) AS min_lat,
  ST_YMAX(g.geometry) AS max_lat,
  ST_XMIN(g.geometry) AS min_lon,
  ST_XMAX(g.geometry) AS max_lon,
  ST_Y(ST_CENTROID(g.geometry)) AS center_lat,
  ST_X(ST_CENTROID(g.geometry)) AS center_lon,
  ${DATABASE}.${SCHEMA}.UDF_TZID_FROM_LATLON(
    ST_Y(ST_CENTROID(g.geometry)),
    ST_X(ST_CENTROID(g.geometry))
  ) AS airport_tzid
FROM g;

ALTER TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'properties';

-- -----------------------------------------------------------------------------
-- 2. PROPERTIES_INFRASTRUCTURE (all Overture infrastructure intersecting airport)
-- Stores all infrastructure objects for flexible filtering and metadata queries.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_INFRASTRUCTURE AS
WITH airport AS (
  SELECT geometry
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
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
  INNER JOIN airport a
    ON ST_INTERSECTS(o.geometry, a.geometry)
),
-- Flatten source_tags for common OSM keys used in airport infrastructure
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

ALTER TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_INFRASTRUCTURE 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'properties';

-- -----------------------------------------------------------------------------
-- GET_OSM_TAG UDF: Retrieve any OSM tag from source_tags_json by key
-- Usage: GET_OSM_TAG(source_tags_json, 'operator')
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ${DATABASE}.${SCHEMA}.GET_OSM_TAG(source_tags VARIANT, tag_key STRING)
RETURNS STRING
LANGUAGE SQL
AS $$
  SELECT MAX(f.value:"value"::STRING)
  FROM TABLE(FLATTEN(input => source_tags:"key_value", OUTER => TRUE)) f
  WHERE LOWER(f.value:"key"::STRING) = LOWER(tag_key)
$$;

-- -----------------------------------------------------------------------------
-- 3. PROPERTIES_GATES (Gate points from Overture Maps Infrastructure)
-- In Overture, airport gates are typically POINT features (OSM aeroway=gate).
-- Gate names are frequently stored in `source_tags.key_value[]` under key="ref".
-- Snowflake cannot GROUP BY GEOGRAPHY/GEOMETRY, so we aggregate on ST_ASGEOJSON(geometry).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_GATES AS
WITH airport AS (
  SELECT geometry
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
),
gates AS (
  SELECT
    i.id,
    ST_ASGEOJSON(i.geometry) AS gate_geojson,
    i.names:primary::STRING AS primary_name,
    IFF(
      IS_OBJECT(i.source_tags),
      i.source_tags,
      TRY_PARSE_JSON(i.source_tags)
    ) AS tags
  FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
  JOIN airport a
    ON ST_DWITHIN(a.geometry, i.geometry, 2000)
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

ALTER TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_GATES 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'properties';

-- -----------------------------------------------------------------------------
-- 4. PROPERTIES_RUNWAYS (from Overture Maps Infrastructure)
-- -----------------------------------------------------------------------------
-- NOTE: Runway Crossings logic relies on an "inside runway" signal.
-- A LINESTRING runway rarely intersects noisy ADS-B points, so we store a runway *corridor area*
-- by buffering the runway centerline to a wider corridor.
--
-- Buffer width:
-- - If Overture `source_tags` contains a numeric `width` tag for a runway segment, we use (width_m / 2) as buffer radius.
--   (Width is full runway width; buffer radius expands on both sides of the centerline.)
-- - If width is missing/invalid, we fall back to a conservative default radius (30m).
-- Snowflake buffers GEOMETRY in meters, so we:
--   GEOGRAPHY -> GEOMETRY (WGS84) -> EPSG:3857 -> ST_BUFFER(radius_m) -> EPSG:4326 -> GEOGRAPHY
--
-- Split into 3 statements to reduce compilation time (Overture union, then buffer, then transform+store).
-- IMPORTANT: In Snowflake Streamlit execution context, `CREATE TEMPORARY TABLE` can be unsupported.
-- We use normal tables with a `TEMP_` prefix instead.

-- 1) Extract runway segments + width-derived buffer radius (meters)
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_SEGMENTS AS
WITH airport AS (
  SELECT geometry
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1
),
runways AS (
  SELECT
    i.id,
    i.geometry AS runway_geog,
    IFF(IS_OBJECT(i.source_tags), i.source_tags, TRY_PARSE_JSON(i.source_tags)) AS tags
  FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
  JOIN airport a
    ON ST_INTERSECTS(a.geometry, i.geometry)
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
  SELECT
    id,
    MAX(IFF(LOWER(k) = 'width', TRY_TO_DOUBLE(v), NULL)) AS width_m
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

-- 1b) Convert runway segments to EPSG:3857 GEOMETRY (meters) once (reduces nested geospatial expressions later)
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_GEOM_3857 AS
SELECT
  id AS runway_id,
  ST_TRANSFORM(TO_GEOMETRY(runway_geog), 3857) AS runway_geom_3857,
  buffer_radius_m
FROM ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_SEGMENTS
WHERE runway_geog IS NOT NULL;

-- 2) Buffer all runway segments in meters (EPSG:3857)
-- NOTE: Some Snowflake accounts do not support ST_UNION_AGG over GEOMETRY, so we
-- keep buffered pieces as GEOMETRY here and union them later as GEOGRAPHY.
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_BUFFER_3857 AS
SELECT
  runway_id,
  ST_BUFFER(runway_geom_3857, COALESCE(buffer_radius_m, 30.0)) AS runway_buffer_3857
FROM ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_GEOM_3857
WHERE runway_geom_3857 IS NOT NULL;

-- 3) Reproject back to 4326 and store as GEOGRAPHY (runway corridor area)
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS AS
SELECT
  -- Use a simple stable row id; if we later split into multiple polygons, we'll re-number them.
  'RWY_001' AS runway_id,
  -- Union as GEOGRAPHY (supported), after transforming buffered GEOMETRY back to WGS84.
  ST_UNION_AGG(TO_GEOGRAPHY(ST_TRANSFORM(runway_buffer_3857, 4326))) AS runway_geog
FROM ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_BUFFER_3857;

-- 4) If runway corridor is a MULTIPOLYGON, split into one polygon per row.
-- Snowflake doesn't expose a built-in "dump parts" function in all accounts, so we use
-- a small JS table function that expands GeoJSON Polygon/MultiPolygon into Polygon rows.
-- NOTE: the installer splits statements on `;`, so the JS body must NOT contain semicolons.
CREATE OR REPLACE FUNCTION ${DATABASE}.${SCHEMA}.ST_GETPOLYGONS(G OBJECT)
RETURNS TABLE (POLYGON OBJECT)
LANGUAGE JAVASCRIPT
AS '
{
processRow: function split_multipolygon(row, rowWriter, context){
    var geojson = row.G
    var polygons = []
    if (!geojson) return
    if (geojson.type === "Polygon") polygons.push(geojson.coordinates)
    else if (geojson.type === "MultiPolygon") {
        for (var i = 0; i < geojson.coordinates.length; i++) polygons.push(geojson.coordinates[i])
    }
    for (var j = 0; j < polygons.length; j++) {
        rowWriter.writeRow({POLYGON: {"type":"Polygon","coordinates": polygons[j]}})
    }
}
}
';

CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_POLYGONS AS
SELECT
  CONCAT('RWY_', LPAD(TO_VARCHAR(ROW_NUMBER() OVER (ORDER BY TO_VARCHAR(p.POLYGON))), 3, '0')) AS runway_id,
  TO_GEOGRAPHY(p.POLYGON) AS runway_geog
FROM ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS r,
TABLE (${DATABASE}.${SCHEMA}.ST_GETPOLYGONS(ST_ASGEOJSON(r.runway_geog))) p
WHERE r.runway_geog IS NOT NULL;

CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS AS
SELECT runway_id, runway_geog
FROM ${DATABASE}.${SCHEMA}.TEMP_RUNWAY_POLYGONS
WHERE runway_geog IS NOT NULL;

ALTER TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'properties';

-- -----------------------------------------------------------------------------
-- 5. HELPER_AIRLINE_DIM (standing airline reference)
-- -----------------------------------------------------------------------------
-- NOTE: we load airlines.csv via SQL from the Git repo stage.
-- This keeps the install fully SQL-based (no Python-side file loading).
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM (
  AIRLINE_ID INT,
  AIRLINE_NAME STRING,
  AIRLINE_IATA STRING,
  AIRLINE_ICAO STRING,
  AIRLINE_CALLSIGN STRING,
  COUNTRY STRING,
  IS_ACTIVE STRING
);

-- CSV file format for airline dim
CREATE OR REPLACE FILE FORMAT ${DATABASE}.${SCHEMA}.FF_AIRLINES_CSV
  TYPE = CSV
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('\N', 'N/A', '-', '');

-- Load from Git repository stage.
-- NOTE: Snowflake does NOT support `COPY INTO <table>` directly from a Git Repository stage.
-- Instead we read the CSV via a SELECT from the stage and INSERT into the table.
TRUNCATE TABLE ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM;

INSERT INTO ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM (
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
FROM ${GIT_REPO_STAGE_BASE}/installer/sql/adapters/airport/data/airlines.csv
  (FILE_FORMAT => ${DATABASE}.${SCHEMA}.FF_AIRLINES_CSV) t;

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- 7. HELPER_AIRLINE_IATA_ICAO_MAP (IATA<->ICAO translation for callsign matching)
-- -----------------------------------------------------------------------------
-- Purpose: Allow matching ADS-B callsigns that use ICAO prefix (SKW3481) with
-- schedule data that uses IATA prefix (OO3481), and vice versa.
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP AS
SELECT
  UPPER(TRIM(AIRLINE_IATA)) AS airline_iata,
  UPPER(TRIM(AIRLINE_ICAO)) AS airline_icao,
  MAX(AIRLINE_NAME) AS airline_name
FROM ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_DIM
WHERE AIRLINE_IATA IS NOT NULL
  AND TRIM(AIRLINE_IATA) <> ''
  AND AIRLINE_ICAO IS NOT NULL
  AND TRIM(AIRLINE_ICAO) <> ''
  AND LENGTH(TRIM(AIRLINE_IATA)) IN (2,3)
  AND LENGTH(TRIM(AIRLINE_ICAO)) IN (2,3)
GROUP BY 1, 2;

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- 8. FLIGHT_SCHEDULE tables (always created, even without API key)
-- -----------------------------------------------------------------------------
-- Raw schedule table (Bronze layer)
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW (
    flight_date DATE,
    flight_status VARCHAR(32),
    departure_airport VARCHAR(8),
    departure_scheduled TIMESTAMP_NTZ,
    departure_estimated TIMESTAMP_NTZ,
    departure_actual TIMESTAMP_NTZ,
    departure_delay INT,
    departure_terminal VARCHAR(8),
    departure_gate VARCHAR(8),
    arrival_airport VARCHAR(8),
    arrival_scheduled TIMESTAMP_NTZ,
    arrival_estimated TIMESTAMP_NTZ,
    arrival_actual TIMESTAMP_NTZ,
    arrival_delay INT,
    arrival_terminal VARCHAR(8),
    arrival_gate VARCHAR(8),
    airline_name VARCHAR(128),
    airline_iata VARCHAR(8),
    airline_icao VARCHAR(8),
    flight_number VARCHAR(16),
    flight_iata VARCHAR(16),
    flight_icao VARCHAR(16),
    aircraft_registration VARCHAR(16),
    aircraft_iata VARCHAR(8),
    aircraft_icao VARCHAR(8),
    codeshared_airline VARCHAR(128),
    codeshared_flight_iata VARCHAR(16),
    raw_json VARIANT,
    ingested_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- Canonical schedule table (Silver layer)
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE (
    FLIGHT_KEY VARCHAR(128),
    FLIGHT_DATE DATE,
    FLIGHT_STATUS VARCHAR(32),
    DEPARTURE_AIRPORT VARCHAR(8),
    ARRIVAL_AIRPORT VARCHAR(8),
    DEPARTURE_SCHEDULED TIMESTAMP_NTZ,
    DEPARTURE_ESTIMATED TIMESTAMP_NTZ,
    DEPARTURE_ACTUAL TIMESTAMP_NTZ,
    DEPARTURE_DELAY INT,
    DEPARTURE_TERMINAL VARCHAR(8),
    DEPARTURE_GATE VARCHAR(8),
    ARRIVAL_SCHEDULED TIMESTAMP_NTZ,
    ARRIVAL_ESTIMATED TIMESTAMP_NTZ,
    ARRIVAL_ACTUAL TIMESTAMP_NTZ,
    ARRIVAL_DELAY INT,
    ARRIVAL_TERMINAL VARCHAR(8),
    ARRIVAL_GATE VARCHAR(8),
    AIRLINE_NAME VARCHAR(128),
    AIRLINE_IATA VARCHAR(8),
    AIRLINE_ICAO VARCHAR(8),
    FLIGHT_NUMBER VARCHAR(16),
    FLIGHT_IATA VARCHAR(16),
    FLIGHT_ICAO VARCHAR(16),
    AIRCRAFT_REGISTRATION VARCHAR(16),
    IS_CODESHARE BOOLEAN,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

ALTER TABLE ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- Verify
SELECT 'PROPERTIES_AIRPORT' AS tbl, COUNT(*) AS cnt FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
UNION ALL SELECT 'PROPERTIES_INFRASTRUCTURE', COUNT(*) FROM ${DATABASE}.${SCHEMA}.PROPERTIES_INFRASTRUCTURE
UNION ALL SELECT 'PROPERTIES_GATES', COUNT(*) FROM ${DATABASE}.${SCHEMA}.PROPERTIES_GATES
UNION ALL SELECT 'PROPERTIES_RUNWAYS', COUNT(*) FROM ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS
UNION ALL SELECT 'HELPER_FLIGHT_SCHEDULE_RAW', COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW
UNION ALL SELECT 'FLIGHT_SCHEDULE', COUNT(*) FROM ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE;
