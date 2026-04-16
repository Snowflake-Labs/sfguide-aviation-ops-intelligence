---
name: base-setup
description: "Create airport database infrastructure, schemas, cost-attribution tags, airport properties from Overture Maps, gate and runway geometry, and airline reference dimension. Subskill of aviation-installer — must be invoked from the router, not independently. Use when: setting up base airport infrastructure as part of installation workflow. Do NOT use for: standalone execution, ADS-B ingestion (use adsb-ingestion), derived analytics (use derived-analytics). Triggers: base setup, airport infrastructure, airport properties, setup airport database."
depends_on:
  - aviation-installer
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# Base Setup

> **This subskill cannot be run independently.** It must be invoked from the `aviation-installer` router.

Creates the `AIRPORT_{IATA}` database, schemas, cost-attribution tags, UDFs, airport properties from Overture Maps geometry, gate points, runway polygons, airline dimension table, and install audit record.

## Prerequisites

- Overture Maps Base (`OVERTURE_MAPS__BASE`) installed from Snowflake Marketplace
- ACCOUNTADMIN role or role with CREATE DATABASE / CREATE INTEGRATION privileges
- `{TARGET_DB}`, `{SCHEMA}`, `{IATA}`, `{ICAO}`, `{AIRPORT_ID}`, `{AIRPORT_NAME}`, `{WAREHOUSE}`, `{GIT_REPO_STAGE_BASE}` resolved by the router

## Configuration

| Variable | Example | Description |
|----------|---------|-------------|
| `{TARGET_DB}` | `AIRPORT_SAN` | Database name (AIRPORT_{IATA}) |
| `{SCHEMA}` | `PUBLIC` | Primary schema |
| `{IATA}` | `SAN` | Airport IATA code |
| `{ICAO}` | `KSAN` | Airport ICAO code |
| `{AIRPORT_ID}` | `08b2...` | Overture Maps place UUID |
| `{AIRPORT_NAME}` | `San Diego International` | Display name |
| `{WAREHOUSE}` | `AVIA_SAN_WH` | Dedicated warehouse |
| `{GIT_REPO_STAGE_BASE}` | `@AIRPORT_SAN.PUBLIC.AVIA_OPS_REPO/branches/main` | Git repo stage path |

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE DATABASE | Account | Creates AIRPORT_{IATA} database |
| CREATE SCHEMA | Database | Creates PUBLIC and TAGS schemas |
| CREATE TAG | Schema | Creates SOLUTION and COMPONENT cost tags |
| CREATE FUNCTION | Schema | Creates UDFs (timezone, OSM tag, polygon splitter) |
| IMPORTED PRIVILEGES ON OVERTURE_MAPS__BASE | Database | Reads airport geometry, infrastructure, gates |

## Friction Log

Report all friction points (errors, warnings, workarounds, race conditions) back to the parent installer. The parent writes the consolidated friction log. If executing standalone, write to `.cortex/skills/logs/aviation-base-setup_{YYYY-MM-DD}_{HH-MM}.md` with the same format described in AGENTS.md.

## Workflow

Execute each statement using `snowflake_sql_execute`. Substitute all `{PLACEHOLDER}` values before executing.

> **Read `references/sql-pipeline-infra.md` (Steps 1-3) and `references/sql-pipeline-properties.md` (Steps 4-9) for complete SQL.**

### CRITICAL: Execution Rules

> 1. **One statement per `snowflake_sql_execute` tool call.**
> 2. **Always use fully qualified object names.**
> 3. **Never use `SET` session variables.**
> 4. **Verify row counts after each CTAS.**
> 5. **All CREATE statements must include a COMMENT tracking tag:** `COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup",...}'`

### Step 0: Set Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 1: Create Database and Schemas

Create `{TARGET_DB}` database, `{SCHEMA}` (PUBLIC) schema, and `TAGS` schema.

### Step 2: Create Cost-Attribution Tags

Create `SOLUTION` and `COMPONENT` tags in `{TARGET_DB}.TAGS`.

### Step 3: Create UDFs

