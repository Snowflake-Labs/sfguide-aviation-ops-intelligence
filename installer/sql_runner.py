"""
Thin SQL template loader and executor.

Loads .sql files from installer/sql/*, applies parameter substitution,
and returns executable SQL strings. No domain logic lives here.

Adapter loading is directory-based:
  - adapter="airport" loads sql/adapters/airport/ (default)
  - adapter="<name>"  loads sql/adapters/<name>/ (pluggable)
  - adapter="byo"     generates OBSERVATION_SOURCE from a customer column mapping
Compat and smoke tests follow the same convention (sql/compat/<adapter>/, etc.).
"""

import os
import logging
from typing import Dict, List, Optional

log = logging.getLogger(__name__)

_SQL_DIR = os.path.join(os.path.dirname(__file__), "sql")


def _resolve_dir(subdir: str) -> str:
    """Resolve a subdirectory relative to installer/sql/."""
    path = os.path.join(_SQL_DIR, subdir)
    if not os.path.isdir(path):
        raise FileNotFoundError(f"SQL module directory not found: {path}")
    return path


def load_sql_file(filepath: str, params: Dict[str, str]) -> str:
    """Load a single SQL file and apply parameter substitution.

    Parameters use ${KEY} syntax (e.g. ${DATABASE}, ${SCHEMA}, ${WAREHOUSE}).
    """
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    for key, value in params.items():
        content = content.replace(f"${{{key}}}", value)
    return content


def load_sql_module(subdir: str, params: Dict[str, str]) -> List[tuple]:
    """Load all .sql files from a subdirectory in sorted order.

    Returns a list of (filename, sql_content) tuples.
    """
    dirpath = _resolve_dir(subdir)
    results = []
    for fname in sorted(os.listdir(dirpath)):
        if not fname.endswith(".sql"):
            continue
        fpath = os.path.join(dirpath, fname)
        sql = load_sql_file(fpath, params)
        results.append((fname, sql))
    return results


def load_sql_modules_ordered(
    subdirs: List[str], params: Dict[str, str]
) -> List[tuple]:
    """Load SQL files from multiple subdirectories in the given order.

    Returns a flat list of (subdir/filename, sql_content) tuples.
    """
    results = []
    for subdir in subdirs:
        for fname, sql in load_sql_module(subdir, params):
            results.append((f"{subdir}/{fname}", sql))
    return results


def build_params(
    database: str,
    schema: str,
    warehouse: str,
    **extra: str,
) -> Dict[str, str]:
    """Build the standard parameter dictionary for template substitution."""
    params = {
        "DATABASE": database,
        "SCHEMA": schema,
        "WAREHOUSE": warehouse,
        "CORE_SCHEMA": "DWELL_CORE",
    }
    params.update(extra)
    return params


# ---------------------------------------------------------------------------
# Airport adapter (default)
# ---------------------------------------------------------------------------

