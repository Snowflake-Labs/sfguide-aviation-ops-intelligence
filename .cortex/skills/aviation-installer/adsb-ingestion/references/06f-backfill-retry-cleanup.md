# Backfill Retry, Cleanup, and Tags

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

### PROC_RUN_BACKFILL_ONCE

```sql
-- Wrapper procedure invoked by the task; self-suspends the task after completion
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_RUN_BACKFILL_ONCE()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_once'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
from datetime import datetime, timedelta
import time

MAX_GATE_ATTEMPTS = 10
GATE_SLEEP_SECONDS = 30

def _get_config_backfill_days(session, default_days):
    # Read configured adsb_history_backfill_days from HELPER_MONITOR_LAST_REFRESH.
    try:
        rows = session.sql(
            "SELECT COALESCE(row_count_24h, %d) AS val FROM {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH "
            "WHERE table_name = 'CONFIG_ADSB_BACKFILL_DAYS'" % (int(default_days),)
        ).collect()
        return int(rows[0][0]) if rows else int(default_days)
    except Exception:
        return int(default_days)

def _is_backfill_complete(session, backfill_days):
    if backfill_days < 1:
        return True, 0, 0
    today = datetime.utcnow().date()
    start_date = today - timedelta(days=int(backfill_days))
    end_date = today - timedelta(days=1)
    try:
        rows = session.sql(
            "SELECT COUNT(*) AS cnt FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "WHERE data_date BETWEEN '%s'::DATE AND '%s'::DATE "
            "AND LOWER(download_status) = 'processed'"
            % (start_date.strftime('%Y-%m-%d'), end_date.strftime('%Y-%m-%d'))
        ).collect()
        processed = int(rows[0][0]) if rows else 0
        return processed >= int(backfill_days), processed, int(backfill_days)
    except Exception:
        return False, 0, int(backfill_days)

def _wait_for_backfill_complete(session, backfill_days):
    for attempt in range(MAX_GATE_ATTEMPTS):
        complete, processed, expected = _is_backfill_complete(session, backfill_days)
        if complete:
            return True, processed, expected
        if attempt < MAX_GATE_ATTEMPTS - 1:
            time.sleep(GATE_SLEEP_SECONDS)
    return False, processed, expected

def run_once(session):
    msg = ""
    try:
        res = session.sql("CALL {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_ADSB_HISTORY()").collect()
        msg = (res[0][0] if res else None) or ""

        # After backfill completes, wait for expected days to be fully processed before enrich/refresh.
        config_days = _get_config_backfill_days(session, {BACKFILL_DAYS})
        complete, processed, expected = _wait_for_backfill_complete(session, config_days)
        if not complete:
            msg += " | Backfill not complete (processed %d/%d days); continuing with enrichment" % (processed, expected)

        # Enrichment should still run even if today's history isn't available yet.
        try:
            enrich_res = session.sql(
                "CALL {TARGET_DB}.{SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(%d)" % (int(config_days),)
            ).collect()
            enrich_msg = (enrich_res[0][0] if enrich_res else None) or ""
            msg += " | " + enrich_msg
        except Exception as e:
            msg += " | Enrichment failed: " + str(e)[:200]

        # Always attempt a derived refresh after the backfill task completes.
        try:
            refresh_res = session.sql("CALL {TARGET_DB}.{SCHEMA}.PROC_REFRESH_DERIVED()").collect()
            refresh_msg = (refresh_res[0][0] if refresh_res else None) or ""
            if refresh_msg:
                msg += " | " + refresh_msg
        except Exception as e:
            msg += " | Derived refresh failed: " + str(e)[:200]
        
        # Trigger manual refresh of all Dynamic Tables (event-driven)
        try:
            session.sql("EXECUTE TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS").collect()
            msg += " | Analytics refreshed"
        except Exception as e:
            msg += " | Analytics refresh failed: " + str(e)[:200]
    except Exception as e:
        msg = "Backfill failed: " + str(e)[:200]
    # Always try to self-suspend the one-time task, even on errors.
    try:
        session.sql("ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_ONCE SUSPEND").collect()
    except Exception:
        pass
    return msg
$$;
```

