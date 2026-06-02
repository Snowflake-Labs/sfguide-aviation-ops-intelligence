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


