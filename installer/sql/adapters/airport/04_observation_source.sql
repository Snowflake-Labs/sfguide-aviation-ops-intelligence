-- =============================================================================
-- Airport Adapter: Create DWELL_CORE.OBSERVATION_SOURCE
--
-- Maps ADSB_DATA_LOCAL into the canonical observation shape expected by core.
-- All aviation-specific column references are contained here; core never
-- references ADSB_DATA_LOCAL or aviation field names directly.
--
-- Must be a Dynamic Table (not a view) because ADSB_DATA_LOCAL is a Dynamic
-- Table and Snowflake does not allow DTs to read through views that reference
-- other DTs.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE ${DATABASE}.DWELL_CORE.OBSERVATION_SOURCE
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = ${WAREHOUSE}
AS
WITH one_site AS (
  SELECT site_id, site_tzid
  FROM ${DATABASE}.DWELL_CORE.SITE
  WHERE site_type = 'airport'
  QUALIFY ROW_NUMBER() OVER (ORDER BY created_at DESC) = 1
)
SELECT
  s.site_id                                                       AS site_id,
  a.ICAO_HEX                                                      AS asset_id,
  a.TIMESTAMP                                                      AS observed_ts_utc,
  CONVERT_TIMEZONE('UTC', s.site_tzid, a.TIMESTAMP)::TIMESTAMP_NTZ AS observed_ts_local,
  a.service_date                                                   AS service_date_local,
  a.LOCATION                                                       AS location,
  a.VELOCITY                                                       AS speed,
  a.TRACK                                                          AS heading,
  a.ALTITUDE_BARO                                                  AS altitude,
  a.SOURCE                                                         AS source,
  a.VEHICLE_CATEGORY                                               AS asset_category,
  OBJECT_CONSTRUCT(
    'flight_key',     a.FLIGHT_KEY,
    'callsign',       a.FLIGHT,
    'registration',   a.REGISTRATION,
    'type',           a.TYPE,
    'aircraft_desc',  a.AIRCRAFT_DESC,
    'category',       a.CATEGORY,
    'airline_name',   a.AIRLINE_NAME,
    'airline_iata',   a.AIRLINE_IATA,
    'airline_icao',   a.AIRLINE_ICAO,
    'flight_id',      a.flight_id
  )                                                                AS attrs
FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_LOCAL a
CROSS JOIN one_site s;
