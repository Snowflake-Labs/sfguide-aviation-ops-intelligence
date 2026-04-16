---
name: derived-analytics
description: "Create the airport analytics Dynamic Table pipeline: gate analysis (6 DTs), traffic facts (4 DTs), runway crossings, flight tracker, monitoring views, operational KPIs, and the full task DAG. Subskill of aviation-installer — must be invoked from the router after ADS-B ingestion completes. Use when: deploying derived analytics layer as part of installation. Do NOT use for: standalone execution, base setup, ADS-B ingestion. Triggers: derived analytics, deploy derived analytics, dynamic tables, setup dynamic tables, gate analysis, runway crossings, runway crossings detection, traffic analysis, airport analytics pipeline, DT pipeline."
depends_on:
  - aviation-installer
  - adsb-ingestion
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# Derived Analytics Pipeline

> **This subskill cannot be run independently.** It must be invoked from the `aviation-installer` router after `adsb-ingestion` (and optionally `flight-schedules`) completes.

Deploys 13 Dynamic Tables, 3 views, monitoring tables, refresh procedures, and operational KPI placeholders. This is the analytics layer that powers all dashboard pages.

## Pipeline Architecture

```
ADSB_DATA (Gold layer from adsb-ingestion)
  + FLIGHT_SCHEDULE (optional, from flight-schedules)
  + PROPERTIES_GATES / PROPERTIES_RUNWAYS (from base-setup)
    |
    v
ADSB_DATA_LOCAL (DT, DOWNSTREAM — bbox-filtered local positions)
    |
    +---> GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS (DT, 1 HOUR)
    |         +---> GATE_ANALYSIS_ADSB_GROUND_POINTS (DT, DOWNSTREAM)
    |         +---> GATE_ANALYSIS_FLIGHT_GATE_TIME (DT, DOWNSTREAM)
    |         +---> GATE_ANALYSIS_GATE_UTIL_DAILY (DT, 1 HOUR)
    |         +---> GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY (DT, 1 HOUR)
    |         +---> GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE (DT, 1 HOUR)
    |
    +---> FLIGHT_TRAFFIC_FACT_ADSB_DAILY (DT, 1 HOUR)
    +---> FLIGHT_TRAFFIC_FACT_ADSB_HOURLY (DT, 1 HOUR)
    +---> FLIGHT_TRACKER_FLIGHT_LIST (DT, 1 HOUR)
    +---> FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY (DT, 1 HOUR)
    +---> FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY (DT, 1 HOUR)
    +---> RUNWAY_CROSSINGS_DETAILED (DT, 1 HOUR)
```

## Prerequisites

