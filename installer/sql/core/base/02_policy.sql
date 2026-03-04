-- =============================================================================
-- DWELL_CORE.POLICY: Parameterized thresholds per site
--
-- All core transforms read thresholds from this table instead of hardcoding.
-- Each adapter seeds rows appropriate for its domain.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ${DATABASE}.DWELL_CORE.POLICY (
  site_id                 STRING    NOT NULL,
  -- Ground/presence detection thresholds
  ground_altitude_max_ft  NUMBER    DEFAULT 50     COMMENT 'Max barometric altitude (ft) to classify as on-ground',
  ground_speed_max_kts    NUMBER    DEFAULT 40     COMMENT 'Max speed (knots) to classify as on-ground / low-speed',
  -- Sessionization
  session_gap_minutes     NUMBER    DEFAULT 20     COMMENT 'Gap (minutes) between consecutive points that splits sessions',
  -- Facility proximity
  facility_radius_m       NUMBER    DEFAULT 5000   COMMENT 'Radius (meters) from site geometry to consider an asset near-facility',
  -- Zone assignment
  zone_assign_radius_m    NUMBER    DEFAULT 120    COMMENT 'Radius (meters) from zone geometry for point-to-zone assignment',
  -- Metadata
  attrs                   VARIANT            COMMENT 'Additional policy parameters (domain-specific)',
  updated_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