def generate_dwell_core_sql(
    database: str,
    schema: str,
    warehouse: str,
    adapter: str = "airport",
    byo_config: Optional[dict] = None,
) -> str:
    """Generate the full DWELL_CORE install SQL.

    Args:
        database:  Target database name.
        schema:    Target schema (PUBLIC).
        warehouse: Warehouse for dynamic tables.
        adapter:   Adapter name matching sql/adapters/<name>/ dir,
            or "byo" for generated mapping. Default "airport".
        byo_config: Required when adapter="byo". Dict with keys:
            source_relation, column_mapping, site_config, policy_overrides.

    Returns a single SQL string that can be executed after the base
    infrastructure (properties, ADS-B, etc.) is already in place.
    """
    params = build_params(database, schema, warehouse)

    parts = [
        "-- =============================================================================\n"
        "-- DWELL_CORE: Modular Dwell + Congestion Layer\n"
        f"-- Database: {database}  |  Adapter: {adapter}\n"
        "-- =============================================================================\n"
    ]

    def _append_module(subdir: str) -> None:
        try:
            for fname, sql in load_sql_module(subdir, params):
                parts.append(f"\n-- >>> {subdir}/{fname}\n")
                parts.append(sql)
                parts.append(f"\n-- <<< {subdir}/{fname}\n")
        except FileNotFoundError:
            log.warning("SQL module directory not found: %s (skipping)", subdir)

    def _maybe_append_module(subdir: str) -> bool:
        """Append module if directory exists; return True if loaded."""
        dirpath = os.path.join(_SQL_DIR, subdir)
        if os.path.isdir(dirpath):
            _append_module(subdir)
            return True
        return False

    # Phase 1: core base (schema + empty contract tables)
    _append_module("core/base")

    # Phase 2: adapter (directory-based plugin — must exist)
    if adapter == "byo":
        if not byo_config:
            raise ValueError("byo_config is required when adapter='byo'")
        byo_sql = generate_byo_observation_source(
            database, schema, warehouse, **byo_config
        )
        parts.append("\n-- >>> byo/generated\n")
        parts.append(byo_sql)
        parts.append("\n-- <<< byo/generated\n")
    else:
        adapter_subdir = f"adapters/{adapter}"
        for fname, sql in load_sql_module(adapter_subdir, params):
            parts.append(f"\n-- >>> {adapter_subdir}/{fname}\n")
            parts.append(sql)
            parts.append(f"\n-- <<< {adapter_subdir}/{fname}\n")

    # Phase 3: core transforms (depend on OBSERVATION_SOURCE from adapter)
    _append_module("core/transforms")

    # Phase 4: compat layer
    # Try adapter-specific compat dir first; fall back to flat compat/ for airport
    if not _maybe_append_module(f"compat/{adapter}"):
        if adapter == "airport":
            _maybe_append_module("compat")

    # Phase 5: smoke tests
    smoke_dir = os.path.join(_SQL_DIR, "smoke_tests")
    if os.path.isdir(smoke_dir):
        core_smoke = os.path.join(smoke_dir, "01_core.sql")
        if os.path.isfile(core_smoke):
            parts.append("\n-- >>> smoke_tests/01_core.sql\n")
            parts.append(load_sql_file(core_smoke, params))
            parts.append("\n-- <<< smoke_tests/01_core.sql\n")
        # Try adapter-specific smoke tests dir; fall back to legacy file for airport
        if not _maybe_append_module(f"smoke_tests/{adapter}"):
            if adapter == "airport":
                airport_smoke = os.path.join(smoke_dir, "02_airport.sql")
                if os.path.isfile(airport_smoke):
                    parts.append("\n-- >>> smoke_tests/02_airport.sql\n")
                    parts.append(load_sql_file(airport_smoke, params))
                    parts.append("\n-- <<< smoke_tests/02_airport.sql\n")

    return "\n".join(parts)


def generate_compat_sql(
    database: str, schema: str, warehouse: str
) -> str:
    """Generate only the backward-compatibility layer SQL."""
    params = build_params(database, schema, warehouse)
    parts = []
    for fname, sql in load_sql_module("compat", params):
        parts.append(sql)
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# BYO (Bring-Your-Own) telemetry adapter
# ---------------------------------------------------------------------------

