---
name: tsa-throughput
description: "Set up TSA checkpoint throughput ingestion: create PDF stages, throughput table, network rule, external access integration, Python PDF-fetch and AI_EXTRACT procedures, and weekly scheduled tasks. Optional subskill of aviation-installer. Use when: configuring TSA throughput data as part of installation. Do NOT use for: standalone execution, ADS-B ingestion (use adsb-ingestion), flight schedules (use flight-schedules). Triggers: TSA throughput, passenger throughput, checkpoint data, TSA pipeline."
depends_on:
  - aviation-installer
  - adsb-ingestion
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# TSA Throughput Setup

> **This subskill cannot be run independently.** It must be invoked from the `aviation-installer` router.
>
> **This subskill is optional** -- only execute if the user wants TSA checkpoint throughput data. No API key is required (public FOIA data).

Creates the TSA checkpoint throughput ingestion pipeline: network rule, EAI, PDF stages, throughput table, Python procedures for PDF download and AI_EXTRACT-based data extraction, and a weekly task DAG (Monday 9am PT).

The pipeline fetches the latest weekly TSA throughput PDF from the TSA FOIA reading room, splits it into single-page PDFs, extracts structured tabular data via `AI_EXTRACT`, and loads it into the `TSA_THROUGHPUT` table. Data covers all US airports; the dashboard filters by airport IATA code at query time.

## Prerequisites

- `adsb-ingestion` completed (provides task DAG root)
- Variables from router: `{TARGET_DB}`, `{SCHEMA}`, `{IATA}`, `{WAREHOUSE}`

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE NETWORK RULE | Database | Creates rule for tsa.gov |
| CREATE INTEGRATION | Account | Creates EAI for tsa.gov HTTPS access |
| CREATE STAGE | Schema | Creates 2 PDF stages (source + pages) |
| CREATE TABLE | Schema | Creates TSA_THROUGHPUT table |
| CREATE PROCEDURE | Schema | Creates 3 ingestion/extraction procedures |
| CREATE TASK | Schema | Creates 2-task DAG (fetch + extract) |

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| CRON_SCHEDULE | `0 9 * * 1 America/Los_Angeles` | Weekly Monday 9am PT |
| TASK_PARENT | `TASK_INGEST_ADSB` | Parent task for DAG chaining |
| EAI_TSA_GOV | `{TARGET_DB}_{SCHEMA}_TSA_GOV_EAI` | External access integration name |

## Friction Log

Report all friction points (errors, warnings, workarounds, race conditions) back to the parent installer. The parent writes the consolidated friction log. If executing standalone, write to `.cortex/skills/logs/aviation-tsa-throughput_{YYYY-MM-DD}_{HH-MM}.md` with the same format described in AGENTS.md.

## Workflow

> **Read the `references/` subfiles for complete SQL:**
> - `references/01-network-stages-tables.md` -- Network rule, EAI, stages, table
> - `references/02-procedures.md` -- All 3 procedures (fetch PDF, find latest, process/extract)
> - `references/03-tasks.md` -- Task definitions + initial fetch/extract calls
>
> **Execute ALL SQL from each file in order. Do NOT skip or optimize away any queries.**

### Step 1: Set Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 2: Create Network Rule and EAI

Create network rule for `tsa.gov:443` (HTTPS) and EAI `{EAI_TSA_GOV}`. No secret needed -- the FOIA reading room is public.

See `references/01-network-stages-tables.md` for full SQL.

### Step 3: Create Stages and Table

- `TSA_PDF_STAGE` -- stores downloaded weekly PDF (SNOWFLAKE_SSE encryption, directory enabled)
- `TSA_PDF_PAGES_STAGE` -- scratch space for 1-page PDF splits (cleaned after extraction)
- `TSA_THROUGHPUT` -- destination table for extracted checkpoint data

See `references/01-network-stages-tables.md` for full SQL.

### Step 4: Create Procedures

- `PROC_FETCH_PDF_TO_STAGE(url, stage_path)` -- generic PDF download utility
- `PROC_FETCH_LATEST_TSA_PDF(stage_path)` -- scrapes FOIA page, finds latest throughput PDF, deduplicates
- `PROC_PROCESS_TSA_PDF(pages_stage, target_table)` -- splits PDF, AI_EXTRACT on each page, bulk insert, cleanup

See `references/02-procedures.md` for full SQL.

### Step 5: Create Tasks

- `TASK_FETCH_TSA_PDF` -- root TSA task, weekly CRON, calls `PROC_FETCH_LATEST_TSA_PDF`
- `TASK_EXTRACT_TSA_PDF` -- child task (AFTER fetch), calls `PROC_PROCESS_TSA_PDF`

See `references/03-tasks.md` for full SQL.

> **Note:** Tasks are created SUSPENDED. The router resumes them after all tasks are ready.

### Step 6: Trigger Initial Fetch and Extract

```sql
CALL {TARGET_DB}.{SCHEMA}.PROC_FETCH_LATEST_TSA_PDF('@{TARGET_DB}.{SCHEMA}.TSA_PDF_STAGE');
CALL {TARGET_DB}.{SCHEMA}.PROC_PROCESS_TSA_PDF('@{TARGET_DB}.{SCHEMA}.TSA_PDF_PAGES_STAGE', '{TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT');
```

### Step 7: Verify

```sql
SELECT COUNT(*) AS TSA_ROWS FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT;
SELECT COUNT(DISTINCT airport_code) AS AIRPORTS FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT;
SELECT COUNT(*) AS LOCAL_ROWS FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT WHERE UPPER(airport_code) = '{IATA}';
```

Expected: > 0 rows overall; local rows depend on whether the airport appears in TSA data.

## Stopping Points

- After Step 2: Confirm EAI exists (`SHOW INTEGRATIONS LIKE '%TSA_GOV%'`)
- After Step 6: Verify TSA_THROUGHPUT has rows

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| EAI creation fails | Insufficient privileges | ACCOUNTADMIN required for CREATE INTEGRATION |
| PROC_FETCH fails with connection error | Network rule misconfigured | Check network rule allows `tsa.gov:443` (HTTPS) |
| No PDF found on FOIA page | Page structure changed | TSA may have changed page structure; check `https://www.tsa.gov/foia/readingroom/` manually |
| AI_EXTRACT returns empty results | Wrong encryption type | Ensure stages use SNOWFLAKE_SSE encryption (required for AI_EXTRACT) |
| 0 rows for airport | Airport not in TSA data | Not all airports appear in TSA data; major US airports should have data |

## Cleanup

All objects carry the `sf_sit-is-aviation` COMMENT tracking tag and are auto-discovered by the `aviation-cleanup` skill. EAIs are matched by name pattern `%TSA_GOV_EAI`.

## Return to Router

After completing all steps, return to the `aviation-installer` router and continue with `derived-analytics`.
