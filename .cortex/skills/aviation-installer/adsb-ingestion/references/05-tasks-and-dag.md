# Task DAG

> **Placeholders** (replaced by the skill at generation time):
> - `{TARGET_DB}` — Snowflake database, e.g. `AIRPORT_SAN`
> - `{SCHEMA}` — Schema, e.g. `PUBLIC`
> - `{WAREHOUSE}` — Warehouse name
> - `{EAI_ADSB_LOL}` — External Access Integration name for adsb.lol (e.g. `AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI`)
> - `{EAI_GITHUB}` — External Access Integration name for GitHub (e.g. `AIRPORT_SAN_PUBLIC_GITHUB_EAI`)
> - `{API_URL}` — adsb.lol API endpoint with lat/lon/radius (e.g. `https://api.adsb.lol/v2/point/32.7336/-117.1897/27`)
> - `{BACKFILL_DAYS}` — Number of historical days to backfill (e.g. `7`)
> - `{IATA}` — Airport IATA code (e.g. `SAN`)

The **COMMENT tag** used on every `CREATE` statement:
```
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
```


---

## Step 6a: Root Task (TASK_INGEST_ADSB)

```sql
CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB
  WAREHOUSE = {WAREHOUSE}
  SCHEDULE = 'USING CRON 30 1 * * * UTC'
  ALLOW_OVERLAPPING_EXECUTION = FALSE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
  CALL {TARGET_DB}.{SCHEMA}.PROC_ADSB_INGEST_AND_ETL();

ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'realtime';
```

## Step 6b: Child Tasks (DAG)

> **Note:** Child tasks use the `AFTER` clause. The `COMMENT` clause is valid on `AFTER`-clause tasks but **must be placed before `AFTER`** (clause-ordering requirement). Governance tags are also applied via `ALTER TASK SET TAG`.

```sql
CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB
  WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AFTER {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB
AS
  CALL {TARGET_DB}.{SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(2);

ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'realtime';

-- NOTE: TASK_REFRESH_DERIVED and TASK_REFRESH_ANALYTICS are created by derived-analytics
-- (references/06b-tasks.md). They call PROC_REFRESH_DERIVED and PROC_REFRESH_ANALYTICS
-- which are defined in derived-analytics, so ownership belongs there.
```

Tasks are created **SUSPENDED**. Resume is handled by the installer router (Step 7).

---

