-- =============================================================================
-- DWELL_CORE.ZONE_ASSIGNMENT: Point-level mapping of presence points to zones
--
-- Each presence point is assigned to the nearest zone within the policy
-- zone_assign_radius_m. One row per point (closest zone wins).
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.DWELL_CORE.ZONE_ASSIGNMENT
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = ${WAREHOUSE}
AS
WITH policy AS (
  SELECT site_id, zone_assign_radius_m
  FROM ${DATABASE}.DWELL_CORE.POLICY
)
SELECT
  pp.session_id,
  pp.site_id,
  pp.asset_id,
  pp.observed_ts_utc,
  pp.service_date_local,
  pp.session_seq,
  pp.lag_seconds,
  pp.asset_category,
  z.zone_id,
  z.zone_name,
  z.zone_type,
  'nearest_within_radius' AS assignment_method,
  ST_DISTANCE(pp.location, z.zone_geom) AS distance_m,
  pp.attrs
FROM ${DATABASE}.DWELL_CORE.PRESENCE_POINT pp
JOIN policy pol ON pol.site_id = pp.site_id
LEFT JOIN ${DATABASE}.DWELL_CORE.ZONE z
  ON z.site_id = pp.site_id
 AND ST_DWITHIN(pp.location, z.zone_geom, pol.zone_assign_radius_m)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY pp.site_id, pp.asset_id, pp.observed_ts_utc
  ORDER BY ST_DISTANCE(pp.location, z.zone_geom) ASC NULLS LAST
) = 1;
