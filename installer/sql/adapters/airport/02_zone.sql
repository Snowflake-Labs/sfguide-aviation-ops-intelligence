-- =============================================================================
-- Airport Adapter: Map PROPERTIES_GATES → DWELL_CORE.ZONE
-- =============================================================================

MERGE INTO ${DATABASE}.DWELL_CORE.ZONE t
USING (
  WITH one_site AS (
    SELECT site_id
    FROM ${DATABASE}.DWELL_CORE.SITE
    WHERE site_type = 'airport'
    QUALIFY ROW_NUMBER() OVER (ORDER BY created_at DESC) = 1
  )
  SELECT
    g.gate_id                          AS zone_id,
    s.site_id                          AS site_id,
    'gate'                             AS zone_type,
    g.gate_name                        AS zone_name,
    g.gate_geom                        AS zone_geom,
    NULL::VARIANT                      AS attrs
  FROM ${DATABASE}.${SCHEMA}.PROPERTIES_GATES g
  CROSS JOIN one_site s
) src
ON t.zone_id = src.zone_id AND t.site_id = src.site_id
WHEN MATCHED THEN UPDATE SET
  zone_type = src.zone_type,
  zone_name = src.zone_name,
  zone_geom = src.zone_geom,
  attrs     = src.attrs
WHEN NOT MATCHED THEN INSERT (
  zone_id, site_id, zone_type, zone_name, zone_geom, attrs
) VALUES (
  src.zone_id, src.site_id, src.zone_type, src.zone_name, src.zone_geom, src.attrs
);
