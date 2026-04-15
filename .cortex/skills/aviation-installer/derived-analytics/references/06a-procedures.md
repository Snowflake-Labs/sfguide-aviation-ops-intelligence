# Procedures

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`, `{IATA}`, `{BACKFILL_DAYS}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```

---

## PROC_REFRESH_DERIVED

Updates monitoring tables (HELPER_MONITOR_LAST_REFRESH, HELPER_QA_COUNTS_DAILY) with freshness and QA metrics.

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_REFRESH_DERIVED()
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
DECLARE
  v_adsb_cnt_24h NUMBER(38,0);
  v_adsb_max_ts TIMESTAMP_NTZ;
  v_sched_cnt_window NUMBER(38,0);
BEGIN
  SELECT COUNT(*), MAX(TIMESTAMP)
    INTO :v_adsb_cnt_24h, :v_adsb_max_ts
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
  WHERE TIMESTAMP >= DATEADD('day', -1, SYSDATE());

  SELECT COUNT(*)
    INTO :v_sched_cnt_window
  FROM {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE
  WHERE FLIGHT_DATE BETWEEN DATEADD('day', -2, CURRENT_DATE()) AND DATEADD('day', 2, CURRENT_DATE());

  MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_MONITOR_LAST_REFRESH t
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

  MERGE INTO {TARGET_DB}.{SCHEMA}.HELPER_QA_COUNTS_DAILY t
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
      FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL
      WHERE TIMESTAMP >= DATEADD('day', -1, SYSDATE())
    ),
    legs AS (
      SELECT COUNT(*) AS leg_cnt
      FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG
      WHERE SERVICE_DATE >= DATEADD('day', -1, CURRENT_DATE())
    ),
    leg_matches AS (
      SELECT COUNT(*) AS matched_leg_cnt
      FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_RESULT
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
```

---

## PROC_SMOKE_CHECK (JavaScript)

Validation procedure that fails loudly if core invariants aren't met. Uses `EXECUTE AS CALLER`.

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_SMOKE_CHECK(p_grace_minutes STRING)
RETURNS STRING
LANGUAGE JAVASCRIPT
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
EXECUTE AS CALLER
AS
$$
function scalar(sqlText) {
  var stmt = snowflake.createStatement({sqlText});
  var rs = stmt.execute();
  rs.next();
  return rs.getColumnValue(1);
}

var p_grace_minutes = arguments[0];

function minutesSinceInstall() {
  try {
    var mins = scalar(`SELECT DATEDIFF('minute', MAX(installed_at), CURRENT_TIMESTAMP()) FROM {TARGET_DB}.{SCHEMA}.HELPER_INSTALL_AUDIT`);
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

var runwayCnt = scalar(`SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS`);
if (runwayCnt < 1) {
  throw `Smoke check failed: PROPERTIES_RUNWAYS must have at least 1 row, got ${runwayCnt}`;
}
var runwayNonNull = scalar(`SELECT COUNT_IF(runway_geog IS NOT NULL) FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS`);
if (runwayNonNull < 1) {
  throw `Smoke check failed: PROPERTIES_RUNWAYS.runway_geog is NULL`;
}

var maxTs = scalar(`SELECT MAX(TIMESTAMP) FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL`);
if (maxTs === null) {
  if (minsSince <= grace) {
    return `WAITING_FOR_ADSB_DATA (installed ${minsSince} min ago; grace=${grace}m)`;
  }
  throw `Smoke check failed: ADSB_DATA_LOCAL is empty (MAX(TIMESTAMP) is NULL)`;
}
var fresh = scalar(`SELECT IFF(MAX(TIMESTAMP) >= DATEADD('hour', -2, SYSDATE()), 1, 0) FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL`);
if (fresh !== 1) {
  if (minsSince <= grace) {
    return `WAITING_FOR_ADSB_DATA (stale during grace window; installed ${minsSince} min ago; grace=${grace}m; max_ts=${maxTs})`;
  }
  throw `Smoke check failed: ADSB_DATA_LOCAL appears stale (no points in last 2 hours). max_ts=${maxTs}`;
}

var schedCnt = scalar(`SELECT COUNT(*) FROM {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE WHERE FLIGHT_DATE BETWEEN DATEADD('day', -2, CURRENT_DATE()) AND DATEADD('day', 2, CURRENT_DATE())`);

snowflake.createStatement({sqlText: `SHOW TASKS IN SCHEMA {TARGET_DB}.{SCHEMA}`}).execute();
var schedTaskExists = scalar(`SELECT COUNT_IF("name"='TASK_FLIGHT_SCHEDULE') FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`);
var requiredTasksRunning = scalar(`SELECT COUNT_IF(LOWER("state")='started' AND "name" IN ('TASK_INGEST_ADSB','TASK_ENRICH_ADSB','TASK_REFRESH_DERIVED')) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`);
var schedTaskRunning = scalar(`SELECT COUNT_IF(LOWER("state")='started' AND "name"='TASK_FLIGHT_SCHEDULE') FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`);

if (requiredTasksRunning < 3) {
  throw `Smoke check failed: not all core ADS-B tasks are STARTED (started=${requiredTasksRunning}/3)`;
}

if (schedTaskExists > 0 && schedTaskRunning === 0) {
  throw `Smoke check failed: TASK_FLIGHT_SCHEDULE exists but is not STARTED`; 
}

return 'OK';
$$;
```

---

## PROC_REFRESH_ANALYTICS

Refreshes all 13 Dynamic Tables in dependency order.

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_REFRESH_ANALYTICS()
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
BEGIN
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA_LOCAL REFRESH;
  
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_GATE_UTIL_DAILY REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE REFRESH;
  
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRACKER_FLIGHT_LIST REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY REFRESH;
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY REFRESH;
  
  ALTER DYNAMIC TABLE {TARGET_DB}.{SCHEMA}.RUNWAY_CROSSINGS_DETAILED REFRESH;
  
  RETURN 'Dynamic tables refreshed successfully';
END;
$$;
```

---

## PROC_RESUME_OPTIONAL_TASK

Helper to safely resume a task only if it exists.

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_RESUME_OPTIONAL_TASK(task_name STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-derived-analytics","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
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
```
