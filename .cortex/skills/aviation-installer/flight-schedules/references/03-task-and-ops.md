# Task and Operational SQL

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`, `{BACKFILL_DAYS}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## TASK_FLIGHT_SCHEDULE

Chained after TASK_INGEST_ADSB — runs daily schedule sync.

```sql
CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_FLIGHT_SCHEDULE
  WAREHOUSE = {WAREHOUSE}
  AFTER {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
  CALL {TARGET_DB}.{SCHEMA}.PROC_FLIGHT_SCHEDULE_INGEST_AND_ETL();
```

> **Note:** Task is created SUSPENDED. The router resumes it via `PROC_RESUME_OPTIONAL_TASK` after all tasks are ready.

---

## Initial Backfill (run at install time)

```sql
CALL {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_FLIGHT_SCHEDULE_WINDOW({BACKFILL_DAYS}, 0);
```

---

## Verification

```sql
SELECT COUNT(*) AS RAW_ROWS FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW;
SELECT COUNT(*) AS SCHEDULE_ROWS FROM {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE;
```

Expected: > 0 rows if API key is valid and airport has scheduled service.
