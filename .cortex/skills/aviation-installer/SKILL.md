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

## Re-installation Behavior

The installer detects existing airport databases before proceeding. When `AIRPORT_{IATA}` already exists, you will be prompted to choose:

- **Update dashboard only** -- redeploys the dashboard if a newer version is available; all data and pipelines remain untouched
- **Skip** -- leave the existing installation completely untouched
- **Full reinstall** -- destroys all accumulated data and recreates from scratch (irreversible)

### Dashboard Location

Both dashboards (Streamlit app and React SPCS service) are deployed once per account and auto-discover all `AIRPORT_XXX` databases. When installing a second (or third) airport, the installer detects existing dashboard objects and updates them in-place rather than creating duplicates. Both always live in the same host database (whichever airport database was installed first, or whichever already hosts an existing dashboard).

### Object Safety Reference

| Category | Pattern | Re-run Effect |
|----------|---------|--------------|
| Database, Warehouse, Schemas, Tags | `IF NOT EXISTS` | Safe -- no data loss |
| HELPER_INSTALL_AUDIT | `IF NOT EXISTS` + INSERT | Safe -- appends audit rows |
| PROPERTIES_*, ADSB_DATA, HELPER_ADSB_LOL_RAW | `CREATE OR REPLACE` | **Destructive** -- data wiped |
| 13 Dynamic Tables | `CREATE OR REPLACE` | **Destructive** -- analytics history lost |
| Procedures, Tasks, UDFs, Views | `CREATE OR REPLACE` | Safe -- stateless objects |
| Streamlit app, SPCS service | `CREATE OR REPLACE` / redeploy | Safe -- idempotent |

## Error Logging

When any step fails or produces unexpected results, log the issue to `.cortex/skills/logs/` following the format in `.cortex/skills/logs/README.md`. File name: `aviation-installer_{YYYY-MM-DD}_{HH-MM}.md`. Continue execution where possible.

## Friction Logging

**MANDATORY:** After every execution (regardless of success or failure), generate a friction log in `.cortex/skills/logs/`. File name: `friction-log_{YYYY-MM-DD}_{HH-MM}.md`.

Follow the friction log template in `.cortex/skills/logs/README.md`. The log must capture:
- Exact wall-clock duration of each step (Step Timing table)
- Configuration parameters used
- Objects created counts and initial data row counts
- Any friction points with F1/F2/F3 numbering, each including: Step, Severity (High/Medium/Low), What happened, Resolution, Recommendation
- Verification checklist with pass/fail
- Summary with total execution time and overall outcome (SUCCESS / COMPLETED_WITH_ISSUES / FAILED)

If no friction was encountered, still create the log with "No friction points encountered." and all other sections filled.

Sub-skills executed via `runSubagent` must report friction points back to this parent skill for consolidation into the single friction log.

## Workflow

### Step 1: Set Query Tag and Record Start Time

Record the installation start time (store as `{START_TIME}`):
```sql
SELECT CURRENT_TIMESTAMP() AS install_start_time;
```

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

### Step 3.1: Check for Existing Installation

After resolving `{TARGET_DB}`, check if this airport database already exists:

```sql
SHOW DATABASES LIKE '{TARGET_DB}';
```

**If the database exists**, run a quick health check to understand the current state:

```sql
SELECT 'PROPERTIES_AIRPORT' AS obj, COUNT(*) AS cnt FROM {TARGET_DB}.PUBLIC.PROPERTIES_AIRPORT
UNION ALL SELECT 'ADSB_DATA', COUNT(*) FROM {TARGET_DB}.PUBLIC.ADSB_DATA
UNION ALL SELECT 'HELPER_AIRLINE_DIM', COUNT(*) FROM {TARGET_DB}.PUBLIC.HELPER_AIRLINE_DIM;
```

Then prompt the user with `ask_user_question` (3 options):

