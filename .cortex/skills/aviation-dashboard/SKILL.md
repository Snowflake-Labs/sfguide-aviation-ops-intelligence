---
name: aviation-dashboard
description: "Deploy the Airport Analytics dashboard (Streamlit-in-Snowflake or React/SPCS): upload app files, create the Streamlit object or SPCS service, and verify accessibility. Use when: deploying dashboard, setting up airport analytics UI, installing flight tracker, monitoring page, SPCS dashboard, React dashboard. Do NOT use for: installing airport data pipeline (use aviation-installer), cleaning up objects (use aviation-cleanup). Triggers: deploy dashboard, aviation dashboard, airport analytics UI, streamlit airport, install dashboard, flight tracker app, react dashboard, SPCS dashboard."
depends_on:
  - aviation-installer
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
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
| TSA Throughput | `6_TSA_Throughput.py` | TSA_THROUGHPUT, PROPERTIES_AIRPORT |
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

### TSA Throughput page

| Object | Columns Used |
|--------|-------------|
| `TSA_THROUGHPUT` | DATE, HOUR_OF_DAY, AIRPORT_CODE, CHECKPOINT, TOTAL_PAX_KCM_PAX, AIRPORT_NAME, CITY, STATE |
| `PROPERTIES_AIRPORT` | AIRPORT_CODE |

### Performance page

| Object | Columns Used |
|--------|-------------|
| `V_AIR_OPS_DAILY_KPIS` | FLIGHT_DATE, MEDIAN_TAXI_IN_MIN, MEDIAN_TAXI_OUT_MIN, ON_TIME_ARR_PCT, ON_TIME_DEP_PCT |

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| App shows "No airport databases found" | No airport installed | Run `aviation-installer` first; verify AIRPORT_XXX databases exist |
| Streamlit creation fails | Missing privilege | Check role has CREATE STREAMLIT privilege on target schema |
| Pages show empty charts | Pipeline initializing | Data pipelines may still be initializing; wait 5–10 min after install |
| Map layers not rendering | Missing infrastructure data | Check PROPERTIES_INFRASTRUCTURE has rows for the airport |
| Multi-airport selector missing airports | Missing properties | Verify each AIRPORT_XXX database has PROPERTIES_AIRPORT with 1 row |
| Performance page always empty | Insufficient history | V_AIR_OPS_DAILY_KPIS requires 2+ days of history to compute KPIs |

## Cleanup

```sql
DROP STREAMLIT IF EXISTS {DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME};
```

> **Tip:** Use the `aviation-cleanup` skill to auto-discover all tagged objects (including SPCS objects) via COMMENT tracking.

---

# React Dashboard (SPCS)

A React 18 + TypeScript + deck.gl dashboard deployed as a Snowpark Container Service. Supports both Docker and Podman. Uses the same Snowflake design system as the ORS Control App from the routing solution.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | React 18, TypeScript 5.6, Vite 5.4 |
| Maps | deck.gl ~9.2.11, luma.gl ~9.2.6, CARTO basemap |
| Charts | recharts 3.x |
| Icons | lucide-react |
| Server | Express 4, dual-mode SQL (local `snow sql` / SPCS REST API) |
| Container | Docker or Podman, Snowpark Container Services |

## Pages

| Page | Component | Key Visualizations |
|------|-----------|-------------------|
| Home | `Home.tsx` | Navigation grid with page cards |
| Live View | `LiveView.tsx` | ScatterplotLayer aircraft positions + timetable, day replay with TripsLayer + time slider |
| Flight Tracker | `FlightTracker.tsx` | PathLayer flight paths + altitude profile, timestamp replay slider with moving aircraft dot |
| Ground Activity | `GroundActivity.tsx` | H3HexagonLayer 3D density, Static/Replay mode with day/hour/10-min aggregation slider |
| Runway Crossings | `RunwayCrossings.tsx` | Hexagon heatmap + GeoJsonLayer runways |
| Traffic Analysis | `TrafficAnalysis.tsx` | Daily trends, hourly bars, airline rankings |
| Gate Analysis | `GateAnalysis.tsx` | Utilization bars, airline dwell charts |
| TSA Throughput | `TSAThroughput.tsx` | Daily trend, hourly bars, checkpoint donut, heatmap |
| Monitoring | `Monitoring.tsx` | Freshness, volume, QA counts |
| Performance | `Performance.tsx` | Taxi times, on-time rates |

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| TARGET_DB | AIRPORT_{IATA} | Airport database hosting the service |
| WAREHOUSE | AVIA_{IATA}_WH | Query warehouse for the service |
| COMPUTE_POOL | AVIATION_DASHBOARD_COMPUTE_POOL | Compute pool (shared across airports) |
| IMAGE_TAG | latest | Docker image tag |
| CONTAINER_CMD | docker or podman | Auto-detected container runtime |
| ACCOUNT | (current account) | Snowflake account identifier |

## Required Privileges

| Privilege | Scope | Reason |
|-----------|-------|--------|
| CREATE COMPUTE POOL | Account | Creates the SPCS compute pool |
| CREATE SERVICE | Schema | Creates the SPCS service |
| CREATE IMAGE REPOSITORY | Schema | Creates image repo for Docker images |
| CREATE NETWORK RULE | Schema | CARTO basemap egress rule |
| CREATE INTEGRATION | Account | External access integration for CARTO |
| BIND SERVICE ENDPOINT | Account | Required for public endpoints |
| USAGE ON DATABASE | AIRPORT_XXX | Dashboard reads airport analytics data |
| SELECT ON TABLES/VIEWS | Airport schemas | Reads all dashboard data sources |

