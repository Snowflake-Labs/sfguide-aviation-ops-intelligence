-- =============================================================================
-- STARTUP: Analytics Refresh, Task Resume, Backfill Start
-- Database: ${DATABASE}.${SCHEMA}
-- =============================================================================

-- Initialize ADSB_DATA_LOCAL (must exist before 06_dwell_core.sql runs)
ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL REFRESH;
-- NOTE: GATE_ANALYSIS_*, FLIGHT_TRAFFIC_*, FLIGHT_TRACKER_*, RUNWAY_CROSSINGS_*
-- REFRESH/RESUME are now handled in 06_dwell_core.sql (sql/compat/post_install.sql)
-- since those DTs are created by the modular layer, not by this file.

-- Verify derived tables (only tables created by this file; compat DTs verified in 06_dwell_core.sql)
SELECT 'ADSB_DATA_LOCAL' AS tbl, COUNT(*) AS cnt FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
UNION ALL SELECT 'HELPER_FLIGHT_LEG', COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_LEG
UNION ALL SELECT 'HELPER_FLIGHT_MATCH_CANDIDATES', COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES
UNION ALL SELECT 'HELPER_FLIGHT_MATCH_RESULT', COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_MATCH_RESULT
UNION ALL SELECT 'HELPER_RECURRING_CALLSIGN_PRIOR', COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR
UNION ALL SELECT 'FLIGHT_SCHEDULE', COUNT(*) FROM ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE
UNION ALL SELECT 'HELPER_FLIGHT_SCHEDULE_RAW', COUNT(*) FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW;

-- =============================================================================
-- ANALYTICS REFRESH TASK (Manual Dynamic Table Refresh)
-- =============================================================================
-- This task triggers manual refresh of all Dynamic Tables after enrichment completes.
-- Dynamic Tables are set to TARGET_LAG = DOWNSTREAM (no auto-refresh polling).
-- This ensures event-driven refresh: tables update once per day when data lands.

-- Create procedure to refresh all dynamic tables
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_REFRESH_ANALYTICS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  -- Refresh all Dynamic Tables in dependency order
  
  -- Base table (filters ADSB_DATA to local flights only)
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL REFRESH;
  
  -- Gate analysis tables (depend on ADSB_DATA_LOCAL)
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_GATE_UTIL_DAILY REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE REFRESH;
  
  -- Flight traffic analytics
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRACKER_FLIGHT_LIST REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY REFRESH;
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY REFRESH;
  
  -- Runway analysis
  ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.RUNWAY_CROSSINGS_DETAILED REFRESH;
  
  RETURN 'Dynamic tables refreshed successfully';
END;
$$;

-- =============================================================================
-- START AUTOMATED TASKS
-- =============================================================================
-- CRITICAL: For Task DAG, resume child tasks first (leaf to root), then root task LAST
-- This prevents "Unable to update graph" errors

-- Resume leaf tasks first (deepest in DAG)
ALTER TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_ANALYTICS RESUME;

-- Resume middle-level tasks (work backwards toward root)
ALTER TASK ${DATABASE}.${SCHEMA}.TASK_REFRESH_DERIVED RESUME;
ALTER TASK ${DATABASE}.${SCHEMA}.TASK_ENRICH_ADSB RESUME;

-- Resume FLIGHT_SCHEDULE task if it exists (optional, only created when API key provided)
-- Use stored procedure to handle optional task gracefully
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_RESUME_OPTIONAL_TASK(task_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  EXECUTE IMMEDIATE 'ALTER TASK ' || task_name || ' RESUME';
  RETURN 'Resumed: ' || task_name;
EXCEPTION
  WHEN STATEMENT_ERROR THEN
    RETURN 'Task does not exist (skipped): ' || task_name;
END;
$$;

CALL ${DATABASE}.${SCHEMA}.PROC_RESUME_OPTIONAL_TASK('${DATABASE}.${SCHEMA}.TASK_FLIGHT_SCHEDULE');

-- Resume independent scheduled tasks (not part of INGEST DAG)
ALTER TASK ${DATABASE}.${SCHEMA}.TASK_ENRICH_AIRCRAFT_META RESUME;

-- Resume ROOT task LAST (must be last to avoid graph update errors)
ALTER TASK ${DATABASE}.${SCHEMA}.TASK_INGEST_ADSB RESUME;

-- Resume ADSB_DATA_LOCAL (compat DT RESUME handled in 06_dwell_core.sql)
ALTER DYNAMIC TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL RESUME;

-- Run one enrichment pass immediately (populates schedule association fields on ADSB_DATA)
CALL ${DATABASE}.${SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(2);

-- Heartbeat
CALL ${DATABASE}.${SCHEMA}.PROC_REFRESH_DERIVED();

-- Fail fast if something is clearly wrong
CALL ${DATABASE}.${SCHEMA}.PROC_SMOKE_CHECK('10');

-- =============================================================================
-- START HISTORICAL BACKFILL (RUNS AT END OF INSTALLATION)
-- =============================================================================
-- All procedures and tables are now created. Safe to start backfill tasks.

-- Backfill recent history as a one-time background task (last ${ADSB_HISTORY_BACKFILL_DAYS} UTC days ending yesterday).
-- Safe to close Streamlit after this starts; progress is tracked in HELPER_ADSB_BACKFILL_STATUS.
CALL ${DATABASE}.${SCHEMA}.PROC_START_BACKFILL_HISTORY();

-- Start continuous retry for yesterday+today UTC, and trigger enrichment+derived refresh
-- after a day completes. This closes the "start-day gap" as soon as today's history
-- becomes available (often the next day).
CALL ${DATABASE}.${SCHEMA}.PROC_START_BACKFILL_RETRY_UTC();

-- Final verification
SELECT 'Setup complete! Tasks are now running automatically. Backfill started.' AS status;

-- Check backfill status
SELECT * FROM ${DATABASE}.${SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ORDER BY data_date;
"""
