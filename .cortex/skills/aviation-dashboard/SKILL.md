---
name: aviation-dashboard
description: "Deploy the Airport Analytics Streamlit-in-Snowflake dashboard: upload app files from Git repo stage, create the Streamlit object, and verify the app is accessible. Use when: deploying dashboard, setting up airport analytics UI, installing flight tracker, monitoring page. Do NOT use for: installing airport data pipeline (use aviation-installer), cleaning up objects (use aviation-cleanup). Triggers: deploy dashboard, aviation dashboard, airport analytics UI, streamlit airport, install dashboard, flight tracker app."
depends_on:
  - aviation-installer
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# Deploy Airport Analytics Dashboard

Deploys the multi-page Streamlit-in-Snowflake dashboard that provides real-time and historical analytics for installed airports. The dashboard auto-discovers all `AIRPORT_XXX` databases and shows a multi-airport selector in the sidebar.

## Pages

| Page | File | Key Data Sources |
|------|------|-----------------|
| Live View | `.0_Live_View.py` | ADSB_DATA_LOCAL, FLIGHT_SCHEDULE, PROPERTIES_GATES |
| Flight Tracker | `1_Flight_Tracker.py` | ADSB_DATA_LOCAL, FLIGHT_SCHEDULE, PROPERTIES_GATES |
| Ground Activity | `2_Ground_Activity.py` | ADSB_DATA_LOCAL, PROPERTIES_INFRASTRUCTURE |
| Runway Crossings | `3_Runway_Crossings.py` | RUNWAY_CROSSINGS_DETAILED, PROPERTIES_RUNWAYS |
| Traffic Analysis | `4_Traffic_Analysis.py` | FLIGHT_TRAFFIC_FACT_*, FLIGHT_SCHEDULE, HELPER_AIRLINE_DIM |
| Gate Analysis | `5_Gate_Analysis.py` | GATE_ANALYSIS_*, PROPERTIES_GATES |
| Monitoring | `7_Monitoring.py` | HELPER_MONITOR_*, HELPER_QA_*, HELPER_INGEST_AUDIT |
| Performance | `8_Performance.py` | V_AIR_OPS_DAILY_KPIS |

## Prerequisites

1. At least one airport installed via `aviation-installer` (at minimum `base-setup` and `derived-analytics` completed)
2. Dashboard files available in Git repo stage (`{GIT_REPO_STAGE_BASE}`)
3. A Snowflake database and schema to host the Streamlit app
4. Warehouse for Streamlit execution

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE STREAMLIT | Schema | Creates the Streamlit app object |
| CREATE STAGE | Schema | Creates stage for app files (if not using repo stage directly) |
| USAGE ON DATABASE AIRPORT_XXX | Each airport database | Dashboard reads airport analytics data |
| SELECT ON TABLES/VIEWS | Airport schemas | Reads all dashboard data sources |

> **Note:** Grant PUBLIC role USAGE on each AIRPORT_XXX database and schema — the installer does this automatically, but verify if deploying dashboard to a different role context.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| DASHBOARD_DB | AVIA_INSTALLER | Database to host the Streamlit app |
| DASHBOARD_SCHEMA | PUBLIC | Schema to host the Streamlit app |
| APP_NAME | AIRPORT_ANALYTICS_DASHBOARD | Streamlit object name |
| GIT_REPO_STAGE | `@AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main` | Source files |
| WAREHOUSE | (current warehouse) | Warehouse for app execution |

## Error Logging

When any step fails, log to `logs/` as `aviation-dashboard_{YYYY-MM-DD}_{HH-MM}.md`. If no issues, do not create a log file.

## Workflow

### Step 1: Set Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 2: Verify Prerequisite Airport Data

```sql
SHOW DATABASES LIKE 'AIRPORT_%';
```

Confirm at least one `AIRPORT_XXX` database exists. If none, run `aviation-installer` first.

Quick check that data is flowing:
```sql
SELECT TABLE_SCHEMA, TABLE_NAME, ROW_COUNT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_CATALOG LIKE 'AIRPORT_%'
  AND TABLE_NAME IN ('PROPERTIES_AIRPORT','ADSB_DATA','ADSB_DATA_LOCAL')
ORDER BY TABLE_CATALOG, TABLE_NAME;
```

### Step 3: Create Dashboard Host Database and Schema (if needed)

```sql
CREATE DATABASE IF NOT EXISTS {DASHBOARD_DB}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

CREATE SCHEMA IF NOT EXISTS {DASHBOARD_DB}.{DASHBOARD_SCHEMA}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

> **Note:** If deploying into an existing database (e.g., alongside the installer app), skip this step.

### Step 4: Create or Replace Streamlit App

```sql
CREATE OR REPLACE STREAMLIT {DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME}
  ROOT_LOCATION = '{GIT_REPO_STAGE_BASE}/dashboard'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 5: Verify App

```sql
SHOW STREAMLITS LIKE '{APP_NAME}' IN {DASHBOARD_DB}.{DASHBOARD_SCHEMA};
```

Retrieve the URL:
```sql
SELECT SYSTEM$GET_SNOWSIGHT_HOST();
```

The app URL follows: `https://<account>.snowflakecomputing.com/api/streamlit/{DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME}`

## Dashboard Schema Contract

