-- =============================================================================
-- DWELL_CORE.OBSERVATION: Stable contract view over adapter-provided source
--
-- Core transforms (PRESENCE_POINT, DWELL_SESSION, etc.) read from this view.
-- The underlying data comes from DWELL_CORE.OBSERVATION_SOURCE, which is
-- created by the active adapter (airport, port, BYO, etc.).
--
-- This view enforces the canonical column contract without referencing any
-- domain-specific table or column name.
-- =============================================================================

CREATE OR REPLACE VIEW ${DATABASE}.DWELL_CORE.OBSERVATION AS
SELECT
  site_id,
  asset_id,
  observed_ts_utc,
  observed_ts_local,
  service_date_local,
  location,
  speed,
  heading,
  altitude,
  source,
  asset_category,
  attrs
FROM ${DATABASE}.DWELL_CORE.OBSERVATION_SOURCE;
