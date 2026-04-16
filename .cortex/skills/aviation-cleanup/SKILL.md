---
name: aviation-cleanup
description: "Discover and remove all Snowflake objects created by the aviation-ops-intelligence skills. Uses the COMMENT tracking tag (sf_sit-is-aviation) to find objects, generates DROP statements in dependency-safe order, and optionally executes them. Use when: cleaning up after a demo, removing airport analytics objects, tearing down an environment, removing a specific airport. Do NOT use for: dropping objects not created by these skills, production cleanup without review, provisioning or deploying airports. Triggers: aviation-cleanup, cleanup airport, teardown aviation, remove airport analytics, remove airport objects, drop aviation objects, reset aviation environment."
metadata:
  author: Snowflake SIT-IS
  version: 1.0.0
  category: developer-tools
---

# Cleanup / Teardown

Discovers and removes **all** Snowflake objects created by skills in this repository. Uses the COMMENT tracking tag `sf_sit-is-aviation` for tagged objects and explicit name matching for account-level objects (network rules, external access integrations) that cannot carry COMMENT fields.

## How It Works

Every CREATE statement in every skill includes a COMMENT with JSON metadata:
```json
{"origin":"sf_sit-is-aviation","name":"<skill-tracking-name>","version":{"major":1,"minor":0},...}
```

This skill queries `INFORMATION_SCHEMA`, `SHOW` commands, and `ACCOUNT_USAGE` views to discover all tagged objects, then generates DROP statements in dependency-safe order.

> **IMPORTANT:** External access integrations and network rules are account-level objects created during ADS-B ingestion, flight schedules, and TSA throughput. They are matched by name pattern (`AIRPORT_*_EAI`, `AIRPORT_*_RULE`) rather than COMMENT tag, since those object types may not support COMMENT.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| TRACKING_TAG | `sf_sit-is-aviation` | Origin tag to search for in COMMENT fields |
| AIRPORT_FILTER | (all) | Optional: filter to a specific airport (e.g., `AIRPORT_SAN`) |
| DRY_RUN | `true` | When true, only generates DROP statements without executing |

## Friction Log

Always write a friction log to `.cortex/skills/logs/aviation-cleanup_{YYYY-MM-DD}_{HH-MM}.md` with the same format described in AGENTS.md. Include configuration, objects discovered/dropped, and any errors. If no friction points, mark that section as "None".

## Execution Rules

1. **Always dry-run first.** Never execute DROP statements without user confirmation.
2. **Suspend tasks before dropping.** Every TASK must be SUSPENDED before DROP.
3. **Drop in dependency order.** Follow the phase sequence (Streamlit → Tasks → DTs → Views → Procedures → Tables → EAIs → Database).
4. **Verify after cleanup.** Run `SHOW DATABASES LIKE 'AIRPORT_%'` and `SHOW INTEGRATIONS LIKE 'AIRPORT_%'` to confirm clean state.
5. **All discovery queries must use the tracking tag** `sf_sit-is-aviation` — never drop objects that do not carry this tag.

## Prerequisites

- Active Snowflake connection with ACCOUNTADMIN role
- Review generated DROP statements before executing

## Complete Object Inventory

Drop order reverses creation dependencies (most-dependent objects first).

| # | Object Type | How to Discover | Drop Command |
|---|-------------|-----------------|--------------|
| 1 | Streamlit Apps | `SHOW STREAMLITS` + comment match | `DROP STREAMLIT IF EXISTS <db>.<schema>.<name>` |
| 2 | Tasks | `SHOW TASKS IN <db>.<schema>` per airport | `ALTER TASK <name> SUSPEND; DROP TASK IF EXISTS <name>` |
| 3 | Dynamic Tables | `SHOW DYNAMIC TABLES IN <db>.<schema>` per airport | `DROP DYNAMIC TABLE IF EXISTS <name>` |
| 4 | Views | `INFORMATION_SCHEMA.VIEWS` + comment match | `DROP VIEW IF EXISTS <name>` |
| 5 | Procedures | `INFORMATION_SCHEMA.PROCEDURES` + comment match | `DROP PROCEDURE IF EXISTS <name>(<arg_types>)` |
| 6 | Functions / UDFs | `INFORMATION_SCHEMA.FUNCTIONS` + comment match | `DROP FUNCTION IF EXISTS <name>(<arg_types>)` |
| 7 | Tables | `INFORMATION_SCHEMA.TABLES` + comment match | `DROP TABLE IF EXISTS <name>` |
| 8 | Stages | `SHOW STAGES IN <db>.<schema>` per airport | `DROP STAGE IF EXISTS <name>` |
| 8b | Git Repositories | `SHOW GIT REPOSITORIES IN <db>.<schema>` per airport | `DROP GIT REPOSITORY IF EXISTS <name>` |
| 9 | File Formats | `SHOW FILE FORMATS IN <db>.<schema>` | `DROP FILE FORMAT IF EXISTS <name>` |
| 10 | Tags | `SHOW TAGS IN <db>.TAGS` per airport | `DROP TAG IF EXISTS <name>` |
| 11 | External Access Integrations | `SHOW INTEGRATIONS` + name LIKE 'AIRPORT_%_EAI' | `DROP INTEGRATION IF EXISTS <name>` |
| 12 | Network Rules | `SHOW NETWORK RULES` in airport schemas | `DROP NETWORK RULE IF EXISTS <db>.<schema>.<name>` |
| 13 | Secrets | `SHOW SECRETS IN <db>.<schema>` | `DROP SECRET IF EXISTS <name>` |
| 14 | Schemas | `SHOW SCHEMAS IN <db>` per airport | `DROP SCHEMA IF EXISTS <name> CASCADE` |
| 15 | Databases | `SHOW DATABASES LIKE 'AIRPORT_%'` + comment match | `DROP DATABASE IF EXISTS <name> CASCADE` |