The dashboard queries these tables and views per airport. All objects live in `AIRPORT_{IATA}.PUBLIC`.

### Live View page

| Object | Columns Used |
|--------|-------------|
| `ADSB_DATA_LOCAL` | ICAO24, CALLSIGN, LAT, LON, ALT_BARO, HEADING, SPEED, TIMESTAMP |
| `FLIGHT_SCHEDULE` | FLIGHT_IATA, AIRLINE_IATA, DEP_IATA, ARR_IATA, STATUS, SCHEDULED_DEP, SCHEDULED_ARR |
| `PROPERTIES_GATES` | GATE_REF, GEOMETRY (ST_X/ST_Y for map) |

### Flight Tracker page

| Object | Columns Used |
|--------|-------------|
| `ADSB_DATA_LOCAL` | ICAO24, CALLSIGN, LAT, LON, ALT_BARO, SPEED, TIMESTAMP, FLIGHT_IATA, AIRLINE_IATA |
| `FLIGHT_SCHEDULE` | FLIGHT_IATA, SCHEDULED_DEP, ACTUAL_DEP, STATUS, DEP_IATA, ARR_IATA |
| `FLIGHT_TRACKER_FLIGHT_LIST` | FLIGHT_IATA, ICAO24, FLIGHT_DATE (for dropdown) |
| `GATE_ANALYSIS_FLIGHT_GATE_TIME` | FLIGHT_IATA, GATE_REF, GATE_DWELL_MINUTES |

### Ground Activity page

| Object | Columns Used |
|--------|-------------|
| `ADSB_DATA_LOCAL` | LAT, LON, ALT_BARO, SPEED, CATEGORY, TIMESTAMP |
| `PROPERTIES_INFRASTRUCTURE` | GEOMETRY, CLASS, SUBTYPE (for map overlay) |

### Runway Crossings page

| Object | Columns Used |
|--------|-------------|
| `RUNWAY_CROSSINGS_DETAILED` | ICAO24, CALLSIGN, AIRLINE_IATA, RUNWAY_ID, CROSSING_TIME, SPEED_KTS, DIRECTION, GATE_REF |
| `PROPERTIES_RUNWAYS` | RUNWAY_ID, GEOMETRY, HEADING |

### Traffic Analysis page

| Object | Columns Used |
|--------|-------------|
| `FLIGHT_TRAFFIC_FACT_ADSB_DAILY` | FLIGHT_DATE, ARR_COUNT, DEP_COUNT, ON_TIME_PCT |
| `FLIGHT_TRAFFIC_FACT_ADSB_HOURLY` | HOUR_OF_DAY, DAY_OF_WEEK, FLIGHT_COUNT |
| `FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY` | AIRLINE_IATA, FLIGHT_DATE, FLIGHT_COUNT |
| `FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY` | AIRLINE_IATA, AVG_DELAY_MIN, MEDIAN_DELAY_MIN, P95_DELAY_MIN |
| `HELPER_AIRLINE_DIM` | IATA_CODE, AIRLINE_NAME (for display labels) |

### Gate Analysis page

| Object | Columns Used |
|--------|-------------|
| `GATE_ANALYSIS_GATE_UTIL_DAILY` | GATE_REF, FLIGHT_DATE, TOTAL_DWELL_MIN, FLIGHT_COUNT, OCCUPANCY_PCT |
| `GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY` | GATE_REF, AIRLINE_IATA, DWELL_MINUTES, FLIGHT_DATE |
| `GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE` | FLIGHT_IATA, GATE_REF, AIRLINE_NAME, DWELL_MINUTES, FLIGHT_DATE |

### Monitoring page

| Object | Columns Used |
|--------|-------------|
| `HELPER_MONITOR_LAST_REFRESH` | OBJECT_NAME, LAST_REFRESH_UTC, ROW_COUNT |
| `HELPER_QA_COUNTS_DAILY` | TABLE_NAME, CHECK_DATE, ROW_COUNT, EXPECTED_MIN |
| `HELPER_INGEST_AUDIT` | RUN_TS, ROWS_INSERTED, ROWS_DEDUPLICATED, STATUS |

### Performance page

| Object | Columns Used |
|--------|-------------|
| `V_AIR_OPS_DAILY_KPIS` | FLIGHT_DATE, MEDIAN_TAXI_IN_MIN, MEDIAN_TAXI_OUT_MIN, ON_TIME_ARR_PCT, ON_TIME_DEP_PCT |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| App shows "No airport databases found" | Run `aviation-installer` first; verify AIRPORT_XXX databases exist |
| Streamlit creation fails | Check role has CREATE STREAMLIT privilege on target schema |
| Pages show empty charts | Data pipelines may still be initializing; wait 5–10 min after install |
| Map layers not rendering | Check PROPERTIES_INFRASTRUCTURE has rows for the airport |
| Multi-airport selector missing airports | Verify each AIRPORT_XXX database has PROPERTIES_AIRPORT with 1 row |
| Performance page always empty | V_AIR_OPS_DAILY_KPIS requires 2+ days of history to compute KPIs |

## Cleanup

```sql
DROP STREAMLIT IF EXISTS {DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME};
```

> **Tip:** Use the `aviation-cleanup` skill to auto-discover all tagged objects via COMMENT tracking.
