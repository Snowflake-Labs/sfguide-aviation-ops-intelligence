---
name: adsb-ingestion
description: "Set up real-time ADS-B aircraft position ingestion from adsb.lol: create tables, network rules, external access integrations, Python ingestion procedures, flight-matching enrichment, scheduled tasks, and optional historical backfill. Subskill of aviation-installer — must be invoked from the router, not independently. Use when: configuring ADS-B data pipeline as part of installation. Do NOT use for: standalone execution, flight schedules (use flight-schedules), derived analytics (use derived-analytics). Triggers: ADS-B ingestion, aircraft tracking setup, adsb.lol, realtime aircraft data."
depends_on:
  - aviation-installer
  - base-setup
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# ADS-B Ingestion Setup

> **This subskill cannot be run independently.** It must be invoked from the `aviation-installer` router after `base-setup` completes.

Creates all ADS-B ingestion infrastructure: network rules, external access integrations for adsb.lol and GitHub APIs, ADS-B tables, Python ingestion procedures (realtime + ETL + enrichment), aircraft metadata enrichment, historical backfill procedures, and the core task chain (`TASK_INGEST_ADSB` → `TASK_ENRICH_ADSB`).

## Prerequisites

- `base-setup` completed (`PROPERTIES_AIRPORT` exists with 1 row)
- ACCOUNTADMIN role (required for CREATE INTEGRATION and CREATE NETWORK RULE)
- Variables from router: `{TARGET_DB}`, `{SCHEMA}`, `{IATA}`, `{ICAO}`, `{WAREHOUSE}`, `{CENTER_LAT}`, `{CENTER_LON}`, `{BACKFILL_DAYS}`, `{GIT_REPO_STAGE_BASE}`

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE NETWORK RULE | Database | Creates rules for adsb.lol and GitHub APIs |
| CREATE INTEGRATION | Account | Creates external access integrations |
| CREATE SECRET | Schema | Creates secrets for API keys |
| CREATE PROCEDURE | Schema | Creates 15+ ingestion/ETL procedures |
| CREATE TASK | Schema | Creates TASK_INGEST_ADSB and TASK_ENRICH_ADSB |
| EXECUTE TASK | Account | Enables task execution |

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| API_URL | `https://api.adsb.lol/v2/point/{LAT}/{LON}/27` | ADS-B endpoint (27nm radius) |
| RADIUS_NM | 27 | Capture radius in nautical miles (~50km) |
| BACKFILL_DAYS | 5 | Days of historical ADS-B to backfill |
| TASK_SCHEDULE | `CRON '30 1 * * * UTC'` | Daily ingestion schedule |

## Friction Logging

Report all friction points (errors, warnings, workarounds, race conditions) back to the parent installer using the F1/F2/F3 format from `.cortex/skills/logs/README.md`. The parent writes the consolidated friction log. If executing standalone, write to `.cortex/skills/logs/friction-log_{YYYY-MM-DD}_{HH-MM}.md`.

## Workflow

> **Read the `references/` subfiles for complete SQL:**
> - `references/01-network-rules-eai.md` — Network rules and EAIs
> - `references/02-tables.md` — All tables (ADSB_DATA, helpers, flight matching)
> - `references/03a-schedule-enrichment.md` — PROC_ENRICH_ADSB_WITH_SCHEDULE (flight-schedule matching)
> - `references/03b-aircraft-meta-enrichment.md` — PROC_ENRICH_AIRCRAFT_META + backfill + task
> - `references/04-ingestion-procedures.md` — Realtime ingestion procedures
> - `references/05-tasks-and-dag.md` — Task DAG definitions
> - `references/06a-backfill-infra.md` — Backfill stage, tables
> - `references/06b-backfill-download.md` — PROC_DOWNLOAD_TO_STAGE
> - `references/06c-backfill-extract.md` — PROC_EXTRACT_TO_NDJSON
> - `references/06d-backfill-load-filter.md` — PROC_LOAD_NDJSON_TO_INTERIM + PROC_FILTER_AND_INSERT_SQL
> - `references/06e-backfill-orchestrators.md` — PROC_PROCESS_FROM_STAGE, PROC_BACKFILL_ADSB_HISTORY, PROC_START_BACKFILL_HISTORY
> - `references/06f-backfill-retry-cleanup.md` — Retry wrappers, cleanup, tags, usage reference
>
> **Execute ALL SQL from each file. Do NOT skip or optimize away any queries.**

