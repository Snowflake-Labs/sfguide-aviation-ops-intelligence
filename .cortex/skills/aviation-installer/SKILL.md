---
name: aviation-installer
description: "Install and configure an airport analytics platform in Snowflake. Routes to sub-skills for base infrastructure setup, ADS-B real-time ingestion, flight schedule ingestion, TSA checkpoint throughput ingestion, and derived analytics pipelines. Use when: installing airport analytics, setting up a new airport, deploying aviation platform, provisioning airport database. Do NOT use for: deploying the Streamlit dashboard (use aviation-dashboard), cleaning up objects (use aviation-cleanup), viewing flight data. Triggers: install airport, setup airport, deploy aviation, provision airport, aviation installer, new airport setup, airport analytics platform."
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# Install Airport Analytics Platform

Routes installation requests to the correct sub-skills based on phase. Provisions a complete airport analytics platform in Snowflake: database infrastructure, real-time ADS-B ingestion from adsb.lol, optional flight schedules from Aviationstack, optional TSA checkpoint throughput from FOIA data, and derived Dynamic Table pipelines for gate analysis, traffic analytics, runway crossings, and operational KPIs.

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
| AVIATIONSTACK_KEY | (optional) | API key for flight schedule ingestion. Skip for a fully functional install without schedule matching. |
| TSA_THROUGHPUT | yes (default) | Enable TSA checkpoint throughput ingestion from FOIA data. No API key needed. |
| GIT_REPO_STAGE | `@{TARGET_DB}.{SCHEMA}.AVIA_OPS_REPO/branches/main` | Git repo stage for skill source files |
| BACKFILL_DAYS | 5 | Days of historical ADS-B data to backfill |

## Error Logging

When any step fails or produces unexpected results (SQL errors, missing objects, wrong row counts, service failures, deployment issues), log the issue to `.cortex/skills/logs/`. Create one log file per execution: `aviation-installer_{YYYY-MM-DD}_{HH-MM}.md`. Continue execution where possible, logging all issues encountered. If execution completes with no issues, do not create a log file.

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

**Goal:** Help the user find and select their target airport from 22,000+ airports worldwide.

IMPORTANT: Do NOT run a full inventory query. Use a search-based flow instead.

**3a.** Ask the user which airport they want to install. Use the `ask_user_question` tool with a text input:
- Question: "Which airport do you want to install? Type an airport name, city, or IATA/ICAO code (e.g. 'San Diego', 'SAN', 'KSAN')."
- Default value: "" (empty)

**3b.** Run a filtered search using their input. Replace `{SEARCH}` with the user's text:

> **Read `references/airport-search-query.sql`** for the full query. Replace `{SEARCH}` with the user's input before executing.

**3c.** Present matching airports to the user. Use the `ask_user_question` tool with options showing each airport's name, IATA/ICAO codes, and class (e.g. "San Diego International Airport (SAN / KSAN) — international_airport"). If no results, ask the user to try a different search term.

**3d.** From the selected airport, derive:
- `{TARGET_DB}` = `AIRPORT_{IATA}` (prefer IATA; fall back to ICAO if IATA is empty)
- `{SCHEMA}` = `PUBLIC`
- `{IATA}` = Airport IATA code (or ICAO as fallback for DB naming)
- `{ICAO}` = Airport ICAO code
- `{AIRPORT_ID}` = Overture Maps record ID
- `{AIRPORT_NAME}` = Airport name

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

Collect configuration from the user using structured prompts. Ask these one at a time.

**4a. Flight Schedules (Aviationstack)**

Use the `ask_user_question` tool to ask whether the user wants flight schedule ingestion:
- **Option "Skip"**: "Install without flight schedules. Everything works: real-time aircraft tracking, ground activity, runway crossings, and traffic analytics. Flights just won't be matched to airline schedules (no flight numbers, gate assignments, or delay metrics)."
- **Option "I have a key"**: "Enable flight schedule ingestion via Aviationstack. Adds: flight number matching, airline/gate assignments, on-time performance, and delay analytics. Requires a free or paid API key from aviationstack.com."

If user chooses "I have a key", ask them to provide the key using the `ask_user_question` tool with a text input.
Set `{API_KEY}` to the provided key, or leave empty if skipped.

**4b. TSA Throughput**

Use the `ask_user_question` tool to ask whether the user wants TSA checkpoint throughput data:
- **Option "Yes"** (default): "Enable TSA checkpoint throughput ingestion. Fetches weekly passenger throughput data from the TSA FOIA reading room. No API key needed. Adds: checkpoint passenger counts by hour, day, and checkpoint for the selected airport."
- **Option "Skip"**: "Install without TSA throughput data. All other features remain fully functional."

