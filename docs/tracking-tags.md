# Tracking Tags Reference

This document describes the tracking tag system used across all skills in this repository. It is designed to be self-contained so that Cortex Code (or any other AI agent) can read it and build internal Snowflake dashboards for monitoring solution usage, cost attribution, and object lifecycle.

## Overview

Every skill in this repository uses two complementary tracking mechanisms:

1. **Session `query_tag`** -- a JSON string set via `ALTER SESSION SET query_tag` at the start of every SQL session. This tags every query executed in that session in `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY`.
2. **Object `COMMENT`** -- a JSON string attached to every Snowflake object created by a skill. This enables object discovery via `INFORMATION_SCHEMA` and `SHOW` commands.

Both mechanisms use the same origin identifier: `sf_sit-is-aviation`.

### Why Two Mechanisms?

| Mechanism | Tracks | Queryable Via | Use Case |
|-----------|--------|---------------|----------|
| `query_tag` | Queries (SELECT, INSERT, CALL, etc.) | `QUERY_HISTORY` | Cost attribution, query volume, performance analysis |
| Object `COMMENT` | Created objects (TABLE, VIEW, etc.) | `INFORMATION_SCHEMA`, `SHOW` | Object inventory, cleanup automation, lifecycle tracking |

Together they provide full observability: which skill created which objects, and which skill ran which queries.

## Tag Formats

### Skill-Level Tags

Used by all deployment/demo skills.

#### query_tag Format

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-<skill-name>","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

#### Object COMMENT Format

```sql
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-<skill-name>","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"<sql|notebook|app>"}}';
```

For CTAS (CREATE TABLE AS SELECT) or objects that don't support inline COMMENT:

