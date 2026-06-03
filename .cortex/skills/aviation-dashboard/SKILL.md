---
name: aviation-dashboard
description: "Deploy the Airport Analytics dashboards: Streamlit-in-Snowflake plus the React dashboard via SPCS (Docker build + CREATE SERVICE). Create the Streamlit app, build/push the Docker image, create the SPCS service, and verify the URLs. Use when: deploying dashboard, setting up airport analytics UI, installing flight tracker, monitoring page, SPCS dashboard, React dashboard. Do NOT use for: installing airport data pipeline (use aviation-installer), cleaning up objects (use aviation-cleanup). Triggers: deploy dashboard, aviation dashboard, airport analytics UI, streamlit airport, install dashboard, flight tracker app, react dashboard, SPCS dashboard."
depends_on:
  - aviation-installer
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: infrastructure
---

# Deploy Airport Analytics Dashboard

Every invocation of this skill deploys **both** dashboard stacks for airport analytics:

| Variant | Directory | Stack | Deployment |
|---------|-----------|-------|------------|
| Streamlit | `dashboard-streamlit/` | Python, Streamlit, pydeck, Altair | Streamlit-in-Snowflake |
| React | `dashboard-react/` | React 18, TypeScript, deck.gl, recharts | **SPCS** (`docker build` + `CREATE SERVICE`) |

Both dashboards provide the same analytics pages and auto-discover all `AIRPORT_XXX` databases.

> **IMPORTANT: Single-instance deployment.** Deploy exactly **one Streamlit app** and **one SPCS service** per Snowflake account. Both live in the same host database (the first installed `AIRPORT_*`, or whichever database already hosts an existing dashboard). They auto-discover all other airport databases via `SHOW DATABASES LIKE 'AIRPORT_%'` — do NOT deploy a separate dashboard pair per airport. Use the AirportSwitcher inside either app to switch airports.

## Deployment Order

Execute **both** phases on every run (standalone or via `aviation-installer` Step 6). Do not deploy only one stack unless the user explicitly asks to update a single stack (e.g. "redeploy React only").