Set `{ENABLE_TSA}` = true/false based on user response.

**4c. Historical Backfill**

Use the `ask_user_question` tool with a text input to ask how many days of historical ADS-B data to load:
- Question: "How many days of historical ADS-B data should we backfill? (0 = skip, max 30, default 5). More days = richer initial dataset but longer install time (~2-3 min per day)."
- Default value: "5"

Set `{BACKFILL_DAYS}` to the user's value.

**4d. Warehouse**

Use the `ask_user_question` tool to confirm the warehouse:
- Question: "We'll create warehouse `AVIA_{IATA}_WH` (XSMALL, auto-suspend 60s). Confirm or provide a different warehouse name."
- Default value: `AVIA_{IATA}_WH`

Set `{WAREHOUSE}` to confirmed name.

### Step 5: Create Git Repository Stage

The airline CSV and skill files are loaded from a Git Repository Stage inside the airport database:

```sql
CREATE OR REPLACE GIT REPOSITORY {TARGET_DB}.{SCHEMA}.AVIA_OPS_REPO
  API_INTEGRATION = (ask user or use existing)
  ORIGIN = 'https://github.com/Snowflake-Labs/sfguide-aviation-ops-intelligence.git';
```

Set `{GIT_REPO_STAGE_BASE}` = `@{TARGET_DB}.{SCHEMA}.AVIA_OPS_REPO/branches/main`.

> **Note:** If the Git Repository Stage already exists, skip this step.

### Step 6: Route to Sub-Skills

Execute sub-skills in order:

1. **Base Setup** -- Read and follow `.cortex/skills/aviation-installer/base-setup/SKILL.md`
   - Creates database, schemas, tags, airport properties, gates, runways, airline dimension

2. **ADS-B Ingestion** -- Read and follow `.cortex/skills/aviation-installer/adsb-ingestion/SKILL.md`
   - Creates ADS-B tables, external access integrations, ingestion procedures, tasks, backfill

3. **Flight Schedules** (if API key provided) -- Read and follow `.cortex/skills/aviation-installer/flight-schedules/SKILL.md`
   - Creates schedule tables, ingestion procedure, task

4. **TSA Throughput** (if enabled, default yes) -- Read and follow `.cortex/skills/aviation-installer/tsa-throughput/SKILL.md`
   - Creates TSA PDF stages, throughput table, network rule, EAI, ingestion procedures, weekly tasks

5. **Derived Analytics** -- Read and follow `.cortex/skills/aviation-installer/derived-analytics/SKILL.md`
   - Creates Dynamic Tables, monitoring views, task DAG, operational KPIs

6. **Dashboard** -- Read and follow `.cortex/skills/aviation-dashboard/SKILL.md`
   - Deploys Streamlit-in-Snowflake dashboard from Git repo stage

### Step 7: Start Task DAG

Resume tasks in leaf-to-root order (avoids "Unable to update graph" errors).

First, ensure the root task is suspended (a sub-skill may have already resumed some tasks):

```sql
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB SUSPEND;
```

Then resume children first, root last:

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

If TSA throughput was enabled:
```sql
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_EXTRACT_TSA_PDF RESUME;
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_FETCH_TSA_PDF RESUME;
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

| Error | Cause | Fix |
|-------|-------|-----|
| Overture Maps query fails | Listing not installed | Step 2 auto-installs it; or manually: `CREATE DATABASE IF NOT EXISTS OVERTURE_MAPS__BASE FROM LISTING GZT0Z4CM1E9KV;` |
| Airport not found | Missing IATA code | Search by ICAO code; some airports lack IATA codes in Overture |
| EAI creation fails | Insufficient privileges | Requires ACCOUNTADMIN or CREATE INTEGRATION privilege |
| Tasks not running | Wrong resume order | Resume in leaf-to-root order; check warehouse is active |
| No ADS-B data after 5 min | Ingestion issue | Check `CALL {TARGET_DB}.{SCHEMA}.PROC_INGEST_ADSB_REALTIME()` manually |
| Backfill stuck | Failed days | Check `HELPER_ADSB_BACKFILL_STATUS` for failed days |

## Cleanup

To remove all objects created by this installation:

> **Tip:** Use the `aviation-cleanup` skill to auto-discover all tagged objects via COMMENT tracking.
