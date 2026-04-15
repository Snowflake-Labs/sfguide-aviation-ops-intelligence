---
name: aviation-installer
description: "Install and configure an airport analytics platform in Snowflake. Routes to sub-skills for base infrastructure setup, ADS-B real-time ingestion, flight schedule ingestion, and derived analytics pipelines. Use when: installing airport analytics, setting up a new airport, deploying aviation platform, provisioning airport database. Do NOT use for: deploying the Streamlit dashboard (use aviation-dashboard), cleaning up objects (use aviation-cleanup), viewing flight data. Triggers: install airport, setup airport, deploy aviation, provision airport, aviation installer, new airport setup, airport analytics platform."
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# Install Airport Analytics Platform

Routes installation requests to the correct sub-skills based on phase. Provisions a complete airport analytics platform in Snowflake: database infrastructure, real-time ADS-B ingestion from adsb.lol, optional flight schedules from Aviationstack, and derived Dynamic Table pipelines for gate analysis, traffic analytics, runway crossings, and operational KPIs.

## Prerequisites

1. **Snowflake Account** with ACCOUNTADMIN role (or equivalent privileges)
2. **Overture Maps Base** dataset from Snowflake Marketplace (`OVERTURE_MAPS__BASE`) — auto-installed in Step 1 if missing
3. **Warehouse** available for installation and ongoing tasks
4. **Aviationstack API key** (optional, for flight schedule ingestion)

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE DATABASE | Account | Creates AIRPORT_{IATA} database |
| CREATE INTEGRATION | Account | Creates external access integrations for APIs |
| CREATE NETWORK RULE | Account | Creates network rules for adsb.lol, GitHub, Aviationstack |
| EXECUTE TASK | Account | Enables scheduled task execution |
| IMPORTED PRIVILEGES ON OVERTURE_MAPS__BASE | Database | Reads airport geometry, infrastructure, gates |

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| AIRPORT | (user selects) | Target airport from Overture Maps inventory |
| WAREHOUSE | AVIA_{IATA}_WH | Dedicated warehouse (created automatically, XSMALL) |
| AVIATIONSTACK_KEY | (optional) | API key for flight schedule ingestion |
| GIT_REPO_STAGE | `@AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main` | Git repo stage for dashboard/airline files |
| BACKFILL_DAYS | 5 | Days of historical ADS-B data to backfill |

## Error Logging

When any step fails or produces unexpected results (SQL errors, missing objects, wrong row counts, service failures, deployment issues), log the issue to `logs/` following the format in `logs/README.md`. Create one log file per execution: `aviation-installer_{YYYY-MM-DD}_{HH-MM}.md`. Continue execution where possible, logging all issues encountered. If execution completes with no issues, do not create a log file.

## Workflow

### Step 1: Set Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-installer","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 2: Install Marketplace Dependencies

Check if `OVERTURE_MAPS__BASE` exists. If not, install it from Snowflake Marketplace:

```sql
SHOW DATABASES LIKE 'OVERTURE_MAPS__BASE';
```

If no results:
```sql
CALL SYSTEM$ACCEPT_LEGAL_TERMS('DATA_EXCHANGE_LISTING', 'GZT0Z4CM1E9KV');
CREATE DATABASE IF NOT EXISTS OVERTURE_MAPS__BASE FROM LISTING GZT0Z4CM1E9KV;
```

Verify:
```sql
SELECT COUNT(*) FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE WHERE class ILIKE '%airport%' LIMIT 1;
```

### Step 3: Select Airport

**Goal:** Load airport inventory from Overture Maps and let user choose target airport.

Run the airport inventory query:
```sql
SELECT
    i.id AS AIRPORT_ID,
    COALESCE(
        MAX(IFF(n.value:"key"::STRING = 'en', NULLIF(TRIM(n.value:"value"::STRING), ''), NULL)),
        i.names:primary::STRING
    ) AS AIRPORT_NAME,
    COALESCE(
        MAX(IFF(LOWER(t.value:"key"::STRING) IN ('iata','iata_code','iata:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)),
        ''
    ) AS AIRPORT_CODE_IATA,
    COALESCE(
        MAX(IFF(LOWER(t.value:"key"::STRING) IN ('icao','icao_code','icao:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)),
        ''
    ) AS AIRPORT_CODE_ICAO
FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
    , LATERAL FLATTEN(input => i.names:"common":"key_value", OUTER => TRUE) n
    , LATERAL FLATTEN(
        input => IFF(IS_OBJECT(i.source_tags), i.source_tags, TRY_PARSE_JSON(i.source_tags)):"key_value",
        OUTER => TRUE
    ) t
WHERE i.class ILIKE '%international_airport%'
  AND i.subtype ILIKE '%airport%'
  AND ST_ASGEOJSON(i.geometry):type::STRING <> 'Point'
GROUP BY i.id, i.names:primary::STRING
HAVING COALESCE(
    MAX(IFF(n.value:"key"::STRING = 'en', NULLIF(TRIM(n.value:"value"::STRING), ''), NULL)),
    i.names:primary::STRING
) IS NOT NULL
ORDER BY AIRPORT_NAME
LIMIT 5000;
```

