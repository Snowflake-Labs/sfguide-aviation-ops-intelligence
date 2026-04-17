---
name: flight-schedules
description: "Set up Aviationstack flight schedule ingestion: create schedule tables, network rule, external access integration with API key secret, Python ingestion procedure, ETL procedure, and scheduled task. Conditional subskill of aviation-installer — only runs when user provides an Aviationstack API key. Use when: configuring flight schedule data as part of installation with API key. Do NOT use for: standalone execution, ADS-B ingestion (use adsb-ingestion), derived analytics (use derived-analytics). Triggers: flight schedules, Aviationstack setup, schedule ingestion, flight timetable."
depends_on:
  - aviation-installer
  - adsb-ingestion
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# Flight Schedules Setup

> **This subskill cannot be run independently.** It must be invoked from the `aviation-installer` router.
>
> **This subskill is conditional** — only execute if the user provided an Aviationstack API key.

Creates the Aviationstack flight schedule ingestion pipeline: network rule, EAI, API key secret, schedule tables, Python ingestion procedure, ETL procedure, backfill procedures, and the `TASK_FLIGHT_SCHEDULE` task (chained after `TASK_INGEST_ADSB`).

Without this sub-skill, ADS-B tracks are still captured but won't be enriched with airline/route/gate metadata. The dashboard will show aircraft positions but flight details will be unavailable.

## Prerequisites

- `adsb-ingestion` completed
- Aviationstack API key (free tier supports up to 1,000 requests/month)
- Variables from router: `{TARGET_DB}`, `{SCHEMA}`, `{IATA}`, `{ICAO}`, `{WAREHOUSE}`, `{API_KEY}`, `{BACKFILL_DAYS}`

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE NETWORK RULE | Database | Creates rule for api.aviationstack.com |
| CREATE INTEGRATION | Account | Creates EAI for Aviationstack API |
| CREATE SECRET | Schema | Stores API key securely |
| CREATE PROCEDURE | Schema | Creates 5 ingestion/ETL procedures |
| CREATE TASK | Schema | Creates TASK_FLIGHT_SCHEDULE |

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| API_ENDPOINT | `http://api.aviationstack.com/v1/flights` | Aviationstack REST endpoint |
| BACKFILL_DAYS | 5 | Days of schedule history to backfill |
| TASK_PARENT | `TASK_INGEST_ADSB` | Parent task for DAG chaining |

## Friction Logging

Report all friction points (errors, warnings, workarounds, race conditions) back to the parent installer using the F1/F2/F3 format from `.cortex/skills/logs/README.md`. The parent writes the consolidated friction log. If executing standalone, write to `.cortex/skills/logs/friction-log_{YYYY-MM-DD}_{HH-MM}.md`.

## Workflow

> **Read the `references/` subfiles for complete SQL:**
> - `references/01-network-and-tables.md` — Network rule, EAI, secret
> - `references/02-procedures.md` — All 5 ingestion/ETL/backfill procedures
> - `references/03-task-and-ops.md` — Task definition + initial backfill call
>
> **Execute ALL SQL from each file in order. Do NOT skip or optimize away any queries.**

### Step 0: Set Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 1: Create Network Rule and EAI

```sql
CREATE OR REPLACE NETWORK RULE {TARGET_DB}.{SCHEMA}.{SCHEMA}_aviationstack_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.aviationstack.com:80')
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

CREATE OR REPLACE SECRET {TARGET_DB}.{SCHEMA}.aviationstack_key
  TYPE = GENERIC_STRING
  SECRET_STRING = '{API_KEY}'
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

Create EAI `{EAI_AVIATIONSTACK}` (e.g. `AIRPORT_SAN_PUBLIC_AVIATIONSTACK_EAI`) referencing the network rule and secret.

### Step 2: Create Schedule Tables

- `HELPER_FLIGHT_SCHEDULE_RAW` — raw JSON responses from Aviationstack (Bronze layer), one row per API call
- `FLIGHT_SCHEDULE` — canonical flight schedule (Silver layer) with departure/arrival times, airline, route, status

### Step 3: Create Ingestion Procedures

- `PROC_INGEST_FLIGHT_SCHEDULE(VARCHAR, VARCHAR)` — Python procedure that calls Aviationstack API for `{IATA}` airport, inserts raw JSON into HELPER_FLIGHT_SCHEDULE_RAW
- `PROC_ETL_SCHEDULE_TO_FLIGHT_SCHEDULE()` — SQL procedure that parses raw JSON → FLIGHT_SCHEDULE (deduplication by flight_date + flight_iata)
- `PROC_BACKFILL_FLIGHT_SCHEDULE(INT)` — backfills N days of schedule history
- `PROC_BACKFILL_FLIGHT_SCHEDULE_WINDOW(INT, INT)` — backfills a specific date range (days ago start/end)
- `PROC_FLIGHT_SCHEDULE_INGEST_AND_ETL()` — orchestrates ingest + ETL in sequence

### Step 4: Create Task

```sql
CREATE TASK {TARGET_DB}.{SCHEMA}.TASK_FLIGHT_SCHEDULE
  WAREHOUSE = {WAREHOUSE}
  AFTER {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_FLIGHT_SCHEDULE_INGEST_AND_ETL();
```

> **Note:** Do NOT resume this task here. The router uses `PROC_RESUME_OPTIONAL_TASK` to resume it after all tasks are ready.

### Step 5: Trigger Initial Backfill

```sql
CALL {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_FLIGHT_SCHEDULE({BACKFILL_DAYS});
```

### Step 6: Verify

```sql
SELECT COUNT(*) AS RAW_ROWS FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW;
SELECT COUNT(*) AS SCHEDULE_ROWS FROM {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE;
```

Expected: > 0 rows if API key is valid and airport has scheduled service.

## Stopping Points

- After Step 1: Confirm EAI exists (`SHOW INTEGRATIONS LIKE '%AVIATIONSTACK%'`)
- After Step 5: Verify FLIGHT_SCHEDULE has rows (`SELECT COUNT(*) FROM FLIGHT_SCHEDULE`)

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| EAI creation fails | Insufficient privileges | ACCOUNTADMIN required for CREATE INTEGRATION |
| PROC_INGEST fails with 403 | Invalid API key | API key may be invalid or rate-limited; check Aviationstack dashboard |
| FLIGHT_SCHEDULE empty after backfill | Limited coverage | Some airports have limited Aviationstack coverage; try major IATA codes (SAN, LAX, JFK) |
| HTTP 80 blocked | Wrong port in network rule | Check network rule uses PORT 80 not 443 (Aviationstack uses plain HTTP) |
| Secret value redacted in logs | Expected behavior | Installer masks SECRET_STRING literals in UI display |

## Return to Router

After completing all steps, return to the `aviation-installer` router and continue with `derived-analytics`.

## Cleanup

Use the `aviation-cleanup` skill for automated tag-based teardown. Manual cleanup:

```sql
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_FLIGHT_SCHEDULE SUSPEND;

DROP TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_FLIGHT_SCHEDULE;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE;
DROP TABLE IF EXISTS {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW;
DROP PROCEDURE IF EXISTS {TARGET_DB}.{SCHEMA}.PROC_FETCH_FLIGHT_SCHEDULE();
DROP PROCEDURE IF EXISTS {TARGET_DB}.{SCHEMA}.PROC_FLIGHT_SCHEDULE_INGEST_AND_ETL();
```
