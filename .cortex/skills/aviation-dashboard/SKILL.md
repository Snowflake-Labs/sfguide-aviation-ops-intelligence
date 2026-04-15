---
name: aviation-dashboard
description: "Deploy the Airport Analytics dashboard (Streamlit-in-Snowflake or React/SPCS): upload app files, create the Streamlit object or SPCS service, and verify accessibility. Use when: deploying dashboard, setting up airport analytics UI, installing flight tracker, monitoring page, SPCS dashboard, React dashboard. Do NOT use for: installing airport data pipeline (use aviation-installer), cleaning up objects (use aviation-cleanup). Triggers: deploy dashboard, aviation dashboard, airport analytics UI, streamlit airport, install dashboard, flight tracker app, react dashboard, SPCS dashboard."
depends_on:
  - aviation-installer
metadata:
  author: Snowflake SIT-IS
  version: 2.0.0
  category: infrastructure
---

# Deploy Airport Analytics Dashboard

This skill contains two dashboard implementations for airport analytics:

| Variant | Directory | Stack | Deployment |
|---------|-----------|-------|------------|
| Streamlit | `dashboard-streamlit/` | Python, Streamlit, pydeck, Altair | Streamlit-in-Snowflake |
| React | `dashboard-react/` | React 18, TypeScript, deck.gl, recharts | SPCS (Docker + Express) |

Both dashboards provide the same 8 analytics pages and auto-discover all `AIRPORT_XXX` databases.

---

# Streamlit Dashboard

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
2. Dashboard files available in Git repo stage (`{GIT_REPO_STAGE_BASE}/.cortex/skills/aviation-dashboard/dashboard-streamlit`)
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
| DASHBOARD_DB | {TARGET_DB} | Database to host the Streamlit app (same as the airport database) |
| DASHBOARD_SCHEMA | PUBLIC | Schema to host the Streamlit app |
| APP_NAME | AIRPORT_ANALYTICS_DASHBOARD | Streamlit object name |
| GIT_REPO_STAGE | `@{TARGET_DB}.{SCHEMA}.AVIA_OPS_REPO/branches/main` | Source files |
| WAREHOUSE | (current warehouse) | Warehouse for app execution |

## Error Logging

When any step fails, log to `.cortex/skills/logs/` as `aviation-dashboard_{YYYY-MM-DD}_{HH-MM}.md`. If no issues, do not create a log file.

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

### Step 3: Verify Dashboard Host Schema

The dashboard is deployed into the airport database created by `base-setup`. Verify it exists:

```sql
SELECT 1 FROM INFORMATION_SCHEMA.SCHEMATA WHERE CATALOG_NAME = '{DASHBOARD_DB}' AND SCHEMA_NAME = '{DASHBOARD_SCHEMA}';
```

> **Note:** The airport database and PUBLIC schema already exist from the `base-setup` sub-skill.

### Step 4: Create or Replace Streamlit App

```sql
CREATE OR REPLACE STREAMLIT {DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME}
  ROOT_LOCATION = '{GIT_REPO_STAGE_BASE}/.cortex/skills/aviation-dashboard/dashboard-streamlit'
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

---

# React Dashboard (SPCS)

A React 18 + TypeScript + deck.gl dashboard deployed as a Snowpark Container Service. Uses the same Snowflake design system as the ORS Control App from the routing solution.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | React 18, TypeScript 5.6, Vite 5.4 |
| Maps | deck.gl ~9.2.11, luma.gl ~9.2.6, CARTO basemap |
| Charts | recharts 3.x |
| Icons | lucide-react |
| Server | Express 4, dual-mode SQL (local `snow sql` / SPCS REST API) |
| Deploy | Docker, Snowpark Container Services |

## Pages

| Page | Component | Key Visualizations |
|------|-----------|-------------------|
| Home | `Home.tsx` | Navigation grid with page cards |
| Live View | `LiveView.tsx` | ScatterplotLayer aircraft positions + timetable |
| Flight Tracker | `FlightTracker.tsx` | PathLayer flight paths + altitude profile |
| Ground Activity | `GroundActivity.tsx` | H3HexagonLayer 3D density |
| Runway Crossings | `RunwayCrossings.tsx` | Hexagon heatmap + GeoJsonLayer runways |
| Traffic Analysis | `TrafficAnalysis.tsx` | Daily trends, hourly bars, airline rankings |
| Gate Analysis | `GateAnalysis.tsx` | Utilization bars, airline dwell charts |
| Monitoring | `Monitoring.tsx` | Freshness, volume, QA counts |
| Performance | `Performance.tsx` | Taxi times, on-time rates |

## Local Development

```bash
cd dashboard-react
cp .env.example .env
# Edit .env: set SNOWFLAKE_CONNECTION, SNOWFLAKE_WAREHOUSE, SNOWFLAKE_DATABASE

npm install --legacy-peer-deps
npm run dev          # Vite dev server (frontend) on :5173
npm run build:server # Compile Express server
npm start            # Express server on :8080 (serves API + proxies tiles)
```

The Vite dev server proxies `/api/*` to `http://localhost:8080`.

## Production Build

```bash
npm run build          # TypeScript check + Vite bundle → dist/
npm run build:server   # Compile server → dist-server/
npm start              # Serves dist/ + API on :8080
```

## SPCS Deployment

### 1. Build and push Docker image

```bash
cd dashboard-react
docker build -f Dockerfile.runtime -t aviation-ops-dashboard:latest .

# Tag and push to Snowflake image registry
docker tag aviation-ops-dashboard:latest <registry>/aviation-ops-dashboard:latest
docker push <registry>/aviation-ops-dashboard:latest
```

### 2. Create the SPCS service

```sql
CREATE SERVICE {DATABASE}.{SCHEMA}.AVIATION_DASHBOARD_SERVICE
  IN COMPUTE POOL {COMPUTE_POOL}
  FROM SPECIFICATION_FILE = 'aviation_dashboard_service.yaml'
  EXTERNAL_ACCESS_INTEGRATIONS = ({EAI_NAME})
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"aviation-ops-dashboard","version":"1.0"}';
```

### 3. Verify

```sql
SHOW SERVICES LIKE 'AVIATION_DASHBOARD_SERVICE' IN SCHEMA {DATABASE}.{SCHEMA};
SELECT SYSTEM$GET_SERVICE_STATUS('{DATABASE}.{SCHEMA}.AVIATION_DASHBOARD_SERVICE');
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SNOWFLAKE_CONNECTION` | Local only | `snow sql -c` connection name |
| `SNOWFLAKE_WAREHOUSE` | Yes | Warehouse for queries |
| `SNOWFLAKE_DATABASE` | No | Default airport database |
| `PORT` | No | Server port (default: 8080) |

In SPCS, the service authenticates via OAuth token from `/snowflake/session/token` and executes SQL through the SQL REST API.

## Design Notes

- CSS is inline in `index.html` using the same Snowflake design system (`--sf-blue: #29B5E8`) as the ORS Control App
- No CSS modules or Tailwind — all styles via CSS custom properties
- State management via React Context (`AirportContext`)
- Navigation via simple string state (no react-router)
- `useSnowflake` hook for data fetching via `/api/query`
- CARTO basemap tiles proxied through Express to avoid CORS
