# Historical Backfill Infrastructure

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

### PROC_PROCESS_FROM_STAGE

```sql
-- =============================================================================
-- Procedure: Combined process (Extract + Load + Filter)
-- Entry point that orchestrates the 3-step process
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_PROCESS_FROM_STAGE(p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'process_day'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
def process_day(session, p_date):
    # Snowflake Scripting does NOT allow "CALL ... INTO var" inside SQL procedures.
    # This Python orchestrator keeps the same behavior but safely captures return values.

    # Skip if already processed and raw has data for this date
    try:
        # IMPORTANT: avoid triple-quoted strings here because this procedure body itself is embedded
        # inside the installer's triple-quoted SQL templates.
        already_sql = (
            "SELECT IFF( "
            "  EXISTS ( "
            "    SELECT 1 FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            "    WHERE data_date = '" + p_date + "'::DATE AND LOWER(download_status) = 'processed' "
            "  ) "
            "  AND EXISTS ( "
            "    SELECT 1 FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW "
            "    WHERE timestamp::DATE = '" + p_date + "'::DATE LIMIT 1 "
            "  ), "
            "  1, 0 "
            ")"
        )
        already = session.sql(already_sql).collect()
        if already and int(already[0][0]) == 1:
            return "Already processed " + str(p_date)
    except Exception:
        # If this check fails for any reason, continue with processing (still restart-safe).
        pass

    def call1(sql):
        res = session.sql(sql).collect()
        return (res[0][0] if res else None) or ""

    # Step 0: Ensure TAR parts exist (download is resume-safe)
    download_msg = call1("CALL {TARGET_DB}.{SCHEMA}.PROC_DOWNLOAD_TO_STAGE('" + p_date + "')")
    low0 = (download_msg or "").lower()
    if ("download failed:" in low0) or ("no tar parts" in low0) or ("partial download:" in low0):
        return download_msg

    # Step 1: Extract TAR to stage (streaming)
    extract_msg = call1("CALL {TARGET_DB}.{SCHEMA}.PROC_EXTRACT_TO_NDJSON('" + p_date + "')")
    low = extract_msg.lower()
    if low.startswith("error") or low.startswith("tar error:") or ("no aircraft traces" in low):
        return download_msg + " | " + extract_msg

    # Step 2: Load extracted NDJSON batches
    load_msg = call1("CALL {TARGET_DB}.{SCHEMA}.PROC_LOAD_NDJSON_TO_INTERIM('" + p_date + "')")
    low = load_msg.lower()
    if low.startswith("error") or ("error loading" in low):
        return download_msg + " | " + extract_msg + " | " + load_msg

    # Step 3: Filter with SQL and insert
    filter_msg = call1("CALL {TARGET_DB}.{SCHEMA}.PROC_FILTER_AND_INSERT_SQL('" + p_date + "')")
    return download_msg + " | " + extract_msg + " | " + load_msg + " | " + filter_msg
$$;
```

### PROC_BACKFILL_ADSB_HISTORY

