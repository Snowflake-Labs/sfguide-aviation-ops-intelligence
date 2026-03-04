-- =============================================================================
-- DWELL_CORE.ZONE: A sub-area within a site (gate, dock, door, bay, etc.)
--
-- Populated by adapters. Zones are the unit of dwell measurement.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ${DATABASE}.DWELL_CORE.ZONE (
  zone_id     STRING      NOT NULL  COMMENT 'Stable unique identifier (adapter-supplied)',
  site_id     STRING      NOT NULL  COMMENT 'FK to SITE.site_id',
  zone_type   STRING                COMMENT 'Kind of zone (gate, dock, door, bay, …) — adapter-supplied',
  zone_name   STRING                COMMENT 'Human-readable zone name',
  zone_geom   GEOGRAPHY             COMMENT 'Zone geometry (point, polygon, etc.)',
  attrs       VARIANT               COMMENT 'Adapter-specific metadata',
  created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