### PROC_RUN_BACKFILL_RETRY_UTC

```sql
-- =============================================================================
-- Continuous retry backfill (UTC): keep trying yesterday + today until available,
-- and trigger enrichment + derived refresh only after the full configured window is processed.
-- This closes the "start-day gap" (midnight -> ingestion start time) as soon as
-- the daily history release for "today" becomes available (often the next day).
-- =============================================================================

CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_RUN_BACKFILL_RETRY_UTC()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_retry'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
from datetime import datetime, timedelta
import time

MAX_GATE_ATTEMPTS = 10
GATE_SLEEP_SECONDS = 30

def _get_status(session, date_str):
    try:
        rows = session.sql(
            "SELECT LOWER(download_status) AS st FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "WHERE data_date = '%s'::DATE" % (date_str,)
        ).collect()
        return (rows[0][0] if rows else None) or None
    except Exception:
        return None

def _ensure_row(session, date_str):
    try:
        session.sql(
            "MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS t "
            "USING (SELECT '%s'::DATE AS data_date) s ON t.data_date = s.data_date "
            "WHEN NOT MATCHED THEN INSERT (data_date, download_status) VALUES (s.data_date, 'pending')"
            % (date_str,)
        ).collect()
    except Exception:
        pass

def _get_config_backfill_days(session):
    # Read configured adsb_history_backfill_days from HELPER_MONITOR_LAST_REFRESH.
    try:
        rows = session.sql(
            "SELECT COALESCE(row_count_24h, 7) AS val FROM {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH "
            "WHERE table_name = 'CONFIG_ADSB_BACKFILL_DAYS'"
        ).collect()
        return int(rows[0][0]) if rows else 7
    except Exception:
        return 7

def _is_backfill_complete(session, backfill_days):
    if backfill_days < 1:
        return True, 0, 0
    today = datetime.utcnow().date()
    start_date = today - timedelta(days=int(backfill_days))
    end_date = today - timedelta(days=1)
    try:
        rows = session.sql(
            "SELECT COUNT(*) AS cnt FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "WHERE data_date BETWEEN '%s'::DATE AND '%s'::DATE "
            "AND LOWER(download_status) = 'processed'"
            % (start_date.strftime('%Y-%m-%d'), end_date.strftime('%Y-%m-%d'))
        ).collect()
        processed = int(rows[0][0]) if rows else 0
        return processed >= int(backfill_days), processed, int(backfill_days)
    except Exception:
        return False, 0, int(backfill_days)

def _wait_for_backfill_complete(session, backfill_days):
    for attempt in range(MAX_GATE_ATTEMPTS):
        complete, processed, expected = _is_backfill_complete(session, backfill_days)
        if complete:
            return True, processed, expected
        if attempt < MAX_GATE_ATTEMPTS - 1:
            time.sleep(GATE_SLEEP_SECONDS)
    return False, processed, expected

def run_retry(session):
    today = datetime.utcnow().date()
    dates = [today - timedelta(days=1), today]  # yesterday (expected) + today (best-effort)
    results = []

    # Read configured backfill window to use for enrichment lookback
    config_backfill_days = _get_config_backfill_days(session)
    max_enrich_days = config_backfill_days + 1  # +1 to cover edge cases

    for d in dates:
        date_str = d.strftime('%Y-%m-%d')
        _ensure_row(session, date_str)

        before = _get_status(session, date_str)
        if before == 'processed':
            results.append("%s: already processed" % (date_str,))
            continue

        # Process (download/extract/load/filter); this is resume-safe per date.
        try:
            r = session.sql("CALL {TARGET_DB}.{SCHEMA}.PROC_PROCESS_FROM_STAGE('%s')" % (date_str,)).collect()
            msg = (r[0][0] if r else None) or ""
        except Exception as e:
            msg = "process failed: " + str(e)[:200]

        after = _get_status(session, date_str)
        results.append("%s: %s (status=%s)" % (date_str, msg, after))

        # Defer enrichment/refresh until the full configured backfill window is processed.

    complete, processed, expected = _wait_for_backfill_complete(session, config_backfill_days)
    if complete:
        try:
            session.sql(
                "CALL {TARGET_DB}.{SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(%d)" % (int(max_enrich_days),)
            ).collect()
            session.sql("CALL {TARGET_DB}.{SCHEMA}.PROC_REFRESH_DERIVED()").collect()
            session.sql("EXECUTE TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS").collect()
            results.append("triggered enrich+refresh+analytics after backfill complete (processed=%d/%d)" % (processed, expected))
        except Exception as e:
            results.append("enrich/refresh/analytics failed after backfill complete: %s" % (str(e)[:200],))
    else:
        results.append("backfill not complete (processed %d/%d days); enrich/refresh skipped" % (processed, expected))

    return "\\n".join(results)
$$;
```

