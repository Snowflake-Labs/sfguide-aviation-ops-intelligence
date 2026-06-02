# Tasks and Initial Load

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## TASK_FETCH_TSA_PDF

Weekly root task — fetches the latest TSA throughput PDF every Monday at 9am PT. Chained after `TASK_INGEST_ADSB` so the warehouse is guaranteed to be active.

```sql
CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_FETCH_TSA_PDF
  WAREHOUSE = {WAREHOUSE}
  SCHEDULE  = 'USING CRON 0 9 * * 1 America/Los_Angeles'
  COMMENT   = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
  CALL {TARGET_DB}.{SCHEMA}.PROC_FETCH_LATEST_TSA_PDF('@{TARGET_DB}.{SCHEMA}.TSA_PDF_STAGE');
```

> **Note:** Task is created SUSPENDED. The router resumes it after all tasks are ready.

---

## TASK_EXTRACT_TSA_PDF

Child task — runs after fetch completes, extracts data from the downloaded PDF.

> **Note:** Child tasks use `AFTER` clause. Snowflake does not allow `COMMENT` on `AFTER`-clause tasks; use `ALTER TASK SET TAG` instead.

```sql
CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_EXTRACT_TSA_PDF
  WAREHOUSE = {WAREHOUSE}
  AFTER     {TARGET_DB}.{SCHEMA}.TASK_FETCH_TSA_PDF
AS
  CALL {TARGET_DB}.{SCHEMA}.PROC_PROCESS_TSA_PDF(
    '@{TARGET_DB}.{SCHEMA}.TSA_PDF_PAGES_STAGE',
    '{TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT'
  );

ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_EXTRACT_TSA_PDF
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'tsa-throughput';
```

> **Note:** Task is created SUSPENDED. The router resumes it (child first, then root) after all tasks are ready.

---

## Initial Fetch and Extract (run at install time)

```sql
CALL {TARGET_DB}.{SCHEMA}.PROC_FETCH_LATEST_TSA_PDF('@{TARGET_DB}.{SCHEMA}.TSA_PDF_STAGE');
CALL {TARGET_DB}.{SCHEMA}.PROC_PROCESS_TSA_PDF('@{TARGET_DB}.{SCHEMA}.TSA_PDF_PAGES_STAGE', '{TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT');
```

---

## Verification

```sql
SELECT COUNT(*) AS TSA_ROWS FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT;
SELECT COUNT(DISTINCT airport_code) AS AIRPORTS FROM {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT;
```

Expected: > 0 rows if PDF was successfully downloaded and extracted.
