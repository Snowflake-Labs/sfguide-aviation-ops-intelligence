-- =============================================================================
-- MONITORING, OPS PLACEHOLDERS, REFRESH & SMOKE CHECK
-- Database: ${DATABASE}.${SCHEMA}
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3b. Monitoring tables (used by Monitoring page)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH (
  table_name STRING,
  last_refreshed_at TIMESTAMP_NTZ,
  row_count_24h NUMBER(38,0),
  max_ts TIMESTAMP_NTZ,
  status STRING,
  details STRING
);

CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_QA_COUNTS_DAILY (
  metric_date DATE,
  metric_name STRING,
  metric_value NUMBER(38,0)
);

-- Ensure columns exist if table was created by an older installer version
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS row_count_24h NUMBER(38,0);
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS max_ts TIMESTAMP_NTZ;
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS status STRING;
ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH ADD COLUMN IF NOT EXISTS details STRING;

-- Store installer config: adsb_history_backfill_days (used by backfill retry enrichment)
MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH t
USING (SELECT 'CONFIG_ADSB_BACKFILL_DAYS' AS table_name, ${ADSB_HISTORY_BACKFILL_DAYS} AS row_count_24h) s
ON t.table_name = s.table_name
WHEN MATCHED THEN UPDATE SET row_count_24h = s.row_count_24h, last_refreshed_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (table_name, row_count_24h, last_refreshed_at) 
                      VALUES (s.table_name, s.row_count_24h, CURRENT_TIMESTAMP());

CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_INGEST_AUDIT (
  run_id STRING,
  airport_code STRING,
  window_start TIMESTAMP_NTZ,
  window_end TIMESTAMP_NTZ,
  rows_raw NUMBER(38,0),
  rows_inserted NUMBER(38,0),
  rows_deduped NUMBER(38,0),
  status STRING,
  error_message STRING,
  created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------------
-- 3c. Ops/performance placeholders (avoid dashboard hard errors; can be replaced later)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.H2H_CONFLICT_PAIRS (
  event_a_id STRING,
  event_b_id STRING,
  flight_a STRING,
  flight_b STRING,
  aircraft_a STRING,
  aircraft_b STRING,
  op_a STRING,
  op_b STRING,
  runway_mode STRING,
  a_start TIMESTAMP_NTZ,
  a_end TIMESTAMP_NTZ,
  b_start TIMESTAMP_NTZ,
  b_end TIMESTAMP_NTZ,
  min_gap_seconds NUMBER(38,0)
);

CREATE OR REPLACE VIEW ${DATABASE}.${SCHEMA}.V_AIR_OPS_TIMELINE AS
SELECT CAST(NULL AS DATE) AS service_date, CAST(NULL AS STRING) AS airline_name
WHERE 1=0;

CREATE OR REPLACE VIEW ${DATABASE}.${SCHEMA}.V_AIR_OPS_DAILY_KPIS AS
SELECT
  CAST(NULL AS DATE) AS service_date,
  CAST(NULL AS STRING) AS airline_name,
  CAST(NULL AS NUMBER(38,0)) AS ops,
  CAST(NULL AS FLOAT) AS med_taxi_out_min,
  CAST(NULL AS FLOAT) AS med_taxi_in_min,
  CAST(NULL AS FLOAT) AS med_dep_runway_occ_min,
  CAST(NULL AS FLOAT) AS med_arr_runway_occ_min,
  CAST(NULL AS FLOAT) AS on_time_dep_out_15m_rate,
  CAST(NULL AS FLOAT) AS on_time_arr_in_15m_rate,
  CAST(NULL AS BOOLEAN) AS head_to_head
WHERE 1=0;

-- -----------------------------------------------------------------------------
-- 4. Refresh procedure
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_REFRESH_DERIVED()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  v_adsb_cnt_24h NUMBER(38,0);
  v_adsb_max_ts TIMESTAMP_NTZ;
  v_sched_cnt_window NUMBER(38,0);
BEGIN
  -- Core table freshness (avoid full-table scans by limiting to recent window where possible)
  SELECT COUNT(*), MAX(TIMESTAMP)
    INTO :v_adsb_cnt_24h, :v_adsb_max_ts
  FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
  WHERE TIMESTAMP >= DATEADD('day', -1, SYSDATE());

  SELECT COUNT(*)
    INTO :v_sched_cnt_window
  FROM ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE
  WHERE FLIGHT_DATE BETWEEN DATEADD('day', -2, CURRENT_DATE()) AND DATEADD('day', 2, CURRENT_DATE());

  MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_MONITOR_LAST_REFRESH t
  USING (
    SELECT 'ADSB_DATA_LOCAL' AS table_name,
           SYSDATE() AS ts,
           :v_adsb_cnt_24h AS row_count_24h,
           :v_adsb_max_ts AS max_ts,
           IFF(:v_adsb_max_ts IS NOT NULL AND :v_adsb_max_ts >= DATEADD('hour', -2, SYSDATE()), 'OK', 'STALE') AS status,
           IFF(:v_adsb_max_ts IS NULL, 'No relevant ADS-B data yet', NULL) AS details
    UNION ALL
    SELECT 'FLIGHT_SCHEDULE', SYSDATE(), :v_sched_cnt_window, NULL,
           IFF(:v_sched_cnt_window > 0, 'OK', 'EMPTY'),
           IFF(:v_sched_cnt_window = 0, 'No schedule rows in current +/-2 day window', NULL)
  ) s
  ON t.table_name = s.table_name
  WHEN MATCHED THEN UPDATE SET
    last_refreshed_at = s.ts,
    row_count_24h = s.row_count_24h,
    max_ts = s.max_ts,
    status = s.status,
    details = s.details
  WHEN NOT MATCHED THEN INSERT (table_name, last_refreshed_at, row_count_24h, max_ts, status, details)
    VALUES (s.table_name, s.ts, s.row_count_24h, s.max_ts, s.status, s.details);

  -- QA completeness metrics for last 24h (integer percent 0-100)
  MERGE INTO ${DATABASE}.${SCHEMA}.HELPER_QA_COUNTS_DAILY t
  USING (
    WITH base AS (
      SELECT
        COUNT(*) AS cnt,
        COUNT_IF(FLIGHT IS NOT NULL AND TRIM(FLIGHT) <> '') AS nn_flight,
        COUNT_IF(TRACK IS NOT NULL) AS nn_track,
        COUNT_IF(TRUE_HEADING IS NOT NULL) AS nn_true_heading,
        COUNT_IF(SQUAWK IS NOT NULL AND TRIM(SQUAWK) <> '') AS nn_squawk,
        COUNT_IF(CATEGORY IS NOT NULL AND TRIM(CATEGORY) <> '') AS nn_category,
        COUNT_IF(AIRCRAFT_DESC IS NOT NULL AND TRIM(AIRCRAFT_DESC) <> '') AS nn_aircraft_desc,
        COUNT_IF(ALTITUDE_GEOM IS NOT NULL) AS nn_alt_geom,
        COUNT_IF(VERTICAL_RATE IS NOT NULL) AS nn_vertical_rate,
        COUNT_IF(SCHEDULE_FLIGHT_KEY IS NOT NULL) AS nn_matched,
        COUNT(DISTINCT ICAO_HEX) AS unique_aircraft
      FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL
      WHERE TIMESTAMP >= DATEADD('day', -1, SYSDATE())
    ),
    legs AS (
      SELECT COUNT(*) AS leg_cnt
      FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_LEG
      WHERE SERVICE_DATE >= DATEADD('day', -1, CURRENT_DATE())
    ),
    leg_matches AS (
      SELECT COUNT(*) AS matched_leg_cnt
      FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_MATCH_RESULT
      WHERE SERVICE_DATE >= DATEADD('day', -1, CURRENT_DATE())
    )
    SELECT CURRENT_DATE() AS metric_date, 'adsb_points_24h' AS metric_name, cnt::NUMBER(38,0) AS metric_value FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_flight_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_flight/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_track_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_track/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_true_heading_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_true_heading/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_squawk_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_squawk/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_category_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_category/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_aircraft_desc_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_aircraft_desc/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_alt_geom_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_alt_geom/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'adsb_vertical_rate_nonnull_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_vertical_rate/cnt))::NUMBER(38,0) FROM base
    -- Flight matching health metrics
    UNION ALL SELECT CURRENT_DATE(), 'match_rate_pct_24h', IFF(cnt=0, NULL, ROUND(100*nn_matched/cnt))::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'unique_aircraft_24h', unique_aircraft::NUMBER(38,0) FROM base
    UNION ALL SELECT CURRENT_DATE(), 'flight_legs_24h', leg_cnt::NUMBER(38,0) FROM legs
    UNION ALL SELECT CURRENT_DATE(), 'matched_legs_24h', matched_leg_cnt::NUMBER(38,0) FROM leg_matches
    UNION ALL SELECT CURRENT_DATE(), 'leg_match_rate_pct_24h', IFF((SELECT leg_cnt FROM legs)=0, NULL, ROUND(100*(SELECT matched_leg_cnt FROM leg_matches)/(SELECT leg_cnt FROM legs)))::NUMBER(38,0)
  ) s
  ON t.metric_date = s.metric_date AND t.metric_name = s.metric_name
  WHEN MATCHED THEN UPDATE SET metric_value = s.metric_value
  WHEN NOT MATCHED THEN INSERT (metric_date, metric_name, metric_value) VALUES (s.metric_date, s.metric_name, s.metric_value);

  RETURN 'Monitoring + QA updated';
END;
$$;

-- -----------------------------------------------------------------------------
-- Smoke check (fail the installer loudly if core invariants aren't met)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_SMOKE_CHECK(p_grace_minutes STRING)
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
function scalar(sqlText) {
  var stmt = snowflake.createStatement({sqlText});
  var rs = stmt.execute();
  rs.next();
  return rs.getColumnValue(1);
}

// Snowflake JS sprocs reliably expose parameters via `arguments[]`
var p_grace_minutes = arguments[0];

function minutesSinceInstall() {
  try {
    var mins = scalar(`SELECT DATEDIFF('minute', MAX(installed_at), CURRENT_TIMESTAMP()) FROM ${DATABASE}.${SCHEMA}.HELPER_INSTALL_AUDIT`);
    if (mins === null) return 999999;
    return mins;
  } catch (e) {
    return 999999;
  }
}

var grace = 10;
if (p_grace_minutes !== null) {
  var parsed = parseInt(p_grace_minutes, 10);
  if (!isNaN(parsed)) grace = parsed;
}
var minsSince = minutesSinceInstall();

// Runways: at least 1 row and non-null geometry (may be split into multiple polygons)
var runwayCnt = scalar(`SELECT COUNT(*) FROM ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS`);
if (runwayCnt < 1) {
  throw `Smoke check failed: PROPERTIES_RUNWAYS must have at least 1 row, got ${runwayCnt}`;
}
var runwayNonNull = scalar(`SELECT COUNT_IF(runway_geog IS NOT NULL) FROM ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS`);
if (runwayNonNull < 1) {
  throw `Smoke check failed: PROPERTIES_RUNWAYS.runway_geog is NULL`;
}

// ADS-B freshness: expect points within last 2 hours once tasks are running
var maxTs = scalar(`SELECT MAX(TIMESTAMP) FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL`);
if (maxTs === null) {
  if (minsSince <= grace) {
    return `WAITING_FOR_ADSB_DATA (installed ${minsSince} min ago; grace=${grace}m)`;
  }
  throw `Smoke check failed: ADSB_DATA_LOCAL is empty (MAX(TIMESTAMP) is NULL)`;
}
var fresh = scalar(`SELECT IFF(MAX(TIMESTAMP) >= DATEADD('hour', -2, SYSDATE()), 1, 0) FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL`);
if (fresh !== 1) {
  if (minsSince <= grace) {
    return `WAITING_FOR_ADSB_DATA (stale during grace window; installed ${minsSince} min ago; grace=${grace}m; max_ts=${maxTs})`;
  }
  throw `Smoke check failed: ADSB_DATA_LOCAL appears stale (no points in last 2 hours). max_ts=${maxTs}`;
}

// Flight schedule: check if data exists (optional, may be empty if no API key provided)
var schedCnt = scalar(`SELECT COUNT(*) FROM ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE WHERE FLIGHT_DATE BETWEEN DATEADD('day', -2, CURRENT_DATE()) AND DATEADD('day', 2, CURRENT_DATE())`);
// Note: schedule may be empty if API key was not provided during install

// Tasks should be STARTED (check for flight schedule task separately)
snowflake.createStatement({sqlText: `SHOW TASKS IN SCHEMA ${DATABASE}.${SCHEMA}`}).execute();
var schedTaskExists = scalar(`SELECT COUNT_IF(\"name\"='TASK_FLIGHT_SCHEDULE') FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`);
var requiredTasksRunning = scalar(`SELECT COUNT_IF(LOWER(\"state\")='started' AND \"name\" IN ('TASK_INGEST_ADSB','TASK_ENRICH_ADSB','TASK_REFRESH_DERIVED')) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`);
var schedTaskRunning = scalar(`SELECT COUNT_IF(LOWER(\"state\")='started' AND \"name\"='TASK_FLIGHT_SCHEDULE') FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`);

// Core tasks (ADS-B ingestion, enrichment, derived refresh) must be running
if (requiredTasksRunning < 3) {
  throw `Smoke check failed: not all core ADS-B tasks are STARTED (started=${requiredTasksRunning}/3)`;
}

// Flight schedule task is optional (only exists if API key was provided)
if (schedTaskExists > 0 && schedTaskRunning === 0) {
  throw `Smoke check failed: TASK_FLIGHT_SCHEDULE exists but is not STARTED`; 
}

return 'OK';
$$;