Create 3 UDFs:
- `UDF_TZID_FROM_LATLON(DOUBLE, DOUBLE)` — Python, returns timezone ID from coordinates
- `GET_OSM_TAG(VARIANT, STRING)` — SQL, extracts OSM tag value from source_tags
- `ST_GETPOLYGONS(OBJECT)` — JavaScript UDTF, splits MultiPolygon into individual Polygon rows

### Step 4: Create Airport Properties

CTAS `PROPERTIES_AIRPORT` from Overture Maps geometry for the selected airport ID. Includes geometry, centroid lat/lon, bounding box, IATA/ICAO codes, timezone (via UDF_TZID_FROM_LATLON), and display name.

Verify: `SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT` → expect 1 row.

### Step 5: Create Infrastructure Table

CTAS `PROPERTIES_INFRASTRUCTURE` from Overture Maps infrastructure filtered to airport bounding box. Captures all infrastructure objects (taxiways, aprons, terminals, runways, gates, etc.) within the airport footprint.

Verify: `SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_INFRASTRUCTURE` → expect 100–5000 rows.

### Step 6: Create Gates Table

CTAS `PROPERTIES_GATES` from `PROPERTIES_INFRASTRUCTURE` filtering for gate-class objects. Extracts gate reference codes and centroid geometry.

Verify: `SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES` → expect 5–200 rows depending on airport size.

### Step 7: Create Runways Table

Build `PROPERTIES_RUNWAYS` via multi-step runway polygon extraction:
1. Create `TEMP_RUNWAY_SEGMENTS` from infrastructure runway objects
2. Reproject to EPSG:3857 (meters) → `TEMP_RUNWAY_GEOM_3857`
3. Buffer 20m → `TEMP_RUNWAY_BUFFER_3857`
4. Convert to WGS84 polygons → `TEMP_RUNWAY_POLYGONS`
5. CTAS `PROPERTIES_RUNWAYS` from final polygons
6. Drop temp tables

Verify: `SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS` → expect 1–10 rows.

### Step 8: Create File Format and Airline Dimension

1. Create `FF_AIRLINES_CSV` file format (CSV with header, UTF-8)
2. CTAS `HELPER_AIRLINE_DIM` from `airlines.csv` loaded via Git repo stage
3. CTAS `HELPER_AIRLINE_IATA_ICAO_MAP` as IATA↔ICAO lookup from `HELPER_AIRLINE_DIM`

Verify: `SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM` → expect ~1200 rows.

### Step 9: Create Install Audit Record

Insert into `HELPER_INSTALL_AUDIT` table with installation metadata (version, timestamp, IATA, ICAO, airport name, warehouse, schema).

## Stopping Points

- After Step 4: Confirm PROPERTIES_AIRPORT has 1 row
- After Step 6: Confirm PROPERTIES_GATES has rows
- After Step 8: Confirm HELPER_AIRLINE_DIM has ~1200 rows

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| OVERTURE_MAPS__BASE query fails | Marketplace listing not installed | Install from Snowflake Marketplace; verify IMPORTED PRIVILEGES |
| PROPERTIES_AIRPORT empty | Invalid Overture Maps UUID | Verify airport_id exists in Overture Maps places dataset |
| PROPERTIES_GATES empty | No gate objects in Overture Maps | Check subtype filters; some airports lack gate geometry |
| PROPERTIES_RUNWAYS empty | No runway objects in Overture Maps | Check infrastructure for runway objects; verify subtype/class filters |
| Airline CSV not found | Wrong stage path | Verify GIT_REPO_STAGE_BASE path points to correct branch |
| UDF creation fails | Package agreement missing | Accept ANACONDA_PACKAGE_AGREEMENT on account |

## Return to Router

After completing all steps, return to the `aviation-installer` router and continue with `adsb-ingestion`.

## Cleanup

Use the `aviation-cleanup` skill for automated tag-based teardown. Manual cleanup:

```sql
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.PROPERTIES_INFRASTRUCTURE;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.HELPER_INSTALL_AUDIT;
```