### PROC_START_BACKFILL_RETRY_UTC

```sql
-- Task wrapper: keep TASK body as a single CALL (installer statement-splitting safe)
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_START_BACKFILL_RETRY_UTC()
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
BEGIN
  EXECUTE IMMEDIATE '
    CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_RETRY
      WAREHOUSE = {WAREHOUSE}
      SCHEDULE = ''60 MINUTE''
      USER_TASK_TIMEOUT_MS = 21600000
      ALLOW_OVERLAPPING_EXECUTION = FALSE
      COMMENT = ''{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}''
    AS
      CALL {TARGET_DB}.{SCHEMA}.PROC_RUN_BACKFILL_RETRY_UTC();
  ';

  EXECUTE IMMEDIATE 'ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_RETRY RESUME';
  RETURN 'Started TASK_ADSB_BACKFILL_RETRY (yesterday+today UTC retry + enrich). Monitor HELPER_ADSB_BACKFILL_STATUS.';
END;
$$;
```

### PROC_CLEANUP_STAGE

```sql
-- =============================================================================
-- Procedure: Cleanup stage after processing
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_CLEANUP_STAGE(p_date VARCHAR)
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
BEGIN
    REMOVE @{TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE/:p_date/;
    RETURN 'Cleaned up ' || :p_date;
END;
$$;
```

---

## Step 8: Tags for All Backfill Objects

```sql
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_DOWNLOAD_TO_STAGE(VARCHAR)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_EXTRACT_TO_NDJSON(VARCHAR)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_LOAD_NDJSON_TO_INTERIM(VARCHAR)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_FILTER_AND_INSERT_SQL(VARCHAR)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_PROCESS_FROM_STAGE(VARCHAR)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_ADSB_HISTORY()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_START_BACKFILL_HISTORY()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_RUN_BACKFILL_ONCE()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_RUN_BACKFILL_RETRY_UTC()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_START_BACKFILL_RETRY_UTC()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_CLEANUP_STAGE(VARCHAR)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'backfill';
```

---

## Usage Reference

```sql
-- Download one day to stage:
--   CALL {TARGET_DB}.{SCHEMA}.PROC_DOWNLOAD_TO_STAGE('2025-12-15');
--
-- Process from stage:
--   CALL {TARGET_DB}.{SCHEMA}.PROC_PROCESS_FROM_STAGE('2025-12-15');
--
-- Backfill full week (download + process):
--   CALL {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_ADSB_HISTORY();
--
-- Check status:
--   SELECT * FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS;
--
-- Cleanup stage:
--   CALL {TARGET_DB}.{SCHEMA}.PROC_CLEANUP_STAGE('2025-12-15');
```