- **Option "Update dashboard only"**: "Keep all data and pipelines intact. Redeploy the dashboard if a newer version is available. Current data: {row counts from health check}."
- **Option "Skip this airport"**: "Leave the existing installation completely untouched. No changes will be made."
- **Option "Full reinstall (data loss)"**: "WARNING: This will destroy ALL accumulated ADS-B data, flight schedules, Dynamic Tables, and analytics history for {AIRPORT_NAME}. This cannot be undone. The airport will be rebuilt from scratch."

**Handling each choice:**

- **Update dashboard only** → Jump to **Step 3.1a: Dashboard-Only Update** (below).
- **Skip this airport** → Print "Skipping {AIRPORT_NAME} ({IATA}) — existing installation preserved." and stop.
- **Full reinstall** → Continue with Step 3.5 and the normal installation flow (Steps 4–9).

**If the database does not exist**, proceed normally with Step 3.5 (fresh install).

### Step 3.1a: Dashboard-Only Update

This shortcut path skips all data pipeline sub-skills and only updates the dashboard.

1. Resolve `{WAREHOUSE}` from the existing installation:
   ```sql
   SELECT WAREHOUSE FROM {TARGET_DB}.PUBLIC.HELPER_INSTALL_AUDIT
   ORDER BY INSTALL_TS DESC LIMIT 1;
   ```
   Fall back to `AVIA_{IATA}_WH` if no audit record exists.

2. Locate the existing dashboard host database. Check BOTH object types in ANY airport database:
   ```sql
   SHOW STREAMLITS IN ACCOUNT;
   SHOW SERVICES LIKE 'AVIATION_DASHBOARD_SERVICE' IN ACCOUNT;
   ```
   Filter results for rows where the `comment` column contains `"sf_sit-is-aviation"` and `"oss-aviation-dashboard"`. Record the database from either result as `{DASHBOARD_DB}` (prefer the database that hosts both; if only one exists, use that database).

   If no existing Streamlit or SPCS dashboard is found, set `{DASHBOARD_DB}` = `{TARGET_DB}`.

3. Ensure the Git Repository Stage is up to date:
   ```sql
   ALTER GIT REPOSITORY {DASHBOARD_DB}.PUBLIC.AVIA_OPS_REPO FETCH;
   ```
   If the Git Repository Stage does not exist in `{DASHBOARD_DB}`, create it (same as Step 5).

4. Invoke the dashboard skill: Read and follow `.cortex/skills/aviation-dashboard/SKILL.md` with `{DASHBOARD_DB}` as the target (`{TARGET_DB}` = `{DASHBOARD_DB}` for the React phase).
   The skill deploys **both** Streamlit and React/SPCS; per-stack version checks determine whether each stack is redeployed.

