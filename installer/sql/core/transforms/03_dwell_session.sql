-- =============================================================================
-- DWELL_CORE.DWELL_SESSION: Aggregated dwell sessions per asset per day
--
-- One row per continuous presence session. Domain-agnostic: attrs is passed
-- through from point-level data without assuming any key names.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.DWELL_CORE.DWELL_SESSION
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
SELECT
  session_id,
  site_id,
  asset_id,
  service_date_local,
  session_seq,
  MIN(observed_ts_utc)  AS start_ts_utc,
  MAX(observed_ts_utc)  AS end_ts_utc,
  DATEDIFF('second', MIN(observed_ts_utc), MAX(observed_ts_utc)) AS dwell_seconds,
  COUNT(*)              AS points,
  MAX(asset_category)   AS asset_category,
  ANY_VALUE(attrs)       AS attrs
FROM ${DATABASE}.DWELL_CORE.PRESENCE_POINT
GROUP BY session_id, site_id, asset_id, service_date_local, session_seq;
