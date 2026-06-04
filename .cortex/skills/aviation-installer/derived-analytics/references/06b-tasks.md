# Tasks

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`

---

## Task DAG (child tasks)

> **Note:** Child tasks use the `AFTER` clause. The `COMMENT` clause is valid on `AFTER`-clause tasks but **must be placed before `AFTER`** (clause-ordering requirement). Governance tags are also applied via `ALTER TASK SET TAG`.

```sql
CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED
  WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AFTER {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_REFRESH_DERIVED();

CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS
  WAREHOUSE = {WAREHOUSE}
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
  AFTER {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED
  AS CALL {TARGET_DB}.{SCHEMA}.PROC_REFRESH_ANALYTICS();
```

## Tag Tasks

```sql
ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'realtime';

ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'realtime';
```
