# sql-pipeline-infra.md — Database, Warehouse, Tags, UDFs
# Airport: {TARGET_DB} (e.g., AIRPORT_SAN)
# Schema: {SCHEMA} (PUBLIC)
# Overture Airport ID: {AIRPORT_ID}
# IATA: {IATA}, ICAO: {ICAO}

## Step 1: Create Database, Schema, and Grants

```sql
CREATE DATABASE IF NOT EXISTS {TARGET_DB}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

CREATE SCHEMA IF NOT EXISTS {TARGET_DB}.{SCHEMA}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

GRANT USAGE ON DATABASE {TARGET_DB} TO ROLE PUBLIC;
GRANT USAGE ON SCHEMA {TARGET_DB}.{SCHEMA} TO ROLE PUBLIC;
```

## Step 1.5: Create Dedicated Warehouse

```sql
CREATE WAREHOUSE IF NOT EXISTS AVIA_{IATA}_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

USE WAREHOUSE AVIA_{IATA}_WH;
```

## Step 2: Create Cost-Attribution Tags

```sql
CREATE SCHEMA IF NOT EXISTS {TARGET_DB}.TAGS
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

CREATE TAG IF NOT EXISTS {TARGET_DB}.TAGS.SOLUTION
  ALLOWED_VALUES 'aviation-ops-intelligence'
  COMMENT = 'Identifies objects belonging to Aviation Ops Intelligence solution';

CREATE TAG IF NOT EXISTS {TARGET_DB}.TAGS.COMPONENT
  ALLOWED_VALUES 'etl', 'analytics', 'realtime', 'backfill', 'properties'
  COMMENT = 'Functional component categorization';
```

## Step 3: Create UDFs

### UDF_TZID_FROM_LATLON — Timezone from lat/lon

```sql
CREATE OR REPLACE FUNCTION {TARGET_DB}.{SCHEMA}.UDF_TZID_FROM_LATLON(lat DOUBLE, lon DOUBLE)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('timezonefinder')
HANDLER = 'tzid_from_latlon'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
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
```

### GET_OSM_TAG — Extract any tag from Overture source_tags

```sql
CREATE OR REPLACE FUNCTION {TARGET_DB}.{SCHEMA}.GET_OSM_TAG(source_tags VARIANT, tag_key STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS $$
  SELECT MAX(f.value:"value"::STRING)
  FROM TABLE(FLATTEN(input => source_tags:"key_value", OUTER => TRUE)) f
  WHERE LOWER(f.value:"key"::STRING) = LOWER(tag_key)
$$;
```

### ST_GETPOLYGONS — UDTF to split MultiPolygon into individual Polygon rows

```sql
CREATE OR REPLACE FUNCTION {TARGET_DB}.{SCHEMA}.ST_GETPOLYGONS(G OBJECT)
RETURNS TABLE (POLYGON OBJECT)
LANGUAGE JAVASCRIPT
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS $$
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
$$;
```
