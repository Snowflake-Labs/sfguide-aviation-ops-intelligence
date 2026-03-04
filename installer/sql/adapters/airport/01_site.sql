-- =============================================================================
-- Airport Adapter: Map PROPERTIES_AIRPORT → DWELL_CORE.SITE
-- =============================================================================

MERGE INTO ${DATABASE}.DWELL_CORE.SITE t
USING (
  SELECT
    MD5(CONCAT('airport:', COALESCE(airport_code, airport_icao, airport_name)))
                                       AS site_id,
    COALESCE(airport_code, '')         AS site_code,
    airport_name                       AS site_name,
    COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS site_tzid,
    geometry                           AS site_geom,
    'airport'                          AS site_type,
    OBJECT_CONSTRUCT(
      'airport_icao',  airport_icao,
      'center_lat',    center_lat,
      'center_lon',    center_lon,
      'min_lat',       min_lat,
      'max_lat',       max_lat,
      'min_lon',       min_lon,
      'max_lon',       max_lon
    )                                  AS attrs
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT
) s
ON t.site_id = s.site_id
WHEN MATCHED THEN UPDATE SET
  site_code  = s.site_code,
  site_name  = s.site_name,
  site_tzid  = s.site_tzid,
  site_geom  = s.site_geom,
  site_type  = s.site_type,
  attrs      = s.attrs
WHEN NOT MATCHED THEN INSERT (
  site_id, site_code, site_name, site_tzid, site_geom, site_type, attrs
) VALUES (
  s.site_id, s.site_code, s.site_name, s.site_tzid, s.site_geom, s.site_type, s.attrs
);
