-- =============================================================================
-- DWELL_CORE.CONGESTION_CELL_FACT: Placeholder for congestion analytics
--
-- Scaffolding for a future congestion primitive. Currently empty DDL only;
-- no population logic. Does not break installs if unpopulated.
--
-- Intended use: spatial grid cells (H3, geohash, custom polygons) with
-- time-bucketed asset counts and average dwell times for heatmaps.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ${DATABASE}.DWELL_CORE.CONGESTION_CELL_FACT (
  site_id             STRING        COMMENT 'FK to SITE.site_id',
  cell_id             STRING        COMMENT 'Spatial cell identifier (H3 index, geohash, etc.)',
  period_start_utc    TIMESTAMP_NTZ COMMENT 'Start of the time bucket',
  period_end_utc      TIMESTAMP_NTZ COMMENT 'End of the time bucket',
  asset_count         NUMBER        COMMENT 'Number of distinct assets in the cell during the period',
  avg_dwell_seconds   NUMBER        COMMENT 'Average dwell time of assets in the cell',
  attrs               VARIANT       COMMENT 'Additional metrics (peak count, congestion score, etc.)',
  computed_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