### Step 0: Set Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 1: Create Network Rules

Create 2 network rules in `{TARGET_DB}.{SCHEMA}`:
- `{SCHEMA}_adsb_lol_rule` — allows api.adsb.lol:443
- `{SCHEMA}_github_rule` — allows api.github.com, github.com, objects.githubusercontent.com, release-assets.githubusercontent.com

### Step 2: Create External Access Integrations

Create 2 EAIs (account-level objects, require ACCOUNTADMIN):
- `{EAI_ADSB_LOL}` (e.g., `AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI`) — for realtime position fetch
- `{EAI_GITHUB}` (e.g., `AIRPORT_SAN_PUBLIC_GITHUB_EAI`) — for historical ADS-B archive download

> **Note:** EAI names are derived by replacing non-alphanumeric characters in `{TARGET_DB}_{SCHEMA}` with underscores.

### Step 3: Create ADS-B Tables

Create core tables:
- `HELPER_ADSB_LOL_RAW` — raw JSON responses from adsb.lol (Bronze layer)
- `HELPER_AIRCRAFT_META` — aircraft type and description lookup (populated by enrichment procedure)
- `ADSB_DATA` — canonical ADS-B position records (Gold layer) with flight matching fields

### Step 4: Create Staging Infrastructure

Create:
- `ADSB_HISTORY_STAGE` — internal stage for historical ADS-B TAR archives
- `FF_AIRLINES_CSV` — already created in base-setup (skip if exists)
- `HELPER_ADSB_BACKFILL_STATUS` — backfill tracking per-day status table
- `HELPER_ADSB_HISTORY_INTERIM` — interim table for raw JSON from backfill

### Step 5: Create Ingestion Procedures

Create Python stored procedures:
- `PROC_INGEST_ADSB_REALTIME()` — fetches live positions from adsb.lol API, inserts into HELPER_ADSB_LOL_RAW
- `PROC_ETL_ADSB_TO_DATA()` — transforms Bronze → Gold (ADSB_DATA), deduplicates by icao24+timestamp
- `PROC_DEDUP_ADSB_DATA(INT)` — removes duplicate position records older than N days
- `PROC_ADSB_INGEST_AND_ETL()` — orchestrates PROC_INGEST_ADSB_REALTIME + PROC_ETL_ADSB_TO_DATA

### Step 6: Create Flight Enrichment Procedures

Create procedures for matching ADS-B tracks to flight schedules:
- `PROC_ENRICH_ADSB_WITH_SCHEDULE(INT)` — matches ADSB_DATA tracks to FLIGHT_SCHEDULE by callsign, time, and O/D proximity; populates HELPER_FLIGHT_LEG, HELPER_FLIGHT_MATCH_CANDIDATES, HELPER_FLIGHT_MATCH_RESULT
- Helper tables: `HELPER_FLIGHT_LEG`, `HELPER_FLIGHT_MATCH_CANDIDATES`, `HELPER_FLIGHT_MATCH_RESULT`, `HELPER_RECURRING_CALLSIGN_PRIOR`

### Step 7: Create Aircraft Metadata Procedures

- `PROC_ENRICH_AIRCRAFT_META(INT, INT, INT)` — Python procedure that fetches aircraft type/description from GitHub aircraft database, populates HELPER_AIRCRAFT_META
- `PROC_BACKFILL_ADSB_AIRCRAFT_DESC(INT)` — backfills description field on existing ADSB_DATA rows
- `PROC_ENRICH_AIRCRAFT_META_AND_BACKFILL()` — orchestrates both

### Step 8: Create Historical Backfill Procedures