5. Print summary: "Dashboard check complete for {AIRPORT_NAME} ({IATA}) — Streamlit and React/SPCS." and stop. Include both URLs from the dashboard skill [Final Output](.cortex/skills/aviation-dashboard/SKILL.md#final-output).

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
  ORIGIN = 'https://github.com/Snowflake-Labs/sfguide-aviation-ops-intelligence.git'
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-installer","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
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

6. **Dashboard (Streamlit + React/SPCS)** -- Before deploying, locate any existing dashboard objects across all airport databases:
   ```sql
   SHOW STREAMLITS IN ACCOUNT;
   SHOW SERVICES LIKE 'AVIATION_DASHBOARD_SERVICE' IN ACCOUNT;
   ```
   Filter results for rows where the `comment` column contains `"sf_sit-is-aviation"` and `"oss-aviation-dashboard"`.

   - **If either object already exists** in another airport database: set `{DASHBOARD_DB}` to that database (same host for both stacks). Both dashboards auto-discover all `AIRPORT_XXX` databases — do NOT create duplicates.
   - **If neither exists anywhere**: set `{DASHBOARD_DB}` = `{TARGET_DB}`.

   Then read and follow `.cortex/skills/aviation-dashboard/SKILL.md` with `{DASHBOARD_DB}` as the target (`{TARGET_DB}` = `{DASHBOARD_DB}`).
   The skill always runs Phase A (Streamlit) then attempts Phase B (React/SPCS). Per-stack version checks determine whether each stack is redeployed or skipped. If Docker/Podman, `snow` CLI, or SPCS privileges are missing, Phase B is skipped and installation **still succeeds** with Streamlit only (`{REACT_DEPLOYED}` = false from the dashboard skill).

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

Record the installation end time and compute elapsed minutes: `{ELAPSED} = TIMEDIFF(minute, {START_TIME}, CURRENT_TIMESTAMP())`. Store the row counts from the verification query above as `{GATE_COUNT}`, `{RUNWAY_COUNT}`, `{AIRLINE_COUNT}` for the output summary.

## Stopping Points

- After Step 3: Confirm airport selection with user
- After Step 3.1: If existing airport detected, confirm user choice (skip/update/reinstall)
- After Step 6.1 (base-setup): Verify PROPERTIES_AIRPORT has 1 row
- After Step 6.2 (adsb-ingestion): Verify EAIs and procedures exist
- After Step 7: Verify all tasks are STARTED
- After Step 8: Wait 2-3 minutes, then verify ADSB_DATA has rows

## Examples

### Example 1: Fresh install for San Diego International
User says: "Install airport analytics for San Diego"
Actions:
1. Search Overture Maps for "San Diego" → find SAN / KSAN
2. Confirm airport selection with user
3. Gather config: skip flight schedules, enable TSA, 5-day backfill, default warehouse
4. Run sub-skills in order: base-setup → adsb-ingestion → tsa-throughput → derived-analytics → dashboard (Streamlit + React/SPCS)
5. Resume task DAG, trigger initial data load, verify
Result: `AIRPORT_SAN` database with full analytics pipeline and both dashboard URLs

### Example 2: Add a second airport to existing installation
User says: "Set up LAX — I already have SAN installed"
Actions:
1. Search for "LAX" → find Los Angeles International
2. Create `AIRPORT_LAX` database (new)
3. Existing dashboards in `AIRPORT_SAN` are detected and reused (no duplicate Streamlit or SPCS)
4. Run all sub-skills for LAX
Result: `AIRPORT_LAX` database; dashboards in SAN auto-discover both SAN and LAX

### Example 3: Update dashboard for existing airport
User says: "Update the dashboard for my SAN airport"
Actions:
1. Detect `AIRPORT_SAN` exists → prompt user
2. User selects "Update dashboard only"
3. Fetch latest Git repo, redeploy both Streamlit and React/SPCS dashboards
Result: Both dashboards updated, all data and pipelines untouched

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| Overture Maps query fails | Listing not installed | Step 2 auto-installs it; or manually: `CREATE DATABASE IF NOT EXISTS OVERTURE_MAPS__BASE FROM LISTING GZT0Z4CM1E9KV;` |
| Airport not found | Missing IATA code | Search by ICAO code; some airports lack IATA codes in Overture |
| EAI creation fails | Insufficient privileges | Requires ACCOUNTADMIN or CREATE INTEGRATION privilege |
| Tasks not running | Wrong resume order | Resume in leaf-to-root order; check warehouse is active |
| No ADS-B data after 5 min | Ingestion issue | Check `CALL {TARGET_DB}.{SCHEMA}.PROC_INGEST_ADSB_REALTIME()` manually |
| Backfill stuck | Failed days | Check `HELPER_ADSB_BACKFILL_STATUS` for failed days |
| Airport already installed | Database exists | Step 3.1 detects this automatically; choose update dashboard, skip, or full reinstall |
| Duplicate dashboards | Dashboard in multiple DBs | Step 6.6 auto-discovers existing dashboard and reuses it; remove duplicates via `aviation-cleanup` |

## Output

After Step 9 verification completes, print the following summary to the user (substituting actual values from the installation):

---

**Airport Analytics Platform installed for {AIRPORT_NAME} ({IATA} / {ICAO})**

**Installation time:** {ELAPSED} minutes

**Capabilities installed:**
- Real-time ADS-B aircraft tracking (5-minute refresh from adsb.lol)
- Ground movement analysis (taxi paths, gate dwell times)
- Runway crossing detection
- Daily and hourly traffic analytics
- Airline-level traffic and delay metrics
- Gate utilization and airline dwell analysis
- Flight tracker with historical replay
- Operational KPI dashboard (V_AIR_OPS_DAILY_KPIS)
- {BACKFILL_DAYS}-day historical ADS-B backfill (running in background)
- Flight schedule matching via Aviationstack *(include only if API key was provided; otherwise print: "Flight schedules: skipped (no API key)")*
- TSA checkpoint throughput ingestion *(include only if TSA was enabled; otherwise print: "TSA throughput: skipped")*

**Objects created:**
- Database: `{TARGET_DB}`
- Warehouse: `{WAREHOUSE}`
- Schemas: `PUBLIC`, `TAGS`
- Reference tables: PROPERTIES_AIRPORT (1 row), PROPERTIES_GATES ({GATE_COUNT} gates), PROPERTIES_RUNWAYS ({RUNWAY_COUNT} runways), HELPER_AIRLINE_DIM ({AIRLINE_COUNT} airlines)
- ADS-B pipeline: 3 network rules, 3 external access integrations, ingestion and enrichment stored procedures
- Dynamic Tables: 13 cascading DTs (traffic facts, gate analysis, runway crossings, flight tracker)
- Views: V_AIR_OPS_DAILY_KPIS, HELPER_MONITOR_LAST_REFRESH, HELPER_QA_COUNTS_DAILY
- Task DAG: TASK_INGEST_ADSB (root, 5-min schedule) with child tasks for enrichment, derived analytics, and optional flight schedule / TSA ingestion
- Dashboards: Streamlit app (always); React SPCS service when Phase B deployed (see links below)

---

### Final Step: Open the Dashboards

Use `{DASHBOARD_DB}` from Step 6; default `{DASHBOARD_SCHEMA}` = `PUBLIC`, `{APP_NAME}` = `AIRPORT_ANALYTICS_DASHBOARD`. Follow the dashboard skill [Final Output](.cortex/skills/aviation-dashboard/SKILL.md#final-output) — Streamlit URL always; React/SPCS only when `{REACT_DEPLOYED}` = true.

**Streamlit (Snowsight)** — always:

```sql
SELECT SYSTEM$GET_SNOWSIGHT_HOST() AS host;
```

**React (SPCS public endpoint)** — only if the service exists:

```sql
SHOW SERVICES LIKE 'AVIATION_DASHBOARD_SERVICE' IN {DASHBOARD_DB}.PUBLIC;
```

If a row is returned:

```sql
SHOW ENDPOINTS IN SERVICE {DASHBOARD_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;
SELECT 'https://' || "ingress_url" AS dashboard_url
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'dashboard';
```

**When both stacks deployed** (`{REACT_DEPLOYED}` = true), print:

> **Airport Analytics Dashboards deployed (both stacks):**
>
> **Streamlit (Snowsight):** `https://<host>/api/streamlit/{DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME}`
>
> **React (SPCS):** `https://<ingress_url>` — log in with your Snowflake credentials.

Then open the SPCS URL automatically when running locally:

```bash
open "https://<ingress_url>"
```

**When React/SPCS was skipped** (`{REACT_DEPLOYED}` = false), print the Streamlit URL and the skip reason from the dashboard skill (container runtime, CLI, or privileges).

## Cleanup

To remove all objects created by this installation:

> **Tip:** Use the `aviation-cleanup` skill to auto-discover all tagged objects via COMMENT tracking.
