# Aviation Ops Intelligence - Installation Friction Log
**Airport:** San Diego International Airport (SAN / KSAN)
**Date:** 2026-04-15
**Account:** wgb26798
**Role:** ACCOUNTADMIN

## Configuration
| Parameter | Value |
|-----------|-------|
| Target Database | AIRPORT_SAN |
| Schema | PUBLIC |
| Warehouse | AVIA_SAN_WH (XSMALL) |
| Aviationstack Key | None (skipped flight-schedules) |
| Backfill Days | 5 |
| Overture Maps ID | 6d5bdf11-2e2b-3090-b7bb-5494e47d6ba3 |

## Installation Summary

| Step | Sub-skill | Status | Duration |
|------|-----------|--------|----------|
| 1 | Set query tag | OK | <1s |
| 2 | Install Overture Maps | OK | ~10s |
| 3 | Search airport | OK | ~15s |
| 4 | base-setup | OK | ~2min |
| 5 | adsb-ingestion | OK | ~5min |
| 6 | tsa-throughput | OK | ~2min |
| 7 | derived-analytics | OK | ~3min |
| 8 | Dashboard | SKIPPED (no Git repo stage) |
| 9 | Task DAG + backfill | OK | ~1min |

## Objects Created

| Category | Count |
|----------|-------|
| Database | 1 (AIRPORT_SAN) |
| Schemas | 2 (PUBLIC, TAGS) |
| Tables | 35 |
| Dynamic Tables | 13 |
| Views | 2 |
| Procedures | 23 |
| Functions (UDFs) | 3 |
| Tasks | 8 (all STARTED) |
| Tags | 2 |
| Stages | 3 |
| Network Rules | 3 |
| External Access Integrations | 3 |

## Initial Data

| Table | Rows |
|-------|------|
| PROPERTIES_AIRPORT | 1 |
| PROPERTIES_INFRASTRUCTURE | 750 |
| PROPERTIES_GATES | 51 |
| PROPERTIES_RUNWAYS | 1 |
| HELPER_AIRLINE_DIM | 1,222 |
| ADSB_DATA (initial ingest) | 70 |

## Friction Points

### 1. Overture Maps Not Pre-installed (LOW)
**Issue:** `OVERTURE_MAPS__BASE` database was not present. Had to install from marketplace listing using `CREATE DATABASE FROM LISTING`.
**Impact:** Added ~10s to installation.
**Suggestion:** The skill docs mention checking/auto-installing from listing `GZT0Z4CM1E9KV` -- this worked correctly via `CREATE DATABASE IF NOT EXISTS ... FROM LISTING 'GZT0Z4CM1E9KV'`.

### 2. Git Repository Stage Creation Failed (HIGH)
**Issue:** Creating a Git Repository stage with `API_INTEGRATION = ''` (empty string) fails with compilation error. The skill references `@AIRPORT_SAN.PUBLIC.AVIA_OPS_REPO/branches/main` for loading `airlines.csv` and deploying the Streamlit dashboard.
**Error:** `SQL compilation error: Invalid value '' for parameter 'API_INTEGRATION'`
**Workaround:** Loaded airlines.csv via a temporary internal stage (`PUT` from local filesystem + `COPY INTO`). Dashboard deployment was skipped entirely.
**Impact:** Dashboard not deployed. Manual intervention needed to create a proper API integration or use an alternative file loading method.
**Suggestion:** The skill should either (a) provide instructions for creating a Git API integration first, or (b) embed airlines.csv as a Snowflake literal / VALUES statement, or (c) use a public URL download approach.

### 3. Task Resume Order Matters (LOW)
**Issue:** Resuming `TASK_EXTRACT_TSA_PDF` after its root task `TASK_FETCH_TSA_PDF` was already resumed caused `Unable to update graph` error. Had to suspend root, resume child, then resume root.
**Impact:** Minor -- easily recovered with suspend/resume cycle.
**Suggestion:** The skill docs already mention leaf-to-root resume order, but this was easy to forget for the TSA tasks which have a separate DAG from the main ADS-B chain.

### 4. FLIGHT_SCHEDULE Stub Schema Mismatch (LOW)
**Issue:** The derived-analytics `01-adsb-data-local.md` reference creates `FLIGHT_SCHEDULE` with specific columns, but the enrichment procedure `PROC_ENRICH_ADSB_WITH_SCHEDULE` references additional columns like `FLIGHT_KEY` and `AIRCRAFT_REGISTRATION` that aren't in the stub definition.
**Workaround:** Added the missing columns to the stub table at creation time.
**Suggestion:** Align the stub table definition with all columns referenced by downstream procedures.

### 5. HELPER_INSTALL_AUDIT Schema Inconsistency (LOW)
**Issue:** `base-setup` creates `HELPER_INSTALL_AUDIT` with columns (INSTALL_TS, INSTALLER_VERSION, ...) but `derived-analytics/01-adsb-data-local.md` tries to create it with different columns (installed_at, installer_git_sha, ...). The CREATE IF NOT EXISTS succeeds silently but the INSERT uses the wrong column names.
**Workaround:** Adapted the INSERT to match the existing schema.
**Suggestion:** Standardize HELPER_INSTALL_AUDIT schema across sub-skills.

### 6. Dynamic Tables All Use FULL Refresh Mode (INFO)
**Issue:** All 13 Dynamic Tables were auto-assigned FULL refresh mode (not incremental) due to complex queries, LIMIT clauses, and FULL-mode upstream dependencies.
**Impact:** Higher warehouse costs for large datasets. Acceptable for XSMALL warehouse during initial setup.
**Suggestion:** Consider adding REFRESH_MODE=INCREMENTAL hints where possible, or document expected refresh modes.

### 7. Dashboard Deployment Blocked (HIGH)
**Issue:** Without a Git Repository stage, the Streamlit dashboard cannot be deployed via `CREATE OR REPLACE STREAMLIT ... ROOT_LOCATION = '@AIRPORT_SAN.PUBLIC.AVIA_OPS_REPO/...'`.
**Status:** Dashboard deployment SKIPPED.
**Suggestion:** Provide an alternative deployment method (e.g., upload files to an internal stage, or use `PUT` + `CREATE STREAMLIT` from internal stage).

## Backfill Status
- `TASK_ADSB_BACKFILL_ONCE` created and STARTED (runs every 1 minute, self-suspends after completion)
- Will download and process 5 days of historical ADS-B data from adsb.lol GitHub releases
- Monitor: `SELECT * FROM AIRPORT_SAN.PUBLIC.HELPER_ADSB_BACKFILL_STATUS`

## Verification Checklist
- [x] PROPERTIES_AIRPORT: 1 row (SAN/KSAN, America/Los_Angeles)
- [x] PROPERTIES_INFRASTRUCTURE: 750 rows
- [x] PROPERTIES_GATES: 51 gates
- [x] PROPERTIES_RUNWAYS: 1 runway polygon
- [x] HELPER_AIRLINE_DIM: 1,222 airlines
- [x] ADSB_DATA: 70 initial positions
- [x] 13 Dynamic Tables: All ACTIVE
- [x] 8 Tasks: All STARTED
- [x] 3 EAIs: All ENABLED
- [ ] Dashboard: NOT DEPLOYED (Git repo stage unavailable)
- [ ] TSA initial fetch: NOT TRIGGERED (skipped due to time)
