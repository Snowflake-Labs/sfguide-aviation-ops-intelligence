# Modular SQL Architecture — Dwell + Congestion Core

## Overview

This directory contains the **modular SQL layer** for the Dwell + Congestion Intelligence package.
It implements a domain-agnostic core contract with pluggable adapters and a backward-compatibility
layer that preserves all existing dashboard objects.

```
installer/sql/
├── core/
│   ├── base/                        # Phase 1: schema + empty contract tables
│   │   ├── 01_schema.sql            # DWELL_CORE schema creation
│   │   ├── 02_policy.sql            # POLICY table (parameterized thresholds)
│   │   ├── 03_site.sql              # SITE: monitored facility
│   │   └── 04_zone.sql              # ZONE: sub-areas within a site
│   └── transforms/                  # Phase 3: views + dynamic tables (depend on adapter)
│       ├── 01_observation.sql       # OBSERVATION: contract view over OBSERVATION_SOURCE
│       ├── 02_presence_point.sql    # PRESENCE_POINT: on-ground/in-facility points
│       ├── 03_dwell_session.sql     # DWELL_SESSION: aggregated sessions
│       ├── 04_zone_assignment.sql   # ZONE_ASSIGNMENT: point-to-zone mapping
│       ├── 05_zone_dwell_fact.sql   # ZONE_DWELL_FACT: daily zone utilization
│       └── 06_congestion_placeholder.sql  # CONGESTION_CELL_FACT (future)
├── adapters/airport/                # Phase 2: airport-specific source mappings
│   ├── 01_site.sql                  # PROPERTIES_AIRPORT → SITE
│   ├── 02_zone.sql                  # PROPERTIES_GATES → ZONE
│   ├── 03_seed_policy.sql           # Seed airport-specific thresholds
│   └── 04_observation_source.sql    # ADSB_DATA_LOCAL → OBSERVATION_SOURCE
├── policies/                        # Policy documentation + overrides
│   └── airport_defaults.sql         # Documents standard airport thresholds
├── compat/
│   └── airport/                     # Phase 4: backward-compatible PUBLIC objects (airport)
│       ├── gate_analysis.sql        # GATE_ANALYSIS_* dynamic tables
│       ├── flight_traffic.sql       # FLIGHT_TRAFFIC_FACT_* dynamic tables
│       ├── flight_tracker.sql       # FLIGHT_TRACKER_FLIGHT_LIST + HELPER views
│       ├── landing_timetable.sql    # HELPER_LANDING_LIVE_TIMETABLE
│       ├── runway_crossings.sql     # RUNWAY_CROSSINGS_DETAILED
│       └── zz_post_install.sql      # REFRESH / RESUME for compat DTs
└── smoke_tests/                     # Phase 5: verification
    ├── 01_core.sql                  # Core contract validation (domain-agnostic)
    └── 02_airport.sql               # Airport PUBLIC objects validation
```

## Installation Phases

The SQL modules execute in a strict 5-phase order:

| Phase | Module | Purpose |
|-------|--------|---------|
| 1 | `core/base` | Create DWELL_CORE schema and empty contract tables |
| 2 | `adapters/<name>` | Seed SITE, ZONE, POLICY; create OBSERVATION_SOURCE |
| 3 | `core/transforms` | Create OBSERVATION view + Dynamic Tables that consume OBSERVATION_SOURCE |
| 4 | `compat/{adapter}` | Re-create PUBLIC Dynamic Tables backed by DWELL_CORE (e.g. `compat/airport/`) |
| 5 | `smoke_tests` | Verify objects exist and pass sanity checks |

This ordering ensures adapters populate base tables _before_ transforms try to read them,
and the compat layer overwrites inline DTs _after_ both core and transforms are in place.

## Core Contract

The `DWELL_CORE` schema contains **domain-agnostic** primitives:

| Object | Type | Description |
|--------|------|-------------|
| `SITE` | Table | A monitored facility (airport, port, warehouse) |
| `ZONE` | Table | A sub-area within a site (gate, dock, bay) |
| `POLICY` | Table | Parameterized thresholds per site |
| `OBSERVATION_SOURCE` | View | Adapter-created mapping of raw telemetry to canonical columns |
| `OBSERVATION` | View | Stable contract view over OBSERVATION_SOURCE |
| `PRESENCE_POINT` | Dynamic Table | Filtered in-facility points with sessionization |
| `DWELL_SESSION` | Dynamic Table | Aggregated dwell sessions |
| `ZONE_ASSIGNMENT` | Dynamic Table | Point-to-zone mapping |
| `ZONE_DWELL_FACT` | Dynamic Table | Daily zone-level dwell aggregation |
| `CONGESTION_CELL_FACT` | Table | Placeholder for future congestion analytics |

