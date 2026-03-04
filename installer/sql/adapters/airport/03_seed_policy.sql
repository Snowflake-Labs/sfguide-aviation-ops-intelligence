-- =============================================================================
-- Airport Adapter: Seed DWELL_CORE.POLICY with airport-specific defaults
--
-- These values replicate the thresholds currently hardcoded in the existing
-- dynamic table definitions. Changing these values will change behavior for
-- all core transforms that read from POLICY.
--
-- Current airport defaults (preserved from existing logic):
--   ground_altitude_max_ft  = 50   (ALTITUDE_BARO <= 50)
--   ground_speed_max_kts    = 40   (VELOCITY <= 40)
--   session_gap_minutes     = 20   (gap_min > 20 splits sessions)
--   facility_radius_m       = 5000 (ST_DWITHIN 5000m for "near airport")
--   zone_assign_radius_m    = 120  (ST_DWITHIN 120m for gate assignment)
-- =============================================================================

MERGE INTO ${DATABASE}.DWELL_CORE.POLICY t
USING (
  SELECT
    s.site_id,
    50    AS ground_altitude_max_ft,
    40    AS ground_speed_max_kts,
    20    AS session_gap_minutes,
    5000  AS facility_radius_m,
    120   AS zone_assign_radius_m,
    OBJECT_CONSTRUCT(
      'adapter', 'airport',
      'notes',   'Default airport thresholds matching existing logic'
    ) AS attrs
  FROM ${DATABASE}.DWELL_CORE.SITE s
  WHERE s.site_type = 'airport'
) src
ON t.site_id = src.site_id
WHEN MATCHED THEN UPDATE SET
  ground_altitude_max_ft = src.ground_altitude_max_ft,
  ground_speed_max_kts   = src.ground_speed_max_kts,
  session_gap_minutes    = src.session_gap_minutes,
  facility_radius_m      = src.facility_radius_m,
  zone_assign_radius_m   = src.zone_assign_radius_m,
  attrs                  = src.attrs,
  updated_at             = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
  site_id, ground_altitude_max_ft, ground_speed_max_kts,
  session_gap_minutes, facility_radius_m, zone_assign_radius_m, attrs
) VALUES (
  src.site_id, src.ground_altitude_max_ft, src.ground_speed_max_kts,
  src.session_gap_minutes, src.facility_radius_m, src.zone_assign_radius_m, src.attrs
);
