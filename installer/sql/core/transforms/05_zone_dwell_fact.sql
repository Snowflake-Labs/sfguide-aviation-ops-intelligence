-- =============================================================================
-- DWELL_CORE.ZONE_DWELL_FACT: Daily zone-level dwell aggregation
--
-- One row per (service_date, site, zone, asset_category).
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.DWELL_CORE.ZONE_DWELL_FACT
  TARGET_LAG = '1 HOUR'
  WAREHOUSE = ${WAREHOUSE}
  INITIALIZE = ON_SCHEDULE
AS
SELECT
  za.service_date_local,
  za.site_id,
  za.zone_id,
  za.zone_name,
  za.asset_category,
  SUM(za.lag_seconds) / 60.0        AS dwell_minutes,
  COUNT(DISTINCT za.session_id)      AS distinct_sessions,
  COUNT(DISTINCT za.asset_id)        AS distinct_assets,
  NULL::VARIANT                      AS attrs
FROM ${DATABASE}.DWELL_CORE.ZONE_ASSIGNMENT za
WHERE za.zone_id IS NOT NULL
GROUP BY
  za.service_date_local,
  za.site_id,
  za.zone_id,
  za.zone_name,
  za.asset_category;