**Key design principles:**
- No "gate", "runway", "flight" in core table/column names
- Thresholds read from `POLICY` (never hardcoded)
- Core never references domain-specific tables (e.g., `ADSB_DATA_LOCAL`) — only `OBSERVATION_SOURCE`
- Altitude filter is optional (tolerates NULL for non-altimeter sources)
- Facility geofence uses `SITE.site_geom` + `POLICY.facility_radius_m` (skipped if site_geom is NULL)
- The `attrs VARIANT` column on every object carries domain-specific data without schema changes

## OBSERVATION_SOURCE Contract

The adapter (or BYO mapping) must create `DWELL_CORE.OBSERVATION_SOURCE` as a view with these columns:

| Column | Type | Required | Description |
|--------|------|----------|-------------|
| `site_id` | STRING | Yes | FK to SITE.site_id |
| `asset_id` | STRING | Yes | Unique asset identifier |
| `observed_ts_utc` | TIMESTAMP_NTZ | Yes | UTC timestamp |
| `observed_ts_local` | TIMESTAMP_NTZ | Yes | Local timestamp (derived from site timezone) |
| `service_date_local` | DATE | Yes | Local calendar date (for sessionization) |
| `location` | GEOGRAPHY | Yes | Position |
| `speed` | FLOAT | No | Speed in **knots** (matches `POLICY.ground_speed_max_kts`; NULL OK) |
| `heading` | FLOAT | No | Heading/course (NULL OK) |
| `altitude` | NUMBER | No | Altitude in **feet** (matches `POLICY.ground_altitude_max_ft`; NULL OK) |
| `source` | STRING | No | Data source label |
| `asset_category` | STRING | No | Asset type/category |
| `attrs` | VARIANT | No | Domain-specific fields (callsign, registration, etc.) |

## Template Parameters

All `.sql` files use `${PARAM}` syntax for substitution:

| Parameter | Example | Description |
|-----------|---------|-------------|
| `${DATABASE}` | `AIRPORT_SFO` | Target database name |
| `${SCHEMA}` | `PUBLIC` | Target schema (always PUBLIC for dashboards) |
| `${WAREHOUSE}` | `COMPUTE_WH` | Warehouse for dynamic tables |

## How to Add a New Adapter (e.g., Port / Warehouse)

To extend this system for a new domain, create an adapter directory with 4 files:

### 1. New adapter directory

```
installer/sql/adapters/port/
├── 01_site.sql              # Map port properties → DWELL_CORE.SITE
├── 02_zone.sql              # Map berths/docks → DWELL_CORE.ZONE
├── 03_seed_policy.sql       # Seed port-specific thresholds
└── 04_observation_source.sql # Map AIS data → DWELL_CORE.OBSERVATION_SOURCE
```

### 2. Implement SITE mapping

```sql
MERGE INTO ${DATABASE}.DWELL_CORE.SITE t
USING (
  SELECT
    port_id        AS site_id,
    port_code      AS site_code,
    port_name      AS site_name,
    port_timezone  AS site_tzid,
    port_boundary  AS site_geom,
    'port'         AS site_type,
    OBJECT_CONSTRUCT('country', country) AS attrs
  FROM ${DATABASE}.${SCHEMA}.PORT_PROPERTIES
) s
ON t.site_id = s.site_id
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT ...;
```

### 3. Implement OBSERVATION_SOURCE

```sql
CREATE OR REPLACE VIEW ${DATABASE}.DWELL_CORE.OBSERVATION_SOURCE AS
SELECT
  s.site_id                                    AS site_id,
  v.MMSI                                       AS asset_id,
  v.RECEIVED_AT                                AS observed_ts_utc,
  CONVERT_TIMEZONE('UTC', s.site_tzid, v.RECEIVED_AT)::TIMESTAMP_NTZ
                                               AS observed_ts_local,
  TO_DATE(CONVERT_TIMEZONE('UTC', s.site_tzid, v.RECEIVED_AT))
                                               AS service_date_local,
  ST_MAKEPOINT(v.LON, v.LAT)                  AS location,
  v.SOG                                        AS speed,
  v.COG                                        AS heading,
  NULL                                         AS altitude,
  'ais'                                        AS source,
  v.SHIP_TYPE                                  AS asset_category,
  OBJECT_CONSTRUCT('vessel_name', v.NAME, 'flag', v.FLAG) AS attrs
FROM ${DATABASE}.${SCHEMA}.AIS_POSITIONS v
INNER JOIN ${DATABASE}.DWELL_CORE.SITE s ON s.site_type = 'port';
```

### 4. Seed policy with domain-specific thresholds

