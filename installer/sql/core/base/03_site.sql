-- =============================================================================
-- DWELL_CORE.SITE: A monitored facility (airport, port, warehouse, etc.)
--
-- Populated by adapters. One row per facility.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ${DATABASE}.DWELL_CORE.SITE (
  site_id     STRING      NOT NULL  COMMENT 'Stable unique identifier (adapter-supplied)',
  site_code   STRING                COMMENT 'Short code (e.g. IATA for airports, but not required)',
  site_name   STRING                COMMENT 'Human-readable facility name',
  site_tzid   STRING                COMMENT 'IANA timezone identifier for local time derivation',
  site_geom   GEOGRAPHY             COMMENT 'Facility boundary/polygon',
  site_type   STRING                COMMENT 'Domain type supplied by adapter (airport, port, warehouse, …)',
  attrs       VARIANT               COMMENT 'Adapter-specific metadata (ICAO code, center lat/lon, etc.)',
  created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