- `adsb-ingestion` completed (`ADSB_DATA` table exists, even if empty)
- `PROPERTIES_AIRPORT`, `PROPERTIES_GATES`, `PROPERTIES_RUNWAYS` all exist
- Variables from router: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`, `{IATA}`

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE DYNAMIC TABLE | Schema | Creates 13 Dynamic Tables |
| CREATE VIEW | Schema | Creates 3 operational views |
| CREATE TABLE | Schema | Creates monitoring and placeholder tables |
| CREATE PROCEDURE | Schema | Creates PROC_REFRESH_DERIVED, PROC_REFRESH_ANALYTICS, PROC_SMOKE_CHECK |
| CREATE TASK | Schema | Creates TASK_REFRESH_DERIVED and TASK_REFRESH_ANALYTICS |
| USAGE ON WAREHOUSE | Warehouse | All Dynamic Tables use {WAREHOUSE} |

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| DT_LAG_GATE | 1 HOUR | Refresh lag for gate analysis DTs |
| DT_LAG_TRAFFIC | 1 HOUR | Refresh lag for traffic fact DTs |
| DT_INIT | ON_SCHEDULE | Initialization mode for all DTs |
| CROSSING_MAX_SPEED | 45 | Max knots for runway crossing detection |
| CROSSING_MAX_SEC | 120 | Max seconds for a runway crossing event |
| CROSSING_MAX_DIST_M | 220 | Max meters proximity to runway centroid |

## Error Logging

When any step fails, log to `.cortex/skills/logs/` as `aviation-derived-analytics_{YYYY-MM-DD}_{HH-MM}.md`. If no issues, do not create a log file.

## Workflow

> **Read the `references/` subfiles for complete SQL:**
> - `references/01-adsb-data-local.md` — Foundation DT with VEHICLE_CATEGORY
> - `references/02a-gate-sessions-dts.md` — Gate analysis DTs 1-3 (sessions, ground points, flight gate time)
> - `references/02b-gate-utilization-dts.md` — Gate analysis DTs 4-6 (utilization, airline dwell, flight dwell)
> - `references/03-traffic-dts.md` — 5 traffic fact DTs + flight tracker
> - `references/04-runway-crossings.md` — RUNWAY_CROSSINGS_DETAILED DT
> - `references/05-views-and-tables.md` — HELPER_LANDING_LIVE_TIMETABLE, monitoring tables, placeholders
> - `references/06a-procedures.md` — PROC_REFRESH_DERIVED, PROC_SMOKE_CHECK, PROC_REFRESH_ANALYTICS, PROC_RESUME_OPTIONAL_TASK
> - `references/06b-tasks.md` — Task CREATE statements (no COMMENT on AFTER tasks) + ALTER TAG
> - `references/06c-operations.md` — DT refresh, DT resume, install-time calls, verification
>
> **Execute ALL SQL from each file in order. Do NOT skip or optimize away any queries.**

### Step 1: Create ADSB_DATA_LOCAL Dynamic Table

Foundation DT — filters ADSB_DATA to the airport bounding box using `PROPERTIES_AIRPORT` geometry. All other DTs depend on this.

```sql
CREATE OR REPLACE DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = {WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AS
  SELECT a.*
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA a
  CROSS JOIN {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT p
  WHERE ST_CONTAINS(p.AIRPORT_BBOX, ST_MAKEPOINT(a.LON, a.LAT));
```

### Step 2: Create Gate Analysis Dynamic Tables (6 DTs)

In dependency order:
1. `GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS` — detects continuous on-ground periods per aircraft using LAG-based state change detection
2. `GATE_ANALYSIS_ADSB_GROUND_POINTS` — filters ground-phase ADS-B points with H3 index
3. `GATE_ANALYSIS_FLIGHT_GATE_TIME` — assigns nearest gate to each ground session
4. `GATE_ANALYSIS_GATE_UTIL_DAILY` — daily gate utilization metrics (occupancy %, flights, avg dwell)
5. `GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY` — dwell minutes per gate per airline per day
6. `GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE` — per-flight gate dwell enriched with airline name

### Step 3: Create Traffic Fact Dynamic Tables (4 DTs)

1. `FLIGHT_TRAFFIC_FACT_ADSB_DAILY` — daily arrival/departure counts, on-time rates
2. `FLIGHT_TRAFFIC_FACT_ADSB_HOURLY` — hourly traffic volume by hour-of-day
3. `FLIGHT_TRACKER_FLIGHT_LIST` — deduplicated flight list for tracker page dropdown
4. `FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY` — per-airline daily traffic breakdown
5. `FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY` — per-airline delay analytics (avg, median, p95)

### Step 4: Create Runway Crossings Dynamic Table

`RUNWAY_CROSSINGS_DETAILED` — detects aircraft crossing runway polygons at taxi speeds (speed ≤ 45 kts, duration ≤ 120s, proximity ≤ 220m to runway centroid). Enriched with airline, direction, gate correlation.

### Step 5: Create Monitoring Tables and Views

- `HELPER_LANDING_LIVE_TIMETABLE` — view for live timetable widget (joins ADSB_DATA_LOCAL + FLIGHT_SCHEDULE + gate data)
- `H2H_CONFLICT_PAIRS` — head-to-head conflict placeholder table
- `V_AIR_OPS_TIMELINE` — operational timeline view (placeholder structure)
- `V_AIR_OPS_DAILY_KPIS` — daily KPI view (placeholder structure for Performance page)

### Step 6: Create Refresh Procedures

- `PROC_REFRESH_DERIVED()` — calls `ALTER DYNAMIC TABLE ... REFRESH` on all 13 DTs
- `PROC_REFRESH_ANALYTICS()` — runs QA checks, updates HELPER_QA_COUNTS_DAILY and HELPER_MONITOR_LAST_REFRESH
- `PROC_SMOKE_CHECK(STRING)` — JavaScript procedure that runs validation queries and returns pass/fail summary
- `PROC_RESUME_OPTIONAL_TASK(STRING)` — helper to safely resume a task only if it exists

### Step 7: Create Remaining DAG Tasks

```sql
CREATE TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED
  WAREHOUSE = {WAREHOUSE}
  AFTER {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_REFRESH_DERIVED();

CREATE TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS
  WAREHOUSE = {WAREHOUSE}
  AFTER {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_REFRESH_ANALYTICS();
```

### Step 8: Trigger Initial DT Refresh

```sql
ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL REFRESH;
ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS REFRESH;
ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY REFRESH;
ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.RUNWAY_CROSSINGS_DETAILED REFRESH;
```

### Step 9: Verify Pipeline

```sql
SELECT NAME, SCHEDULING_STATE, DATA_TIMESTAMP, LAST_REFRESH_DETAILS
FROM INFORMATION_SCHEMA.DYNAMIC_TABLES
WHERE TABLE_SCHEMA = '{SCHEMA}'
ORDER BY NAME;
```

Expected: All DTs in `SCHEDULED` or `EXECUTING` state. `DATA_TIMESTAMP` will be NULL until first refresh completes.

## Stopping Points

- After Step 1: Confirm ADSB_DATA_LOCAL is created (`SHOW DYNAMIC TABLES LIKE 'ADSB_DATA_LOCAL' IN {TARGET_DB}.{SCHEMA}`)
- After Step 4: Confirm all 13 DTs exist
- After Step 8: Wait 2–5 minutes, then re-run Step 9 to confirm DATA_TIMESTAMP is populated

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| DT creation fails with "insufficient privileges" | Missing privilege | Ensure role has CREATE DYNAMIC TABLE on schema |
| ADSB_DATA_LOCAL empty after refresh | No source data | Check ADSB_DATA has rows; verify bbox in PROPERTIES_AIRPORT |
| Gate analysis DTs empty | Upstream dependency | GATE_ANALYSIS depends on ADSB_DATA_LOCAL; wait for initial data load |
| RUNWAY_CROSSINGS_DETAILED empty | Missing runway config | Requires PROPERTIES_RUNWAYS to have rows; verify runway detection thresholds |
| DTs stuck in EXECUTING | Warehouse too small | Check warehouse size — large airports may need MEDIUM or LARGE |
| V_AIR_OPS_DAILY_KPIS returns no data | Placeholder views | These are placeholder views; data populates once pipeline has multiple days of history |

## Return to Router

After completing all steps, return to the `aviation-installer` router to proceed with Step 7 (Start Task DAG).

## Cleanup

Derived analytics creates 13 Dynamic Tables and multiple views/procedures. Use the `aviation-cleanup` skill which reads `references/drop-order.sql` to tear down objects in the correct dependency order.

For manual cleanup, suspend tasks first:

```sql
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED SUSPEND;
ALTER TASK IF EXISTS {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS SUSPEND;
```

Then drop objects in reverse dependency order — see `aviation-cleanup` skill's `references/drop-order.sql` for the full sequence.