```sql
MERGE INTO ${DATABASE}.DWELL_CORE.POLICY t
USING (
  SELECT
    s.site_id,
    NULL  AS ground_altitude_max_ft,   -- not applicable for vessels
    5     AS ground_speed_max_kts,     -- berthed vessel speed
    60    AS session_gap_minutes,      -- longer gap for port operations
    2000  AS facility_radius_m,        -- port approach radius
    200   AS zone_assign_radius_m      -- berth assignment radius
  FROM ${DATABASE}.DWELL_CORE.SITE s
  WHERE s.site_type = 'port'
) src
ON t.site_id = src.site_id
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT ...;
```

### 5. Register in installer

Add the new adapter to the module loading order in `sql_runner.py`:

```python
generate_dwell_core_sql(database, schema, warehouse, adapter="port")
```

And add the corresponding module directory handling (or use `"adapters/port"` in the module order).

Once the adapter populates SITE, ZONE, POLICY, and creates OBSERVATION_SOURCE,
all core transforms work automatically with the domain-specific thresholds.

## BYO (Bring-Your-Own) Telemetry

For customers who want to use their own telemetry table without writing an adapter:

```python
from sql_runner import generate_dwell_core_sql

sql = generate_dwell_core_sql(
    database="MY_DB",
    schema="PUBLIC",
    warehouse="MY_WH",
    adapter="byo",
    byo_config={
        "source_relation": "MY_DB.PUBLIC.VEHICLE_POSITIONS",
        "column_mapping": {
            "asset_id_col": "VEHICLE_TAG",
            "ts_col": "RECORDED_AT",
            "lat_col": "LAT",
            "lon_col": "LON",
            "speed_col": "SPEED_KPH",
            "speed_unit": "KPH",
            "speed_multiplier": 0.539957,    # kph → knots
            "altitude_col": "ALT_M",
            "altitude_unit": "M",
            "altitude_multiplier": 3.28084,  # meters → feet
            "asset_category_col": "VEHICLE_TYPE",
        },
        "site_config": {
            "site_id": "warehouse-01",
            "site_name": "Main Distribution Center",
            "site_timezone": "America/Chicago",
            "site_lat": 41.8781,
            "site_lon": -87.6298,
            "site_type": "warehouse",
        },
        "policy_overrides": {
            "ground_speed_max_kts": 15,
            "session_gap_minutes": 10,
            "facility_radius_m": 500,
            "zone_assign_radius_m": 30,
        },
    },
)
```

This generates SITE, POLICY, and OBSERVATION_SOURCE SQL without any file-based adapter.

### BYO Column Mapping — Unit Conversion

The core contract expects **speed in knots** and **altitude in feet** (matching `POLICY` column names).
If your telemetry uses different units, provide conversion via the mapping keys below.

| Key | Type | Description |
|-----|------|-------------|
| `speed_col` | string | Source column name for speed |
| `speed_expr` | string | Raw SQL expression (overrides `speed_col`); e.g. `"src.SPEED_KPH * 0.539957"` |
| `speed_multiplier` | number | Factor applied to `speed_col` (e.g. `0.539957` for kph→kts) |
| `speed_unit` | string | Declared source unit (e.g. `"KPH"`, `"MPS"`). If not `"KTS"`, requires `speed_expr` or `speed_multiplier` |
| `altitude_col` | string | Source column name for altitude |
| `altitude_expr` | string | Raw SQL expression (overrides `altitude_col`); e.g. `"src.ALT_M * 3.28084"` |
| `altitude_multiplier` | number | Factor applied to `altitude_col` (e.g. `3.28084` for m→ft) |
| `altitude_unit` | string | Declared source unit (e.g. `"M"`). If not `"FT"`, requires `altitude_expr` or `altitude_multiplier` |

**Resolution priority** (same for both speed and altitude):

1. `*_expr` — full SQL expression, maximum flexibility
2. `*_multiplier` × `*_col` — simple numeric conversion
3. `*_col` — pass-through (assumed to already be in canonical units)
4. `NULL` — if no column provided

## Execution Order (Full Airport Install)

The modular SQL is generated as `06_dwell_core.sql` and runs after:
1. `01_base.sql` — Database, properties, airline dim
2. `02_adsb.sql` — ADS-B ingestion procedures and tables
3. `03_adsb_history_backfill.sql` — Historical data backfill
4. `04_flight_schedule.sql` — Flight schedule ingestion (optional)
5. `05_derived.sql` — ADSB_DATA_LOCAL, monitoring, tasks, backfill start

The compat layer (inside `06_dwell_core.sql`) re-creates the PUBLIC dynamic tables
to SELECT FROM DWELL_CORE objects, overwriting the inline versions from `05_derived.sql`.

## Migration Notes

- **Existing installs**: Re-running the installer is safe (idempotent). The `DWELL_CORE`
  schema and objects are created alongside existing PUBLIC objects.
- **No dashboard changes required**: All PUBLIC object names, columns, and semantics
  are preserved by the compatibility layer.
- **Policy tuning**: After install, you can adjust thresholds by updating
  `DWELL_CORE.POLICY` rows directly — no code changes needed.