Ask user to select an airport. Derive:
- `{TARGET_DB}` = `AIRPORT_{IATA}` (e.g., `AIRPORT_SAN`)
- `{SCHEMA}` = `PUBLIC`
- `{IATA}` = Airport IATA code
- `{ICAO}` = Airport ICAO code
- `{AIRPORT_ID}` = Overture Maps record ID

### Step 3.5: Create Dedicated Warehouse

```sql
CREATE WAREHOUSE IF NOT EXISTS AVIA_{IATA}_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-base-setup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

Set `{WAREHOUSE}` = `AVIA_{IATA}_WH` for all subsequent steps.

### Step 4: Gather Configuration

Ask the user:
1. Whether they have an Aviationstack API key (optional)
2. Number of backfill days (default 5)
3. Confirm warehouse to use (default: `AVIA_{IATA}_WH`)

### Step 5: Ensure Git Repository Stage Exists

The airline CSV and dashboard files are loaded from a Git Repository Stage. If it doesn't exist, create it:

```sql
CREATE DATABASE IF NOT EXISTS AVIA_INSTALLER;
CREATE SCHEMA IF NOT EXISTS AVIA_INSTALLER.PUBLIC;

CREATE OR REPLACE GIT REPOSITORY AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO
  API_INTEGRATION = (ask user or use existing)
  ORIGIN = 'https://github.com/Snowflake-Labs/sfguide-aviation-ops-intelligence.git';
```

> **Note:** If the Git Repository Stage already exists (e.g., `@AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main`), skip this step. The default `{GIT_REPO_STAGE_BASE}` is `@AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main`.

### Step 6: Route to Sub-Skills

Execute sub-skills in order:

1. **Base Setup** -- Read and follow `.cortex/skills/aviation-installer/base-setup/SKILL.md`
   - Creates database, schemas, tags, airport properties, gates, runways, airline dimension

2. **ADS-B Ingestion** -- Read and follow `.cortex/skills/aviation-installer/adsb-ingestion/SKILL.md`
   - Creates ADS-B tables, external access integrations, ingestion procedures, tasks, backfill

3. **Flight Schedules** (if API key provided) -- Read and follow `.cortex/skills/aviation-installer/flight-schedules/SKILL.md`
   - Creates schedule tables, ingestion procedure, task

4. **Derived Analytics** -- Read and follow `.cortex/skills/aviation-installer/derived-analytics/SKILL.md`
   - Creates Dynamic Tables, monitoring views, task DAG, operational KPIs

5. **Dashboard** -- Read and follow `.cortex/skills/aviation-dashboard/SKILL.md`
   - Deploys Streamlit-in-Snowflake dashboard from Git repo stage

### Step 7: Start Task DAG

Resume tasks in leaf-to-root order (avoids "Unable to update graph" errors):

```sql
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS RESUME;
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED RESUME;
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB RESUME;
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_AIRCRAFT_META RESUME;
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB RESUME;
```

If flight schedules were configured:
```sql
CALL {TARGET_DB}.{SCHEMA}.PROC_RESUME_OPTIONAL_TASK('TASK_FLIGHT_SCHEDULE');
```

### Step 8: Trigger Initial Data Load

```sql
EXECUTE TASK {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB;
```

Optionally start historical backfill:
```sql
CALL {TARGET_DB}.{SCHEMA}.PROC_START_BACKFILL_HISTORY();
```

### Step 9: Verify Installation

```sql
SELECT 'PROPERTIES_AIRPORT' AS OBJ, COUNT(*) AS CNT FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
UNION ALL SELECT 'PROPERTIES_GATES', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES
UNION ALL SELECT 'PROPERTIES_RUNWAYS', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS
UNION ALL SELECT 'HELPER_AIRLINE_DIM', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM;
```

Check task status:
```sql
SELECT NAME, STATE, LAST_COMMITTED_ON, NEXT_SCHEDULED_TIME
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())))
WHERE DATABASE_NAME = '{TARGET_DB}'
ORDER BY SCHEDULED_TIME DESC;
```

## Stopping Points

- After Step 3: Confirm airport selection with user
- After Step 6.1 (base-setup): Verify PROPERTIES_AIRPORT has 1 row
- After Step 6.2 (adsb-ingestion): Verify EAIs and procedures exist
- After Step 7: Verify all tasks are STARTED
- After Step 8: Wait 2-3 minutes, then verify ADSB_DATA has rows

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Overture Maps query fails | Step 2 auto-installs it; or manually: `CALL SYSTEM$ACCEPT_LEGAL_TERMS('DATA_EXCHANGE_LISTING', 'GZT0Z4CM1E9KV'); CREATE DATABASE IF NOT EXISTS OVERTURE_MAPS__BASE FROM LISTING GZT0Z4CM1E9KV;` |
| Airport not found | Search by ICAO code; some airports lack IATA codes in Overture |
| EAI creation fails | Requires ACCOUNTADMIN or CREATE INTEGRATION privilege |
| Tasks not running | Resume in leaf-to-root order; check warehouse is active |
| No ADS-B data after 5 min | Check `CALL {TARGET_DB}.{SCHEMA}.PROC_INGEST_ADSB_REALTIME()` manually |
| Backfill stuck | Check `HELPER_ADSB_BACKFILL_STATUS` for failed days |

## Cleanup

To remove all objects created by this installation:

> **Tip:** Use the `aviation-cleanup` skill to auto-discover all tagged objects via COMMENT tracking.