## Workflow

### Step 1: Set Session Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-cleanup","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### Step 2: Discover All Objects

Run the discovery queries from [references/discovery-queries.sql](references/discovery-queries.sql).

Execute each query block and collect results. SHOW + RESULT_SCAN patterns must be run as two consecutive statements in the same session.

> **Tip:** If filtering to a specific airport, replace `LIKE 'AIRPORT_%'` with `= 'AIRPORT_{IATA}'` in all discovery queries.

### Step 3: Generate DROP Statements

Based on discovery results, generate DROP statements in **strict dependency order**:

### Phase 1 — Streamlit Apps

The dashboard lives inside each airport database:
```sql
DROP STREAMLIT IF EXISTS {TARGET_DB}.PUBLIC.AIRPORT_ANALYTICS_DASHBOARD;
```

### Phase 2 — Tasks (Suspend First)

For each airport database, suspend and drop tasks in leaf-to-root order:

```sql
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_REFRESH_ANALYTICS SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_REFRESH_ANALYTICS;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_REFRESH_DERIVED SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_REFRESH_DERIVED;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_EXTRACT_TSA_PDF SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_EXTRACT_TSA_PDF;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_FETCH_TSA_PDF SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_FETCH_TSA_PDF;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_FLIGHT_SCHEDULE SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_FLIGHT_SCHEDULE;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ENRICH_ADSB SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ENRICH_ADSB;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ENRICH_AIRCRAFT_META SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ENRICH_AIRCRAFT_META;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ADSB_BACKFILL_ONCE SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ADSB_BACKFILL_ONCE;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ADSB_BACKFILL_RETRY SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_ADSB_BACKFILL_RETRY;
ALTER TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_INGEST_ADSB SUSPEND;
DROP TASK IF EXISTS {TARGET_DB}.PUBLIC.TASK_INGEST_ADSB;
```

### Phase 3 — Dynamic Tables

```sql
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.FLIGHT_TRACKER_FLIGHT_LIST;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.FLIGHT_TRAFFIC_FACT_ADSB_DAILY;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.RUNWAY_CROSSINGS_DETAILED;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.GATE_ANALYSIS_GATE_UTIL_DAILY;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.GATE_ANALYSIS_FLIGHT_GATE_TIME;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.GATE_ANALYSIS_ADSB_GROUND_POINTS;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS;
DROP DYNAMIC TABLE IF EXISTS {TARGET_DB}.PUBLIC.ADSB_DATA_LOCAL;
```

### Phase 4 — Views, Procedures, Functions, Tables

Use discovery results to drop in order. See [references/drop-order.sql](references/drop-order.sql) for the complete templated DROP sequence.

### Phase 5 — External Access Integrations and Network Rules

```sql
DROP INTEGRATION IF EXISTS {TARGET_DB}_PUBLIC_ADSB_LOL_EAI;
DROP INTEGRATION IF EXISTS {TARGET_DB}_PUBLIC_GITHUB_EAI;
DROP INTEGRATION IF EXISTS {TARGET_DB}_PUBLIC_AVIATIONSTACK_EAI;
DROP INTEGRATION IF EXISTS {TARGET_DB}_PUBLIC_TSA_GOV_EAI;
DROP INTEGRATION IF EXISTS {TARGET_DB}_PUBLIC_PYPI_ACCESS_INTEGRATION;
```

