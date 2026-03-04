-- =============================================================================
-- DWELL_CORE.OBSERVATION: Stable contract layer over adapter-provided source
--
-- Core transforms (PRESENCE_POINT, DWELL_SESSION, etc.) read from this table.
-- The underlying data comes from DWELL_CORE.OBSERVATION_SOURCE, which is
-- created by the active adapter (airport, port, BYO, etc.).
--
-- Must be a Dynamic Table (not a view) because OBSERVATION_SOURCE is a DT
-- and Snowflake does not allow DTs to read through views that reference DTs.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.DWELL_CORE.OBSERVATION
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = ${WAREHOUSE}
AS
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