def generate_byo_observation_source(
    database: str,
    schema: str,
    warehouse: str,
    source_relation: str,
    column_mapping: dict,
    site_config: dict,
    policy_overrides: Optional[dict] = None,
) -> str:
    """Generate SQL for a BYO telemetry OBSERVATION_SOURCE.

    Creates:
      1. DWELL_CORE.SITE row for the BYO site
      2. DWELL_CORE.POLICY row with provided or default thresholds
      3. DWELL_CORE.OBSERVATION_SOURCE view mapping BYO columns to canonical shape

    Args:
        source_relation: Fully qualified table/view name
            (e.g. "MY_DB.MY_SCHEMA.VEHICLE_POSITIONS").
        column_mapping: Dict with keys:
            - asset_id_col (required): column name for asset identifier
            - ts_col (required): column name for UTC timestamp
            - geography_col: column name for GEOGRAPHY location (use this OR lat/lon)
            - lat_col / lon_col: column names for latitude/longitude
            - speed_col: column for speed (optional)
            - heading_col: column for heading/course (optional)
            - altitude_col: column for altitude (optional)
            - asset_category_col: column for asset type/category (optional)
            - attrs_expression: SQL expression for attrs VARIANT (optional)
        site_config: Dict with keys:
            - site_id (required): stable unique identifier
            - site_name (required): human-readable name
            - site_timezone (optional, default 'UTC'): IANA timezone
            - site_lat / site_lon (optional): facility center coordinates
            - site_type (optional, default 'custom'): domain type label
        policy_overrides: Optional dict overriding default POLICY values:
            - ground_altitude_max_ft, ground_speed_max_kts,
              session_gap_minutes, facility_radius_m, zone_assign_radius_m
    """
    # --- Validate required inputs ---
    errors = []
    if not column_mapping:
        errors.append("column_mapping is required")
    if not site_config:
        errors.append("site_config is required")
    if errors:
        raise ValueError("BYO validation failed:\n  " + "\n  ".join(errors))

    cm = column_mapping
    sc = site_config
    po = policy_overrides or {}

    for key in ("asset_id_col", "ts_col"):
        val = cm.get(key)
        if not val or not str(val).strip():
            errors.append(f"column_mapping['{key}'] is required")
    has_geo = cm.get("geography_col") and str(cm["geography_col"]).strip()
    has_latlon = (
        cm.get("lat_col") and str(cm["lat_col"]).strip()
        and cm.get("lon_col") and str(cm["lon_col"]).strip()
    )
    if not has_geo and not has_latlon:
        errors.append(
            "column_mapping must include 'geography_col' or both 'lat_col' and 'lon_col'"
        )
    for key in ("site_id", "site_name"):
        val = sc.get(key)
        if not val or not str(val).strip():
            errors.append(f"site_config['{key}'] is required")
    if errors:
        raise ValueError("BYO validation failed:\n  " + "\n  ".join(errors))

    asset_id = cm["asset_id_col"]
    ts_col = cm["ts_col"]

    if has_geo:
        location_expr = f"src.{cm['geography_col']}"
    else:
        location_expr = f"ST_MAKEPOINT(src.{cm['lon_col']}, src.{cm['lat_col']})"

    speed_expr = f"src.{cm['speed_col']}" if cm.get("speed_col") else "NULL"
    heading_expr = f"src.{cm['heading_col']}" if cm.get("heading_col") else "NULL"
    altitude_expr = f"src.{cm['altitude_col']}" if cm.get("altitude_col") else "NULL"
    category_expr = (
        f"src.{cm['asset_category_col']}" if cm.get("asset_category_col") else "NULL"
    )
    attrs_expr = cm.get("attrs_expression", "NULL::VARIANT")

    site_id = sc["site_id"]
    site_name = sc["site_name"]
    site_tz = sc.get("site_timezone", "UTC")
    site_type = sc.get("site_type", "custom")

    if sc.get("site_lat") and sc.get("site_lon"):
        site_geom_expr = (
            f"ST_MAKEPOINT({sc['site_lon']}, {sc['site_lat']})"
        )
    else:
        site_geom_expr = "NULL"

    alt_max = po.get("ground_altitude_max_ft", 50)
    spd_max = po.get("ground_speed_max_kts", 40)
    gap_min = po.get("session_gap_minutes", 20)
    fac_rad = po.get("facility_radius_m", 5000)
    zone_rad = po.get("zone_assign_radius_m", 120)

    return f"""-- =============================================================================
-- BYO Telemetry: SITE + POLICY + OBSERVATION_SOURCE
-- Source: {source_relation}
-- =============================================================================

-- 0. Validate source relation and required columns exist
SELECT src.{asset_id}, src.{ts_col}, {location_expr}
FROM {source_relation} src
WHERE FALSE;

-- 1. Seed SITE
MERGE INTO {database}.DWELL_CORE.SITE t
USING (
  SELECT
    '{site_id}'                       AS site_id,
    ''                                AS site_code,
    '{site_name}'                     AS site_name,
    '{site_tz}'                       AS site_tzid,
    {site_geom_expr}                  AS site_geom,
    '{site_type}'                     AS site_type,
    NULL::VARIANT                     AS attrs
) s
ON t.site_id = s.site_id
WHEN MATCHED THEN UPDATE SET
  site_name = s.site_name,
  site_tzid = s.site_tzid,
  site_geom = s.site_geom,
  site_type = s.site_type
WHEN NOT MATCHED THEN INSERT (
  site_id, site_code, site_name, site_tzid, site_geom, site_type, attrs
) VALUES (
  s.site_id, s.site_code, s.site_name, s.site_tzid, s.site_geom, s.site_type, s.attrs
);

-- 2. Seed POLICY
MERGE INTO {database}.DWELL_CORE.POLICY t
USING (
  SELECT
    '{site_id}'  AS site_id,
    {alt_max}    AS ground_altitude_max_ft,
    {spd_max}    AS ground_speed_max_kts,
    {gap_min}    AS session_gap_minutes,
    {fac_rad}    AS facility_radius_m,
    {zone_rad}   AS zone_assign_radius_m,
    OBJECT_CONSTRUCT('adapter', 'byo', 'source', '{source_relation}') AS attrs
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

-- 3. Create OBSERVATION_SOURCE
CREATE OR REPLACE VIEW {database}.DWELL_CORE.OBSERVATION_SOURCE AS
SELECT
  '{site_id}'                                                              AS site_id,
  src.{asset_id}                                                           AS asset_id,
  src.{ts_col}                                                             AS observed_ts_utc,
  CONVERT_TIMEZONE('UTC', '{site_tz}', src.{ts_col})::TIMESTAMP_NTZ       AS observed_ts_local,
  TO_DATE(CONVERT_TIMEZONE('UTC', '{site_tz}', src.{ts_col}))             AS service_date_local,
  {location_expr}                                                          AS location,
  {speed_expr}                                                             AS speed,
  {heading_expr}                                                           AS heading,
  {altitude_expr}                                                          AS altitude,
  NULL                                                                     AS source,
  {category_expr}                                                          AS asset_category,
  {attrs_expr}                                                             AS attrs
FROM {source_relation} src;
"""