Network rules (qualified names inside the airport database):
```sql
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.PUBLIC_ADSB_LOL_RULE;
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.PUBLIC_GITHUB_RULE;
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.PUBLIC_AVIATIONSTACK_RULE;
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.PUBLIC_TSA_GOV_RULE;
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.PUBLIC_PYPI_NETWORK_RULE;
```

### Phase 6 — Schemas and Database

```sql
DROP SCHEMA IF EXISTS {TARGET_DB}.TAGS CASCADE;
DROP DATABASE IF EXISTS {TARGET_DB} CASCADE;
```

### Step 4: Review and Execute

**Action:** Present the generated DROP statements to the user grouped by phase.

- If `DRY_RUN = true`: Display all statements and stop. Ask user to confirm before executing.
- If `DRY_RUN = false`: Execute each DROP statement sequentially and report results.

**Always confirm before executing.** Show a summary count:
```
Objects to drop:
  Streamlit apps: N
  Tasks: N
  Dynamic tables: N
  Views: N
  Procedures: N
  Functions: N
  Tables: N
  Stages: N
  Integrations: N
  Network rules: N
  Schemas: N
  Databases: N
  ─────────────────
  Total: N objects
```

### Step 5: Verify Clean State

```sql
SHOW DATABASES LIKE 'AIRPORT_%';
SHOW INTEGRATIONS LIKE 'AIRPORT_%';
```

Expected: no results.

## Cleanup by Skill

To clean up objects from a single skill only:

| Skill | Tracking Name | Key Objects |
|-------|--------------|-------------|
| aviation-installer | `oss-aviation-installer` | All AIRPORT_XXX databases, EAIs, network rules |
| aviation-base-setup | `oss-aviation-base-setup` | PROPERTIES_*, HELPER_AIRLINE_DIM, UDFs, tags |
| aviation-adsb-ingestion | `oss-aviation-adsb-ingestion` | ADSB_DATA, HELPER_ADSB_*, procedures, tasks, EAIs |
| aviation-flight-schedules | `oss-aviation-flight-schedules` | FLIGHT_SCHEDULE, HELPER_FLIGHT_*, schedule procedures, TASK_FLIGHT_SCHEDULE |
| aviation-tsa-throughput | `oss-aviation-tsa-throughput` | TSA_THROUGHPUT, TSA_PDF_STAGE, TSA_PDF_PAGES_STAGE, TSA procedures, TASK_FETCH/EXTRACT_TSA_PDF, EAI |
| aviation-derived-analytics | `oss-aviation-derived-analytics` | All 13 Dynamic Tables, monitoring views, refresh procedures |
| aviation-dashboard | `oss-aviation-dashboard` | Streamlit app object |

## Examples

### Example 1: Clean up a single airport
User says: "Remove the SAN airport installation"
Actions:
1. Set AIRPORT_FILTER = `AIRPORT_SAN`
2. Discover all tagged objects in AIRPORT_SAN
3. Generate DROP statements (dry run), present summary
4. User confirms → execute all DROPs
5. Verify clean state
Result: `AIRPORT_SAN` database, all EAIs, network rules, and warehouse removed

### Example 2: Dry-run teardown of all airports
User says: "Show me what would be cleaned up for aviation"
Actions:
1. DRY_RUN = true (default)
2. Discover all AIRPORT_XXX databases and tagged objects
3. Present summary: "Found 3 databases, 42 tasks, 39 DTs, 15 EAIs..."
4. Do NOT execute — user reviews list
Result: DROP statements printed, nothing executed

### Example 3: Remove everything after a demo
User says: "Tear down the entire aviation demo environment"
Actions:
1. Discover all tagged objects across all AIRPORT_XXX databases
2. Generate and present DROP statements
3. User confirms → execute in dependency order
4. Verify no AIRPORT_XXX databases or EAIs remain
Result: Full environment cleaned up

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| No objects found | Wrong role | Check ACCOUNTADMIN role: `SELECT CURRENT_ROLE()` |
| Cannot drop task | Task is running | `ALTER TASK ... SUSPEND` first, then DROP |
| Dynamic table has dependents | Wrong drop order | Drop in reverse pipeline order (leaf DTs first, ADSB_DATA_LOCAL last) |
| EAI still exists after database drop | Account-level object | EAIs are account-level; drop them explicitly in Phase 5 |
| Database not empty after DROP TABLE cascade | Schema objects remain | Use `DROP SCHEMA ... CASCADE` then `DROP DATABASE ... CASCADE` |
| SHOW INTEGRATIONS shows unexpected EAIs | Multi-airport overlap | Check name pattern — may be from other airports; filter by specific airport prefix |