| Phase | Section | What it deploys |
|-------|---------|-----------------|
| **A** | [Streamlit Dashboard](#streamlit-dashboard) — Workflow Steps 1–5 | `CREATE OR REPLACE STREAMLIT` from Git repo stage |
| **B** | [React Dashboard (SPCS)](#react-dashboard-spcs) — SPCS Deployment Workflow | SPCS infrastructure, Docker image build/push, `AVIATION_DASHBOARD_SERVICE` |

**Shared host database:** Resolve `{DASHBOARD_DB}` in Phase A and set `{TARGET_DB}` = `{DASHBOARD_DB}` for Phase B (same database for both objects).

**Version checks:** Independent per stack — Streamlit Step 3.5 (`SHOW STREAMLITS`) and React Step 2.5 (`SHOW SERVICES`). Either stack may skip its deploy steps when already at the current skill version; the other stack still runs.

**React prerequisite gate:** Phase B runs the [Prerequisite Gate](#prerequisite-gate-required-before-step-3) before SPCS infrastructure. On the default both-stacks path, if Docker/Podman, `snow` CLI, or required SPCS privileges are missing, **skip Phase B** and complete successfully with Streamlit only — print a clear warning (what was skipped and why). Set `{REACT_DEPLOYED}` = false. **Hard-fail** only when the user explicitly requested React/SPCS only (e.g. "redeploy React only", "SPCS dashboard only").

**Final output:** Print URLs per [Final Output](#final-output) — Streamlit always; React/SPCS only when `{REACT_DEPLOYED}` = true.

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
| DASHBOARD_DB | (first AIRPORT_* database found) | Database to host the Streamlit app — deploy ONLY ONCE per account |
| DASHBOARD_SCHEMA | PUBLIC | Schema to host the Streamlit app |
| APP_NAME | AIRPORT_ANALYTICS_DASHBOARD | Streamlit object name |
| GIT_REPO_STAGE | `@{TARGET_DB}.{SCHEMA}.AVIA_OPS_REPO/branches/main` | Source files |
| WAREHOUSE | (current warehouse) | Warehouse for app execution |

## Friction Logging

When invoked by the parent installer, report all friction points back using the F1/F2/F3 format from `.cortex/skills/logs/README.md`. When invoked standalone, write to `.cortex/skills/logs/friction-log_{YYYY-MM-DD}_{HH-MM}.md`. Always create the log — even if no issues occurred (write "No friction points encountered.").

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

**Single-instance rule:** Always deploy into the FIRST `AIRPORT_*` database (alphabetical). If a Streamlit app named `AIRPORT_ANALYTICS_DASHBOARD` already exists in ANY `AIRPORT_*` database, reuse that database — never create a second dashboard app.

```sql
SHOW STREAMLITS LIKE 'AIRPORT_ANALYTICS_DASHBOARD' IN ACCOUNT;
```

If found, use its database as `DASHBOARD_DB`.

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

### Step 3.5: Check Dashboard Version

Before deploying, check if a dashboard already exists and compare versions.

```sql
SHOW STREAMLITS LIKE '{APP_NAME}' IN {DASHBOARD_DB}.{DASHBOARD_SCHEMA};
```

If a result is returned, parse the `comment` column as JSON and extract `version.major` and `version.minor`. The current skill version is `1.0` (from `metadata.version` in the YAML frontmatter — use major=1, minor=0).

**Decision logic:**
- **No existing dashboard found** → proceed to Step 4 (fresh deploy).
- **Existing version matches current skill version** (major and minor equal) → print "Dashboard is already up to date (v{major}.{minor}). Skipping deployment." and skip Steps 4–5.
- **Existing version is older than current skill version** → print "Updating dashboard from v{old_major}.{old_minor} to v{new_major}.{new_minor}." and proceed to Step 4.
- **COMMENT is missing or not parseable as JSON** → treat as outdated, proceed to Step 4.

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

## Stopping Points

- After Step 3: Confirm target database and schema exist
- After Step 3.5: If dashboard already exists at current version, skip deployment
- After Step 4: Confirm Streamlit object was created (`SHOW STREAMLITS`)
- After Step 5: Verify URL is accessible

## Examples

### Example 1: Deploy both dashboards for first airport
User says: "Deploy the dashboard for SAN"
Actions:
1. Phase A: Set query tag, verify AIRPORT_SAN exists, `CREATE STREAMLIT` from Git repo stage
2. Phase B: Prerequisite gate (Docker/Podman + SPCS privileges), SPCS infra, build/push image, create service
3. Print both Snowsight Streamlit URL and SPCS ingress URL
Result: Streamlit at `AIRPORT_SAN.PUBLIC.AIRPORT_ANALYTICS_DASHBOARD` and SPCS at `AIRPORT_SAN.PUBLIC.AVIATION_DASHBOARD_SERVICE`

### Example 2: Second airport installed, dashboards already exist
User says: "Deploy the dashboard for DFW"
Actions:
1. `SHOW STREAMLITS` / `SHOW SERVICES` → both found in AIRPORT_SAN
2. Version checks per stack; redeploy only stacks that are outdated
3. Print "Dashboards already deployed in AIRPORT_SAN. They auto-discover all airports including DFW."
4. Return existing Streamlit and SPCS URLs
Result: No duplicate objects; user directed to existing dashboards in AIRPORT_SAN

### Example 3: Both dashboards already up to date
User says: "Redeploy the dashboard"
Actions:
1. Streamlit version check → v1.0 matches → skip Phase A deploy steps
2. SPCS version check → v1.0 matches → skip Phase B deploy steps
3. Print both URLs from existing objects
Result: No changes made; both URLs still returned

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

## Output (Streamlit phase)

After Phase A completes (or skips as up to date), record:
- App: `{DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME}`
- 9 analytics pages; auto-discovers all `AIRPORT_XXX` databases

Continue to Phase B, then print both URLs in [Final Output](#final-output).

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
| TARGET_DB | (first AIRPORT_* database found) | Airport database hosting the service — deploy ONLY ONCE per account |
| WAREHOUSE | AVIA_{IATA}_WH | Query warehouse for the service |
| COMPUTE_POOL | AVIATION_DASHBOARD_COMPUTE_POOL | Compute pool (shared across airports) |
| IMAGE_TAG | (from `dashboard-react/image-versions.env` → `AVIATION_DASHBOARD_TAG`) | Pinned semver tag. Never use `:latest` — SPCS caches it and will not re-pull. |
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

### Step 2: Verify Prerequisite Airport Data and Determine TARGET_DB

```sql
SHOW DATABASES LIKE 'AIRPORT_%';
```

At least one `AIRPORT_XXX` database must exist. If none, run `aviation-installer` first.

**Single-instance rule:** Always deploy into the FIRST `AIRPORT_*` database returned (alphabetical order). If a dashboard service already exists in ANY `AIRPORT_*` database, reuse that one — never create a second service.

```sql
-- Check if a dashboard service already exists in any airport DB
SHOW SERVICES LIKE 'AVIATION_DASHBOARD_SERVICE' IN ACCOUNT;
```

If a result is found, use that database as `TARGET_DB` (even if a different airport was just installed). If no existing service, use the first `AIRPORT_*` database.

### Step 2.5: Check Existing SPCS Dashboard Version

Before creating infrastructure, check if the SPCS dashboard service already exists:

```sql
SHOW SERVICES LIKE 'AVIATION_DASHBOARD_SERVICE' IN {TARGET_DB}.PUBLIC;
```

If a result is returned, parse the `comment` column as JSON and extract `version.major` and `version.minor`. The current skill version is `1.0` (major=1, minor=0).

**Decision logic:**
- **No existing service found** → proceed to Step 3 (create infrastructure).
- **Existing version matches current skill version** → print "SPCS Dashboard is already up to date (v{major}.{minor}). Skipping deployment." and skip Steps 3–6.
- **Existing version is older** → print "Updating SPCS dashboard from v{old_major}.{old_minor} to v{new_major}.{new_minor}." and proceed to Step 3. Use `DROP SERVICE IF EXISTS` + `CREATE SERVICE` to redeploy.
- **COMMENT is missing or not parseable** → treat as outdated, proceed to Step 3.

### Prerequisite Gate (required before Step 3)

Run this gate **before Step 3** whenever Phase B will create or update SPCS infrastructure (Steps 3–6 are not skipped by the Step 2.5 version check).

**Default (both stacks):** If any check below fails, print a warning, set `{REACT_DEPLOYED}` = false, skip Steps 3–6, and proceed to [Final Output](#final-output) with Streamlit only. Phase A is already complete — this is a **successful** outcome.

**React-only request:** If the user explicitly asked for React/SPCS only, hard-fail on any failed check (same error messages as below, then `exit 1`).

**1. Container runtime**

> Read and run section 1 in `references/build-images.md` (Detect Container Runtime).

```bash
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  CONTAINER_CMD=docker
elif command -v podman &>/dev/null; then
  CONTAINER_CMD=podman
  podman machine start 2>/dev/null || true
else
  echo "WARNING: Neither docker nor podman found. Skipping React/SPCS (Streamlit deployed)."
  REACT_SKIP=container_runtime
fi
```

If `docker info` or `podman` machine fails after detection, treat as `REACT_SKIP=container_runtime` on the default path; hard-fail on React-only.

**2. Snowflake CLI**

```bash
command -v snow &>/dev/null || REACT_SKIP=snow_cli
```

On React-only: `echo "ERROR: snow CLI not found."; exit 1`

**3. SPCS privileges**

```sql
SHOW GRANTS TO ROLE CURRENT_ROLE();
```

Confirm grants include (or equivalent via a parent role):
- `CREATE COMPUTE POOL` on account
- `CREATE SERVICE` on `{TARGET_DB}.PUBLIC` (or schema)
- `CREATE IMAGE REPOSITORY` on `{TARGET_DB}.PUBLIC`
- `BIND SERVICE ENDPOINT` on account

If any grant is missing: on the default path, set `REACT_SKIP=spcs_privileges` and print which grant is absent; on React-only, stop with an error.

If all checks pass, set `{REACT_DEPLOYED}` = true and `{CONTAINER_CMD}` from step 1 for Phase B build steps.

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

## Update / Redeploy (Rolling Image Update)

SPCS does NOT re-pull when the image tag is unchanged (e.g. `:latest`) and will serve the cached digest even if you `podman push` over the same tag. To ship new code safely, always bump to a new semver tag and then `ALTER SERVICE ... FROM SPECIFICATION` with that tag. SPCS sees a new image digest and pulls cleanly.

### Recommended: scripted pipeline

One command chains: validate -> compile -> build (`--no-cache`) -> push -> `ALTER SERVICE` -> digest verification. Any failure aborts the pipeline.

```bash
SNOWFLAKE_CONNECTION=<conn> TARGET_DB=AIRPORT_XXX WAREHOUSE=AVIA_XXX_WH \
  .cortex/skills/aviation-dashboard/scripts/bump_tag.sh patch
SNOWFLAKE_CONNECTION=<conn> TARGET_DB=AIRPORT_XXX WAREHOUSE=AVIA_XXX_WH \
  .cortex/skills/aviation-dashboard/scripts/deploy.sh
```

`bump_tag.sh` refuses to run if the current tag is malformed, rewrites [image-versions.env](dashboard-react/image-versions.env), and re-runs `check_image_versions.sh` (which includes the code-drift guard). `deploy.sh` refuses to proceed if any consumer file disagrees with the env file, if `dist/` is older than any React source, or if the post-deploy service digest does not match the pinned tag.

### Manual fallback (step-by-step)

#### Step A: Bump the tag

```bash
.cortex/skills/aviation-dashboard/scripts/bump_tag.sh patch   # or minor/major
```

Do NOT hand-edit `image-versions.env` — the script enforces semver parsing and re-runs the validator automatically.

#### Step B: Validate consistency (includes code-drift guard)

```bash
.cortex/skills/aviation-dashboard/scripts/check_image_versions.sh
```

Exit 0 = safe to build/push. Exit 1 = a YAML/doc is out of sync OR React/server sources changed since the tag was cut; fix first.

#### Step C: Rebuild and push with the new tag

Follow `references/build-images.md`. **Always pass `--no-cache`** — cached layers can silently reuse stale `dist/` COPY steps and ship old bytes under a new tag.

#### Step D: Roll the service to the new tag

```bash
SNOWFLAKE_CONNECTION=<conn> TARGET_DB=AIRPORT_XXX WAREHOUSE=AVIA_XXX_WH \
  .cortex/skills/aviation-dashboard/scripts/apply_service_spec.sh
```

This reads the YAML template, substitutes `{TARGET_DB}` / `{WAREHOUSE}` / `{AVIATION_DASHBOARD_TAG}`, fails if any placeholder is unresolved, and runs `ALTER SERVICE ... FROM SPECIFICATION`.

#### Step E: Verify the roll

```bash
SNOWFLAKE_CONNECTION=<conn> TARGET_DB=AIRPORT_XXX \
  .cortex/skills/aviation-dashboard/scripts/verify_service_image.sh
```

Parses `SYSTEM$GET_SERVICE_STATUS` and asserts the running image ends with `:${AVIATION_DASHBOARD_TAG}`. Fails loudly if SPCS is serving a stale digest.

### Rollback

Set `AVIATION_DASHBOARD_TAG` back to the prior value (the old image is still in the registry) and re-run Step D. No rebuild needed — instant rollback.

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

## Output (React phase)

After Phase B completes (or skips as up to date), record:
- Service: `{TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE`
- Compute pool: `AVIATION_DASHBOARD_COMPUTE_POOL`
- 10 pages; auto-discovers all `AIRPORT_XXX` databases

Continue to [Final Output](#final-output).

## Cleanup

```sql
DROP SERVICE IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;
DROP COMPUTE POOL IF EXISTS AVIATION_DASHBOARD_COMPUTE_POOL;
DROP IMAGE REPOSITORY IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO;
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS {TARGET_DB}_AVIATION_CARTO_EAI;
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_CARTO_NETWORK_RULE;
```

> **Tip:** Use the `aviation-cleanup` skill to auto-discover all tagged objects via COMMENT tracking.

---

## Final Output

After Phase A finishes (and Phase B when `{REACT_DEPLOYED}` = true), retrieve and print dashboard URL(s).

**Streamlit (Snowsight)** — always:

```sql
SELECT SYSTEM$GET_SNOWSIGHT_HOST() AS host;
```

**React (SPCS public endpoint)** — only when `{REACT_DEPLOYED}` = true:

```sql
SHOW SERVICES LIKE 'AVIATION_DASHBOARD_SERVICE' IN {TARGET_DB}.PUBLIC;
```

If a service exists:

```sql
SHOW ENDPOINTS IN SERVICE {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;
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

**When React/SPCS was skipped** (`{REACT_DEPLOYED}` = false), print:

> **Airport Analytics Dashboard deployed (Streamlit):**
>
> **Streamlit (Snowsight):** `https://<host>/api/streamlit/{DASHBOARD_DB}.{DASHBOARD_SCHEMA}.{APP_NAME}`
>
> **React (SPCS):** Skipped — `<reason>` (e.g. no container runtime, missing `snow` CLI, or insufficient SPCS privileges). Install Docker/Podman, configure Snowflake CLI, and grant SPCS privileges, then re-run to deploy React.