```sql
CREATE TABLE ... AS SELECT ...;
ALTER TABLE <name> SET COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-<skill-name>","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

#### JSON Schema (Skill-Level)

```json
{
  "origin": "sf_sit-is-aviation",
  "name": "oss-<skill-tracking-name>",
  "version": {
    "major": 1,
    "minor": 0
  },
  "attributes": {
    "is_quickstart": 1,
    "source": "<sql|notebook|app>"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `origin` | string | Always `sf_sit-is-aviation`. Global identifier for this solution. |
| `name` | string | Skill tracking name, prefixed with `oss-`. Unique per skill. |
| `version.major` | integer | Major version of the skill. |
| `version.minor` | integer | Minor version of the skill. |
| `attributes.is_quickstart` | integer | Always `1`. Indicates this is a quickstart/demo asset. |
| `attributes.source` | string | How the object was created: `sql`, `notebook` or `app`. |


## Per-Skill Object Inventory

### base-setup

**Tracking name:** `oss-aviation-base-setup`

| Object | Type | Location |
|--------|------|----------|
| `{TARGET_DB}` | Database | Account |
| `{TARGET_DB}.{SCHEMA}` (PUBLIC) | Schema | `{TARGET_DB}` |
| `{TARGET_DB}.TAGS` | Schema | `{TARGET_DB}` |
| `AVIA_{IATA}_WH` | Warehouse | Account |
| `{TARGET_DB}.TAGS.SOLUTION` | Tag | `{TARGET_DB}.TAGS` |
| `{TARGET_DB}.TAGS.COMPONENT` | Tag | `{TARGET_DB}.TAGS` |
| `{TARGET_DB}.{SCHEMA}.UDF_TZID_FROM_LATLON` | Function (Python) | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.GET_OSM_TAG` | Function (SQL) | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.ST_GETPOLYGONS` | Function (JavaScript UDTF) | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.PROPERTIES_INFRASTRUCTURE` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.PROPERTIES_GATES` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.TEMP_RUNWAY_*` (4 tables) | Table (temporary, dropped) | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.FF_AIRLINES_CSV` | File Format | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_INSTALL_AUDIT` | Table | `{TARGET_DB}.{SCHEMA}` |

### adsb-ingestion

**Tracking name:** `oss-aviation-adsb-ingestion`

| Object | Type | Location |
|--------|------|----------|
| `{SCHEMA}_adsb_lol_rule` | Network Rule | `{TARGET_DB}.{SCHEMA}` |
| `{SCHEMA}_github_rule` | Network Rule | `{TARGET_DB}.{SCHEMA}` |
| `{EAI_ADSB_LOL}` (e.g. `AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI`) | External Access Integration | Account |
| `{EAI_GITHUB}` (e.g. `AIRPORT_SAN_PUBLIC_GITHUB_EAI`) | External Access Integration | Account |
| `{TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_AIRCRAFT_META` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.ADSB_DATA` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_RESULT` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE` | Stage | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS` | Table | `{TARGET_DB}.{SCHEMA}` |
| `{TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM` | Table | `{TARGET_DB}.{SCHEMA}` |
| `PROC_INGEST_ADSB_REALTIME` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_ETL_ADSB_TO_DATA` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_DEDUP_ADSB_DATA` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_ADSB_INGEST_AND_ETL` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_ENRICH_ADSB_WITH_SCHEDULE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_ENRICH_AIRCRAFT_META` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_BACKFILL_ADSB_AIRCRAFT_DESC` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_ENRICH_AIRCRAFT_META_AND_BACKFILL` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_DOWNLOAD_TO_STAGE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_EXTRACT_TO_NDJSON` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_LOAD_NDJSON_TO_INTERIM` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_FILTER_AND_INSERT_SQL` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_PROCESS_FROM_STAGE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_BACKFILL_ADSB_HISTORY` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_RUN_BACKFILL_ONCE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_RUN_BACKFILL_RETRY_UTC` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_START_BACKFILL_HISTORY` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_START_BACKFILL_RETRY_UTC` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_CLEANUP_STAGE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `TASK_INGEST_ADSB` | Task | `{TARGET_DB}.{SCHEMA}` |
| `TASK_ENRICH_ADSB` | Task | `{TARGET_DB}.{SCHEMA}` |
| `TASK_ENRICH_AIRCRAFT_META` | Task | `{TARGET_DB}.{SCHEMA}` |
| `TASK_ADSB_BACKFILL_ONCE` | Task (dynamic) | `{TARGET_DB}.{SCHEMA}` |
| `TASK_ADSB_BACKFILL_RETRY` | Task (dynamic) | `{TARGET_DB}.{SCHEMA}` |

### flight-schedules

**Tracking name:** `oss-aviation-flight-schedules`

| Object | Type | Location |
|--------|------|----------|
| `{SCHEMA}_aviationstack_rule` | Network Rule | `{TARGET_DB}.{SCHEMA}` |
| `aviationstack_key` | Secret | `{TARGET_DB}.{SCHEMA}` |
| `{EAI_AVIATIONSTACK}` (e.g. `AIRPORT_SAN_PUBLIC_AVIATIONSTACK_EAI`) | External Access Integration | Account |
| `HELPER_FLIGHT_SCHEDULE_RAW` | Table | `{TARGET_DB}.{SCHEMA}` |
| `FLIGHT_SCHEDULE` | Table | `{TARGET_DB}.{SCHEMA}` |
| `PROC_INGEST_FLIGHT_SCHEDULE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_ETL_SCHEDULE_TO_FLIGHT_SCHEDULE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_BACKFILL_FLIGHT_SCHEDULE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_BACKFILL_FLIGHT_SCHEDULE_WINDOW` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_FLIGHT_SCHEDULE_INGEST_AND_ETL` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `TASK_FLIGHT_SCHEDULE` | Task | `{TARGET_DB}.{SCHEMA}` |

### tsa-throughput

**Tracking name:** `oss-aviation-tsa-throughput`

| Object | Type | Location |
|--------|------|----------|
| `{SCHEMA}_tsa_gov_rule` | Network Rule | `{TARGET_DB}.{SCHEMA}` |
| `{EAI_TSA_GOV}` (e.g. `AIRPORT_SAN_PUBLIC_TSA_GOV_EAI`) | External Access Integration | Account |
| `TSA_PDF_STAGE` | Stage | `{TARGET_DB}.{SCHEMA}` |
| `TSA_PDF_PAGES_STAGE` | Stage | `{TARGET_DB}.{SCHEMA}` |
| `TSA_THROUGHPUT` | Table | `{TARGET_DB}.{SCHEMA}` |
| `PROC_FETCH_PDF_TO_STAGE` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_FETCH_LATEST_TSA_PDF` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_PROCESS_TSA_PDF` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `TASK_FETCH_TSA_PDF` | Task | `{TARGET_DB}.{SCHEMA}` |
| `TASK_EXTRACT_TSA_PDF` | Task | `{TARGET_DB}.{SCHEMA}` |

### derived-analytics

**Tracking name:** `oss-aviation-derived-analytics`

| Object | Type | Location |
|--------|------|----------|
| `ADSB_DATA_LOCAL` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `GATE_ANALYSIS_ADSB_GROUND_POINTS` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `GATE_ANALYSIS_FLIGHT_GATE_TIME` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `GATE_ANALYSIS_GATE_UTIL_DAILY` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `FLIGHT_TRAFFIC_FACT_ADSB_DAILY` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `FLIGHT_TRAFFIC_FACT_ADSB_HOURLY` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `FLIGHT_TRACKER_FLIGHT_LIST` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `RUNWAY_CROSSINGS_DETAILED` | Dynamic Table | `{TARGET_DB}.{SCHEMA}` |
| `HELPER_LANDING_LIVE_TIMETABLE` | View | `{TARGET_DB}.{SCHEMA}` |
| `V_AIR_OPS_TIMELINE` | View | `{TARGET_DB}.{SCHEMA}` |
| `V_AIR_OPS_DAILY_KPIS` | View | `{TARGET_DB}.{SCHEMA}` |
| `V_TSA_CHECKPOINT_GEO` | View | `{TARGET_DB}.{SCHEMA}` |
| `HELPER_MONITOR_LAST_REFRESH` | Table | `{TARGET_DB}.{SCHEMA}` |
| `HELPER_QA_COUNTS_DAILY` | Table | `{TARGET_DB}.{SCHEMA}` |
| `HELPER_INGEST_AUDIT` | Table | `{TARGET_DB}.{SCHEMA}` |
| `H2H_CONFLICT_PAIRS` | Table | `{TARGET_DB}.{SCHEMA}` |
| `PROC_REFRESH_DERIVED` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_REFRESH_ANALYTICS` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_SMOKE_CHECK` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `PROC_RESUME_OPTIONAL_TASK` | Procedure | `{TARGET_DB}.{SCHEMA}` |
| `TASK_REFRESH_DERIVED` | Task | `{TARGET_DB}.{SCHEMA}` |
| `TASK_REFRESH_ANALYTICS` | Task | `{TARGET_DB}.{SCHEMA}` |

### aviation-dashboard

**Tracking name:** `oss-aviation-dashboard`

#### Streamlit variant

| Object | Type | Location |
|--------|------|----------|
| `{APP_NAME}` (e.g. `AIRPORT_ANALYTICS_DASHBOARD`) | Streamlit | `{TARGET_DB}.{SCHEMA}` |

#### React/SPCS variant (additional objects)

| Object | Type | Location |
|--------|------|----------|
| `AVIATION_DASHBOARD_REPO` | Image Repository | `{TARGET_DB}.PUBLIC` |
| `AVIATION_CARTO_NETWORK_RULE` | Network Rule | `{TARGET_DB}.PUBLIC` |
| `{TARGET_DB}_AVIATION_CARTO_EAI` | External Access Integration | Account |
| `AVIATION_DASHBOARD_COMPUTE_POOL` | Compute Pool | Account |
| `AVIATION_DASHBOARD_SERVICE` | Service | `{TARGET_DB}.PUBLIC` |

### aviation-cleanup

**Tracking name:** `oss-aviation-cleanup`

Creates no objects. This skill discovers and removes objects created by other skills.


## Dashboard SQL Queries

The following queries can be used to build Snowflake dashboards for monitoring the solution.

### Query 1: All Tagged Objects by Skill (Tables and Views)

```sql
SELECT
    TABLE_CATALOG AS DATABASE_NAME,
    TABLE_SCHEMA AS SCHEMA_NAME,
    TABLE_NAME AS OBJECT_NAME,
    TABLE_TYPE AS OBJECT_TYPE,
    PARSE_JSON(COMMENT):origin::STRING AS ORIGIN,
    PARSE_JSON(COMMENT):name::STRING AS SKILL_NAME,
    PARSE_JSON(COMMENT):version AS VERSION,
    PARSE_JSON(COMMENT):attributes:source::STRING AS SOURCE_TYPE,
    CREATED AS CREATED_AT,
    LAST_ALTERED AS LAST_MODIFIED
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND COMMENT LIKE '%sf_sit-is-aviation%'
ORDER BY SKILL_NAME, DATABASE_NAME, SCHEMA_NAME, OBJECT_NAME;
```

### Query 2: Object Count by Skill

```sql
SELECT
    PARSE_JSON(COMMENT):name::STRING AS SKILL_NAME,
    TABLE_TYPE AS OBJECT_TYPE,
    COUNT(*) AS OBJECT_COUNT
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND COMMENT LIKE '%sf_sit-is-aviation%'
GROUP BY 1, 2
ORDER BY 1, 2;
```

### Query 3: All Queries by Skill (from QUERY_HISTORY)

```sql
SELECT
    PARSE_JSON(QUERY_TAG):name::STRING AS SKILL_NAME,
    PARSE_JSON(QUERY_TAG):attributes:source::STRING AS SOURCE_TYPE,
    DATE_TRUNC('day', START_TIME) AS QUERY_DATE,
    COUNT(*) AS QUERY_COUNT,
    SUM(TOTAL_ELAPSED_TIME) / 1000 AS TOTAL_ELAPSED_SECS,
    SUM(CREDITS_USED_CLOUD_SERVICES) AS CLOUD_CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TAG LIKE '%sf_sit-is-aviation%'
  AND START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
ORDER BY 3 DESC, 1;
```

### Query 4: Cost Attribution by Skill (Credits)

```sql
SELECT
    PARSE_JSON(QUERY_TAG):name::STRING AS SKILL_NAME,
    WAREHOUSE_NAME,
    DATE_TRUNC('week', START_TIME) AS WEEK,
    COUNT(*) AS QUERY_COUNT,
    ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 4) AS CLOUD_CREDITS,
    ROUND(AVG(TOTAL_ELAPSED_TIME) / 1000, 2) AS AVG_ELAPSED_SECS,
    ROUND(MAX(TOTAL_ELAPSED_TIME) / 1000, 2) AS MAX_ELAPSED_SECS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TAG LIKE '%sf_sit-is-aviation%'
  AND START_TIME >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
ORDER BY 3 DESC, 5 DESC;
```

### Query 5: Object Lifecycle (Recently Created/Modified)

```sql
SELECT
    PARSE_JSON(COMMENT):name::STRING AS SKILL_NAME,
    TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME AS FULL_NAME,
    TABLE_TYPE,
    CREATED,
    LAST_ALTERED,
    DATEDIFF('day', CREATED, CURRENT_TIMESTAMP()) AS AGE_DAYS
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND COMMENT LIKE '%sf_sit-is-aviation%'
ORDER BY CREATED DESC
LIMIT 50;
```

### Query 6: Tagged Warehouses

```sql
SHOW WAREHOUSES;
SELECT
    "name" AS WAREHOUSE_NAME,
    PARSE_JSON("comment"):name::STRING AS SKILL_NAME,
    "size" AS WAREHOUSE_SIZE,
    "state" AS STATE,
    "auto_suspend" AS AUTO_SUSPEND_SECS
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" LIKE '%sf_sit-is-aviation%';
```

### Query 7: Tagged Stages

```sql
SHOW STAGES IN DATABASE {TARGET_DB};
SELECT
    "database_name" AS DB,
    "schema_name" AS SCHEMA,
    "name" AS STAGE_NAME,
    PARSE_JSON("comment"):name::STRING AS SKILL_NAME
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" LIKE '%sf_sit-is-aviation%';
```

### Query 8: Tagged Procedures and Functions

```sql
SELECT
    FUNCTION_CATALOG AS DATABASE_NAME,
    FUNCTION_SCHEMA AS SCHEMA_NAME,
    FUNCTION_NAME,
    DATA_TYPE AS RETURN_TYPE,
    PARSE_JSON(COMMENT):name::STRING AS SKILL_NAME
FROM SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS
WHERE DELETED IS NULL
  AND COMMENT LIKE '%sf_sit-is-aviation%'
ORDER BY SKILL_NAME, FUNCTION_NAME;
```

### Query 9: Tagged Schemas

```sql
SHOW SCHEMAS IN DATABASE {TARGET_DB};
SELECT
    "database_name" AS DB,
    "name" AS SCHEMA_NAME,
    PARSE_JSON("comment"):name::STRING AS SKILL_NAME
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" LIKE '%sf_sit-is-aviation%';
```

### Query 10: Tagged Databases

```sql
SHOW DATABASES;
SELECT
    "name" AS DATABASE_NAME,
    PARSE_JSON("comment"):name::STRING AS SKILL_NAME,
    "created_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "comment" LIKE '%sf_sit-is-aviation%';
```

### Query 11: Cross-Reference Objects vs Queries

```sql
WITH objects AS (
    SELECT DISTINCT PARSE_JSON(COMMENT):name::STRING AS SKILL_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
    WHERE DELETED IS NULL AND COMMENT LIKE '%sf_sit-is-aviation%'
),
queries AS (
    SELECT
        PARSE_JSON(QUERY_TAG):name::STRING AS SKILL_NAME,
        COUNT(*) AS QUERY_COUNT_30D,
        MAX(START_TIME) AS LAST_QUERY
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE QUERY_TAG LIKE '%sf_sit-is-aviation%'
      AND START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    GROUP BY 1
)
SELECT
    COALESCE(o.SKILL_NAME, q.SKILL_NAME) AS SKILL_NAME,
    IFF(o.SKILL_NAME IS NOT NULL, 'YES', 'NO') AS HAS_OBJECTS,
    COALESCE(q.QUERY_COUNT_30D, 0) AS QUERIES_LAST_30D,
    q.LAST_QUERY
FROM objects o
FULL OUTER JOIN queries q ON o.SKILL_NAME = q.SKILL_NAME
ORDER BY SKILL_NAME;
```

## Dashboard Query Tracking

The Streamlit dashboard sets a session `query_tag` on every connection:

| Mode | Tag Format | Tracking Name |
|------|------------|---------------|
| Streamlit (skills) | JSON query_tag | `oss-aviation-dashboard` |
| Streamlit (standalone) | JSON query_tag | `oss-aviation-dashboard` |
| React/SPCS | JSON query_tag (prepended to each SQL API call) | `oss-aviation-dashboard` |

## Skill Tracking Name Reference

| Skill | Tracking Name |
|-------|---------------|
| aviation-installer | `oss-aviation-installer` |
| base-setup | `oss-aviation-base-setup` |
| adsb-ingestion | `oss-aviation-adsb-ingestion` |
| flight-schedules | `oss-aviation-flight-schedules` |
| tsa-throughput | `oss-aviation-tsa-throughput` |
| derived-analytics | `oss-aviation-derived-analytics` |
| aviation-dashboard | `oss-aviation-dashboard` |
| aviation-cleanup | `oss-aviation-cleanup` |
| Standalone Installer | `oss-aviation-<sub-skill>` (per-function) |

## Known Limitations

1. **Dynamically created tasks** (`TASK_ADSB_BACKFILL_ONCE`, `TASK_ADSB_BACKFILL_RETRY`) are created at runtime by stored procedures. They carry COMMENT tags set within the procedure body.

2. **Account-level objects** (EAIs, network rules) that don't support COMMENT use consistent naming patterns (`{TARGET_DB}_{SCHEMA}_{SERVICE}_EAI`, `{SCHEMA}_{service}_rule`) so `aviation-cleanup` can discover them by name.

3. **Temporary CTAS tables** (`TEMP_RUNWAY_*`) in base-setup are tagged via `ALTER TABLE SET COMMENT` immediately after creation, then dropped at the end of the runway pipeline. Tags exist only briefly.

4. **Cost-attribution tags** (TAG objects in `{TARGET_DB}.TAGS` schema) provide a secondary tracking mechanism via `TAG_REFERENCES`. These are complementary to COMMENT tracking and not required for the dashboard queries above.

## Compliance Rules

Per AGENTS.md, the following rules are mandatory with no exceptions:

- Every new Snowflake object MUST have a COMMENT tracking tag
- Every SQL session MUST set `query_tag` before executing statements
- For CTAS or dynamic SQL, use `ALTER ... SET COMMENT` immediately after creation
- For account-level objects that don't support COMMENT, use consistent naming patterns for discovery
- This applies to all skills, installer app, stored procedures, dynamic SQL, and any other code path