Python procedures for downloading globe_history archives from adsb.lol GitHub releases:
- `PROC_DOWNLOAD_TO_STAGE(VARCHAR)` — downloads TAR.GZ to ADSB_HISTORY_STAGE
- `PROC_EXTRACT_TO_NDJSON(VARCHAR)` — extracts NDJSON from TAR in stage
- `PROC_LOAD_NDJSON_TO_INTERIM(VARCHAR)` — loads NDJSON into HELPER_ADSB_HISTORY_INTERIM
- `PROC_FILTER_AND_INSERT_SQL(VARCHAR)` — filters to airport bbox and inserts into ADSB_DATA
- `PROC_PROCESS_FROM_STAGE(VARCHAR)` — orchestrates extract→load→filter for one day
- `PROC_BACKFILL_ADSB_HISTORY()` — main backfill loop, iterates over pending days
- `PROC_RUN_BACKFILL_ONCE()` — wrapper that runs backfill once then suspends TASK_ADSB_BACKFILL_ONCE
- `PROC_RUN_BACKFILL_RETRY_UTC()` — retry wrapper for failed days
- `PROC_START_BACKFILL_HISTORY()` — seeds HELPER_ADSB_BACKFILL_STATUS and creates/resumes TASK_ADSB_BACKFILL_ONCE
- `PROC_START_BACKFILL_RETRY_UTC()` — creates/resumes TASK_ADSB_BACKFILL_RETRY
- `PROC_CLEANUP_STAGE(VARCHAR)` — removes processed files from stage

### Step 9: Create Monitoring and Audit Tables

- `HELPER_INSTALL_AUDIT` — installation record (already created in base-setup; insert row here if not done)
- `HELPER_MONITOR_LAST_REFRESH` — tracks last refresh timestamps per object
- `HELPER_QA_COUNTS_DAILY` — QA row counts per table per day
- `HELPER_INGEST_AUDIT` — per-run ingest audit log

### Step 10: Create Core Tasks

```sql
CREATE TASK {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB
  WAREHOUSE = {WAREHOUSE}
  SCHEDULE = 'USING CRON 30 1 * * * UTC'
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_ADSB_INGEST_AND_ETL();

CREATE TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB
  WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AFTER {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(1);

CREATE TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_AIRCRAFT_META
  WAREHOUSE = {WAREHOUSE}
  SCHEDULE = 'USING CRON 15 3 * * * UTC'
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_ENRICH_AIRCRAFT_META_AND_BACKFILL();
```

> **Note:** Do NOT resume tasks here. The router resumes all tasks together in Step 5 after all sub-skills complete.

### Step 11: Verify

```sql
SELECT 'HELPER_ADSB_LOL_RAW' AS OBJ, COUNT(*) AS CNT FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW
UNION ALL SELECT 'ADSB_DATA', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
UNION ALL SELECT 'HELPER_AIRCRAFT_META', COUNT(*) FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRCRAFT_META;
```

Expected: 0 rows (data arrives after tasks run). Verify objects exist by checking `INFORMATION_SCHEMA.PROCEDURES`.

## Stopping Points

- After Step 2: Confirm all 2 EAIs exist (`SHOW INTEGRATIONS LIKE '%{IATA}%'`)
- After Step 5: Test ingestion manually: `CALL {TARGET_DB}.{SCHEMA}.PROC_INGEST_ADSB_REALTIME()`
- After Step 10: Confirm tasks exist (SUSPENDED state expected): `SHOW TASKS IN {TARGET_DB}.{SCHEMA}`

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| EAI creation fails | Insufficient privileges | ACCOUNTADMIN required; check role with `SELECT CURRENT_ROLE()` |
| PROC_INGEST_ADSB_REALTIME fails | EAI misconfigured | Test with `CALL PROC_INGEST_ADSB_REALTIME()` and check error |
| Python packages not installing | Anaconda agreement missing | Run `CALL SYSTEM$ACCEPT_LEGAL_TERMS('ANACONDA')` with ACCOUNTADMIN |
| No data after 10 min | Incorrect bounding box | Verify airport bounding box in PROPERTIES_AIRPORT; check API endpoint coverage |
| Backfill procedures missing | Package agreement | Python procedures require ANACONDA_PACKAGE_AGREEMENT on account |

## Return to Router

After completing all steps, return to the `aviation-installer` router. If an API key was provided, continue with `flight-schedules`. Otherwise, continue with `derived-analytics`.

## Cleanup

Use the `aviation-cleanup` skill for automated tag-based teardown. Manual cleanup:

```sql
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB SUSPEND;
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB SUSPEND;
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ENRICH_AIRCRAFT_META SUSPEND;
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_ONCE SUSPEND;
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_RETRY SUSPEND;

DROP TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB;
DROP TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB;
DROP TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ENRICH_AIRCRAFT_META;
DROP TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_ONCE;
DROP TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_RETRY;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.ADSB_DATA;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW;
```