## Prerequisites

1. At least one airport installed via `aviation-installer` (at minimum `base-setup` and `derived-analytics` completed)
2. Docker or Podman installed and running
3. Snowflake CLI (`snow`) installed and configured with a connection

## Local Development

```bash
cd dashboard-react
cp .env.example .env
# Edit .env: set SNOWFLAKE_CONNECTION, SNOWFLAKE_WAREHOUSE, SNOWFLAKE_DATABASE

npm install --legacy-peer-deps
npm run dev          # Vite dev server (frontend) on :5173
npm run build:server # Compile Express server
npm start            # Express server on :3001 (serves API + proxies tiles)
```

The Vite dev server proxies `/api/*` to `http://localhost:3001`.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SNOWFLAKE_CONNECTION` | Local only | `snow sql -c` connection name |
| `SNOWFLAKE_WAREHOUSE` | Yes | Warehouse for queries |
| `SNOWFLAKE_DATABASE` | No | Default airport database |
| `SNOWFLAKE_HOST` | SPCS only | Auto-detected; triggers SPCS mode |
| `PORT` | No | Server port (default: 3001) |

In SPCS, the service authenticates via OAuth token from `/snowflake/session/token` and executes SQL through the Snowflake SQL REST API.

## SPCS Deployment Workflow

### Step 1: Set Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 2: Verify Prerequisite Airport Data

```sql
SHOW DATABASES LIKE 'AIRPORT_%';
```

At least one `AIRPORT_XXX` database must exist. If none, run `aviation-installer` first.

### Step 3: Create SPCS Infrastructure

> Read and follow `references/spcs-infrastructure.md` — steps 2 through 6.

This creates (in order):
1. Image repository in `{TARGET_DB}.PUBLIC`
2. Network rule for CARTO basemap CDN egress
3. External access integration
4. Compute pool (`CPU_X64_XS`, 1 node)
5. Wait for compute pool ACTIVE

### Step 4: Build and Push Docker Image

> Read and follow `references/build-images.md`.

This handles:
- Container runtime detection (Docker or Podman)
- ARM Mac esbuild workaround (prebuilt flow)
- Registry authentication
- Build, push, and verification

### Step 5: Create Service

> Read and follow `references/spcs-infrastructure.md` — step 7.

Uses inline `FROM SPECIFICATION $$...$$` with actual parameter values substituted. No `AUTO_SUSPEND_SECS` (incompatible with public endpoints).

### Step 6: Verify and Get Endpoint URL

```sql
SELECT SYSTEM$GET_SERVICE_STATUS('{TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE');
```

Get the public URL:
```sql
SHOW ENDPOINTS IN SERVICE {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;
```

The `ingress_url` column contains the dashboard URL. Share this with users.

### Step 7: Grant Access (Optional)

```sql
GRANT USAGE ON SERVICE {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE TO ROLE {CONSUMER_ROLE};
```

## Design Notes

- CSS is inline in `index.html` using the same Snowflake design system (`--sf-blue: #29B5E8`) as the ORS Control App
- No CSS modules or Tailwind — all styles via CSS custom properties
- State management via React Context (`AirportContext`)
- Navigation via simple string state (no react-router)
- `useSnowflake` hook for data fetching via `/api/query`
- CARTO basemap tiles proxied through Express to avoid CORS

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| esbuild crash during Docker build on Mac | ARM Mac + QEMU amd64 emulation | Use prebuilt flow in `references/build-images.md` |
| Push appears stuck with no output | Carriage return progress invisible in pipes | Wait 2-4 min; verify with `snow spcs image-repository list-images` |
| White page after deployment | Build failed but error swallowed by shell `\|\| true` | Never chain npm + docker with `\|\| true`; verify `dist/index.html` exists |
| Service stuck in PENDING | Compute pool STARTING or SUSPENDED | Wait for ACTIVE/IDLE; check `SHOW COMPUTE POOLS` |
| "unauthorized" on push | Registry auth expired | Re-run `snow spcs image-registry login` |
| Podman push auth failure | Wrong registry hostname stored | Use `--creds "0sessiontoken:$TOKEN"` flag |
| 502 on map tile proxy | CARTO EAI not attached to service | Verify `EXTERNAL_ACCESS_INTEGRATIONS` includes the CARTO EAI |
| `BIND SERVICE ENDPOINT` error | Missing account-level privilege | `GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE ...` |
| `npm ci` fails in Dockerfile | Missing `package-lock.json` | Run `npm install --legacy-peer-deps` locally first |
| Vite build fails on luma.gl import | Version pin drift to 9.3.x | Verify `~9.2.6` pins in `package.json` |
| SQL REST API 500 errors in SPCS | SNOWFLAKE_HOST set explicitly to short-form account URL | Do NOT set SNOWFLAKE_HOST in service spec; SPCS auto-injects the full regional URL |
| `CREATE OR REPLACE SERVICE` fails | Not supported for SPCS services | Use `DROP SERVICE IF EXISTS` + `CREATE SERVICE` to redeploy |
| Docker `--ignorefile` not recognized | Docker 29.x does not support `--ignorefile` | Swap `.dockerignore` manually (see `references/build-images.md`) |

## Cleanup

```sql
DROP SERVICE IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;
DROP COMPUTE POOL IF EXISTS AVIATION_DASHBOARD_COMPUTE_POOL;
DROP IMAGE REPOSITORY IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO;
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS {TARGET_DB}_AVIATION_CARTO_EAI;
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_CARTO_NETWORK_RULE;
```

> **Tip:** Use the `aviation-cleanup` skill to auto-discover all tagged objects via COMMENT tracking.
