-- =============================================================================
-- DWELL_CORE.PRESENCE_POINT: Filtered observations representing on-ground /
-- in-facility presence, with sessionization columns.
--
-- Thresholds are read from DWELL_CORE.POLICY (not hardcoded).
-- Facility geofence uses SITE.site_geom + POLICY.facility_radius_m.
--
-- Domain-agnostic design:
--   - Altitude filter is optional: points without altitude data are kept.
--   - Speed filter tolerates NULL (treated as 0).
--   - Geofence is skipped when site_geom is NULL.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.DWELL_CORE.PRESENCE_POINT
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = ${WAREHOUSE}
AS
WITH policy AS (
  SELECT
    site_id,
    ground_altitude_max_ft,
    ground_speed_max_kts,
    session_gap_minutes,
    facility_radius_m
  FROM ${DATABASE}.DWELL_CORE.POLICY
),
ground AS (
  SELECT
    o.site_id,
    o.asset_id,
    o.observed_ts_utc,
    o.observed_ts_local,
    o.service_date_local,
    o.location,
    o.speed,
    o.heading,
    o.altitude,
    o.source,
    o.asset_category,
    o.attrs,
    p.session_gap_minutes
  FROM ${DATABASE}.DWELL_CORE.OBSERVATION o
  JOIN policy p ON p.site_id = o.site_id
  JOIN ${DATABASE}.DWELL_CORE.SITE s ON s.site_id = o.site_id
  WHERE o.observed_ts_utc IS NOT NULL
    AND o.location IS NOT NULL
    AND (p.ground_altitude_max_ft IS NULL OR o.altitude IS NULL OR o.altitude <= p.ground_altitude_max_ft)
    AND (p.ground_speed_max_kts IS NULL OR o.speed IS NULL OR o.speed <= p.ground_speed_max_kts)
    AND (p.facility_radius_m IS NULL OR s.site_geom IS NULL OR ST_DWITHIN(o.location, s.site_geom, p.facility_radius_m))
),
with_lag AS (
  SELECT
    g.*,
    TIMESTAMPDIFF(
      'second',
      LAG(g.observed_ts_utc) OVER (
        PARTITION BY g.site_id, g.asset_id, g.service_date_local
        ORDER BY g.observed_ts_utc
      ),
      g.observed_ts_utc
    ) AS lag_seconds,
    DATEDIFF(
      'minute',
      LAG(g.observed_ts_utc) OVER (
        PARTITION BY g.site_id, g.asset_id, g.service_date_local
        ORDER BY g.observed_ts_utc
      ),
      g.observed_ts_utc
    ) AS gap_min
  FROM ground g
),
sessioned AS (
  SELECT
    w.*,
    SUM(IFF(COALESCE(w.gap_min, 999999) > w.session_gap_minutes, 1, 0))
      OVER (
        PARTITION BY w.site_id, w.asset_id, w.service_date_local
        ORDER BY w.observed_ts_utc
        ROWS UNBOUNDED PRECEDING
      ) AS session_seq
  FROM with_lag w
)
SELECT
  MD5(CONCAT(s.site_id, ':', s.asset_id, ':', TO_VARCHAR(s.service_date_local), ':', TO_VARCHAR(s.session_seq)))
    AS session_id,
  s.site_id,
  s.asset_id,
  s.observed_ts_utc,
  s.observed_ts_local,
  s.service_date_local,
  s.location,
  s.speed,
  s.heading,
  s.altitude,
  s.source,
  s.asset_category,
  COALESCE(s.lag_seconds, 0) AS lag_seconds,
  s.session_seq,
  s.attrs
FROM sessioned s;