```sql
-- =============================================================================
-- Procedure: Backfill last {BACKFILL_DAYS} UTC days (download + process), ending yesterday
-- Configurable via installer UI.
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_ADSB_HISTORY()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'backfill_week'
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
from datetime import datetime, timedelta
import time

MAX_GATE_ATTEMPTS = 10
GATE_SLEEP_SECONDS = 30

def backfill_week(session):
    '''Backfill last N UTC days ending yesterday (N injected at install time).'''
    results = []
    
    end_date = datetime.utcnow().date() - timedelta(days=1)  # Yesterday
    n_days = {BACKFILL_DAYS}
    if n_days is None or int(n_days) < 1:
        return "Backfill skipped (adsb_history_backfill_days < 1)"
    start_date = end_date - timedelta(days=int(n_days) - 1)
    
    # Phase 1: Download all days
    results.append("=== DOWNLOADING ===")
    current = start_date
    while current <= end_date:
        date_str = current.strftime('%Y-%m-%d')
        try:
            result = session.sql(f"CALL {TARGET_DB}.{SCHEMA}.PROC_DOWNLOAD_TO_STAGE('{date_str}')").collect()
            msg = result[0][0] if result else "No result"
            results.append(f"{date_str}: {msg}")
        except Exception as e:
            results.append(f"{date_str}: Download error - {str(e)[:100]}")
        current += timedelta(days=1)
    
    # Phase 2: Process all days
    results.append("=== PROCESSING ===")
    current = start_date
    while current <= end_date:
        date_str = current.strftime('%Y-%m-%d')
        try:
            result = session.sql(f"CALL {TARGET_DB}.{SCHEMA}.PROC_PROCESS_FROM_STAGE('{date_str}')").collect()
            msg = result[0][0] if result else "No result"
            results.append(f"{date_str}: {msg}")
        except Exception as e:
            results.append(f"{date_str}: Process error - {str(e)[:100]}")
        current += timedelta(days=1)

    # Cleanup ONLY when all days are processed successfully
    try:
        start_str = start_date.strftime('%Y-%m-%d')
        end_str = end_date.strftime('%Y-%m-%d')
        processed_cnt = session.sql(
            f"SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS "
            f"WHERE data_date BETWEEN '{start_str}'::DATE AND '{end_str}'::DATE "
            f"AND LOWER(download_status) = 'processed'"
        ).collect()[0][0]
    except Exception:
        processed_cnt = 0

    if processed_cnt == int(n_days):
        # Avoid nested f-string braces here (this Python proc is generated by a Python f-string)
        results.append("=== CLEANUP (all %d days processed) ===" % int(n_days))
        current = start_date
        while current <= end_date:
            date_str = current.strftime('%Y-%m-%d')
            try:
                session.sql(f"CALL {TARGET_DB}.{SCHEMA}.PROC_CLEANUP_STAGE('{date_str}')").collect()
                results.append(f"{date_str}: cleaned stage")
            except Exception as e:
                results.append(f"{date_str}: cleanup error - {str(e)[:100]}")
            current += timedelta(days=1)
    else:
        results.append(f"=== CLEANUP SKIPPED (processed {processed_cnt}/{BACKFILL_DAYS} days) ===")
    
    return "\\n".join(results)
$$;
```

### PROC_START_BACKFILL_HISTORY

```sql
-- =============================================================================
-- Procedure: Kick off historical backfill as a one-time background task
-- Runs server-side, so Streamlit can be closed; task self-suspends when done.
-- =============================================================================
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_START_BACKFILL_HISTORY()
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
BEGIN
  -- Create/replace a one-time task that runs soon (every minute) and self-suspends after the first run.
  -- NOTE: Some Snowflake accounts/regions don't support SYSTEM$TASK_FORCE_RUN; we avoid it for portability.
  EXECUTE IMMEDIATE '
    CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_ONCE
      WAREHOUSE = {WAREHOUSE}
      SCHEDULE = ''1 MINUTE''
      -- 5-day backfill can take a while (downloads + extract + SQL filter). Give it room.
      USER_TASK_TIMEOUT_MS = 86400000
      ALLOW_OVERLAPPING_EXECUTION = FALSE
    AS
      CALL {TARGET_DB}.{SCHEMA}.PROC_RUN_BACKFILL_ONCE();
  ';

  EXECUTE IMMEDIATE 'ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ADSB_BACKFILL_ONCE RESUME';
  RETURN 'Started TASK_ADSB_BACKFILL_ONCE. It will run within ~1 minute and then self-suspend. Monitor {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS.';
END;
$$;
```

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
--
-- Resume tasks (leaf→root order):
--   ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_ANALYTICS RESUME;
--   ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_REFRESH_DERIVED RESUME;
--   ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_ADSB RESUME;
--   ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_AIRCRAFT_META RESUME;
--   ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_INGEST_ADSB RESUME;
```
