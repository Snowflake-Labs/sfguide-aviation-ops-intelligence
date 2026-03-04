"""
Airport Analytics Installer (Snowflake Native)

A Streamlit app that generates and optionally executes customized SQL setup scripts.
Designed to run inside Snowflake Streamlit with access to the Snowpark session.

Usage (in Snowflake):
    CREATE STREAMLIT installer FROM @repo/branches/main MAIN_FILE = 'installer_snowflake.py';
"""

import streamlit as st
import pandas as pd
from datetime import datetime
import re
import subprocess

from sql_runner import (
    generate_dwell_core_sql,
    load_module_sql,
)


_RE_SECRET_STRING = re.compile(r"(SECRET_STRING\s*=\s*)'[^']*'(\s*;)", flags=re.IGNORECASE)


def _mask_sql_secrets(sql_text: str) -> str:
    """
    Mask any inline SECRET_STRING literals so we don't display secrets in the Streamlit UI.
    Note: we still execute the real SQL (unmasked).
    """
    try:
        return _RE_SECRET_STRING.sub(r"\1'***REDACTED***'\2", sql_text or "")
    except Exception:
        return sql_text


def _normalize_git_repo_stage_base(stage_base: str) -> str:
    """Normalize a user-provided Git repo stage base.

    Expected format (either is fine):
      - @REPO_NAME/branches/<branch>
      - @DB.SCHEMA.REPO_NAME/branches/<branch>   (fully qualified)

    Key behavior:
    - Adds a leading '@' if missing.
    - Preserves DB.SCHEMA qualification (often required), because unqualified @REPO
      resolves in the *current* schema (e.g. AIRPORT_SAN.PUBLIC) and may not exist there.
    """
    s = (stage_base or "").strip()
    if not s:
        return "@AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main"
    if not s.startswith("@"):
        s = "@" + s

    return s.rstrip("/")
def _get_git_sha_short() -> str:
    """Best-effort git sha for install audit metadata."""
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return "unknown"

# Try to get Snowflake session (only works in Snowflake Streamlit)
try:
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
    IN_SNOWFLAKE = True
except Exception:
    session = None
    IN_SNOWFLAKE = False


# Page config
st.set_page_config(
    page_title="Airport Analytics Installer",
    page_icon="✈️",
    layout="wide"
)

# Custom CSS
st.markdown("""
<style>
    .main-header {
        font-size: 2.5rem;
        font-weight: 700;
        color: #1E3A5F;
        margin-bottom: 0.5rem;
    }
    .sub-header {
        font-size: 1.1rem;
        color: #666;
        margin-bottom: 2rem;
    }
    .success-box {
        background-color: #d4edda;
        border: 1px solid #c3e6cb;
        border-radius: 5px;
        padding: 1rem;
        margin: 1rem 0;
    }
    .code-box {
        background-color: #f8f9fa;
        border: 1px solid #dee2e6;
        border-radius: 5px;
        padding: 1rem;
        font-family: monospace;
        white-space: pre-wrap;
        max-height: 400px;
        overflow-y: auto;
    }
</style>
""", unsafe_allow_html=True)


# ============================================================================
# AIRPORT DATA
# Installer is Snowflake-native: airport inventory is sourced from Overture Maps.
# ============================================================================


def _sql_escape_str(s: str) -> str:
    """Escape a Python string for embedding as a single-quoted SQL string literal."""
    return ("" if s is None else str(s)).replace("'", "''")


@st.cache_data
def load_airports():
    """Load airports from Overture Maps (Snowflake required)."""
    if not (IN_SNOWFLAKE and session):
        # No local fallback: this installer is intended to run inside Snowflake Streamlit.
        return pd.DataFrame()

    # User-requested simplified airport inventory query:
    # - Uses two FLATTENs + GROUP BY (acceptable for inventory list)
    # - Filters out Point geometries
    # - Returns id + English name + IATA/ICAO
    overture_q = """
    SELECT
        i.id AS AIRPORT_ID,
        COALESCE(
            MAX(IFF(n.value:"key"::STRING = 'en', NULLIF(TRIM(n.value:"value"::STRING), ''), NULL)),
            i.names:primary::STRING
        ) AS AIRPORT_NAME,
        COALESCE(
            MAX(IFF(LOWER(t.value:"key"::STRING) IN ('iata','iata_code','iata:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)),
            ''
        ) AS AIRPORT_CODE_IATA,
        COALESCE(
            MAX(IFF(LOWER(t.value:"key"::STRING) IN ('icao','icao_code','icao:code'), NULLIF(TRIM(t.value:"value"::STRING), ''), NULL)),
            ''
        ) AS AIRPORT_CODE_ICAO
    FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
        , LATERAL FLATTEN(input => i.names:"common":"key_value", OUTER => TRUE) n
        , LATERAL FLATTEN(
            input => IFF(IS_OBJECT(i.source_tags), i.source_tags, TRY_PARSE_JSON(i.source_tags)):"key_value",
            OUTER => TRUE
        ) t
    WHERE i.class ILIKE '%international_airport%'
      AND i.subtype ILIKE '%airport%'
      AND ST_ASGEOJSON(i.geometry):type::STRING <> 'Point'
    GROUP BY i.id, i.names:primary::STRING
    HAVING COALESCE(
        MAX(IFF(n.value:"key"::STRING = 'en', NULLIF(TRIM(n.value:"value"::STRING), ''), NULL)),
        i.names:primary::STRING
    ) IS NOT NULL
    ORDER BY AIRPORT_NAME
    LIMIT 5000
    """
    try:
        df = session.sql(overture_q).to_pandas()
        if df is not None and not df.empty and 'AIRPORT_ID' in df.columns:
            st.sidebar.success(f"✅ Loaded {len(df)} airports from Overture Maps")
            return df
        return pd.DataFrame()
    except Exception as e:
        st.sidebar.error(f"Failed to load airports from Overture Maps: {e}")
        return pd.DataFrame()


@st.cache_data(ttl=3600)
def load_airport_geometry_by_id(airport_id: str):
    """Fetch airport geometry + centroid from Overture Maps by record id."""
    if not (IN_SNOWFLAKE and session) or not airport_id:
        return None
    q = f"""
    SELECT
      TO_VARCHAR(ST_ASGEOJSON(i.geometry)) AS geometry_json_str,
      ST_Y(ST_CENTROID(i.geometry)) AS center_lat,
      ST_X(ST_CENTROID(i.geometry)) AS center_lon
    FROM OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE i
    WHERE i.id = '{_sql_escape_str(airport_id)}'
      AND i.class ILIKE '%international_airport%'
      AND i.subtype ILIKE '%airport%'
      AND ST_ASGEOJSON(i.geometry):type::STRING <> 'Point'
    LIMIT 1
    """
    try:
        df = session.sql(q).to_pandas()
        if df is None or df.empty:
            return None
        row = df.iloc[0].to_dict()
        return {
            "GEOMETRY": row.get("GEOMETRY_JSON_STR"),
            "CENTER_LAT": row.get("CENTER_LAT"),
            "CENTER_LON": row.get("CENTER_LON"),
        }
    except Exception:
        return None


# ============================================================================
# SQL TEMPLATE PARAMETER BUILDER
# ============================================================================


def _build_airport_params(
    airport: dict,
    database: str,
    schema: str,
    warehouse: str,
    git_repo_stage_base: str,
    adsb_history_backfill_days: int = 5,
) -> dict:
    """Build the full parameter dict for airport SQL template substitution.

    All computed/derived values are pre-resolved here so that SQL templates
    only need simple ${KEY} placeholders.
    """
    return {
        "DATABASE": database,
        "SCHEMA": schema,
        "WAREHOUSE": warehouse,
        # Airport identity (SQL-escaped for safe embedding in single-quoted literals)
        "AIRPORT_NAME": _sql_escape_str(airport.get("name")),
        "AIRPORT_IATA": _sql_escape_str(airport.get("iata_code")),
        "AIRPORT_ICAO": _sql_escape_str(airport.get("icao_code")),
        "AIRPORT_ID": _sql_escape_str(airport.get("airport_id")),
        "AIRPORT_LAT": str(airport.get("lat", "")),
        "AIRPORT_LON": str(airport.get("lon", "")),
        # External Access Integration names (account-level, per-airport to avoid collisions)
        "EAI_ADSB_LOL": re.sub(r"[^A-Za-z0-9_]", "_", f"{database}_{schema}_ADSB_LOL_EAI").upper(),
        "EAI_GITHUB": re.sub(r"[^A-Za-z0-9_]", "_", f"{database}_{schema}_GITHUB_EAI").upper(),
        # Derived URLs/references
        "API_URL": f"https://api.adsb.lol/v2/point/{airport.get('lat')}/{airport.get('lon')}/27",
        "ADSB_RAW_TABLE": f"{database}.{schema}.HELPER_ADSB_LOL_RAW",
        "GIT_REPO_STAGE_BASE": git_repo_stage_base,
        "ADSB_HISTORY_BACKFILL_DAYS": str(int(adsb_history_backfill_days or 5)),
        # Install audit metadata
        "INSTALLER_SHA": _get_git_sha_short(),
        "INSTALLER_GENERATED_AT": datetime.utcnow().isoformat(),
    }


def generate_all_sql(
    airport: dict,
    database: str,
    schema: str,
    warehouse: str,
    api_key: str = None,
    git_repo_stage_base: str = "@AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main",
    adsb_history_backfill_days: int = 5,
) -> dict:
    """Generate all SQL files from modular templates.

    Execution order:
    1. Generic infrastructure (database, schema, network, tags)
    2. Airport properties (PROPERTIES_*, UDFs, airline dim, schedule tables)
    3. ADS-B setup (tables, procedures, tasks, history backfill)
    4. Flight Schedule (conditional, requires api_key)
    5. Derived analytics (ADSB_DATA_LOCAL, monitoring, tasks, startup)
    6. DWELL_CORE modular layer (core contract + airport adapter + compat)
    """
    params = _build_airport_params(
        airport, database, schema, warehouse,
        git_repo_stage_base, adsb_history_backfill_days,
    )

    files = {
        '01_infra.sql': load_module_sql('infra', params),
        '02_airport_properties.sql': load_module_sql('adapters/airport/properties', params),
        '03_adsb.sql': load_module_sql('adapters/airport/adsb', params),
    }

    if api_key:
        sched_params = {
            **params,
            'API_KEY': api_key,
            'EAI_AVIATIONSTACK': re.sub(
                r"[^A-Za-z0-9_]", "_",
                f"{database}_{schema}_AVIATIONSTACK_EAI",
            ).upper(),
            'SCHEDULE_RAW_TABLE': f"{database}.{schema}.HELPER_FLIGHT_SCHEDULE_RAW",
            'BACKFILL_DAYS': str(max(2, int(adsb_history_backfill_days or 2))),
        }
        files['04_flight_schedule.sql'] = load_module_sql('adapters/airport/schedule', sched_params)

    files['05_derived.sql'] = load_module_sql('adapters/airport/derived', params)

    # DWELL_CORE modular layer (core contract + airport adapter + compat)
    # Must run AFTER 05_derived because:
    #   - DWELL_CORE.OBSERVATION depends on ADSB_DATA_LOCAL (created in 05_derived)
    #   - Compat layer creates gate/traffic/runway DTs in PUBLIC from DWELL_CORE objects.
    files['06_dwell_core.sql'] = generate_dwell_core_sql(database, schema, warehouse)

    return files


# ============================================================================
# TASK MONITOR (Snowflake only)
# ============================================================================

def render_task_monitor(database: str, schema: str):
    """Show task status + recent history for the selected airport DB/schema."""
    if not (IN_SNOWFLAKE and session):
        return

    st.divider()
    st.subheader("🧾 Task Status")

    col_a, col_b = st.columns([1, 3])
    with col_a:
        refresh = st.button("🔄 Refresh", use_container_width=True)
    with col_b:
        st.caption(f"Showing tasks in `{database}.{schema}`")

    if refresh:
        st.rerun()

    # Avoid burning inbound queries on every rerun: cache results briefly in session_state.
    # This also reduces the chance of hitting Streamlit-in-Snowflake inbound query limits.
    import time
    cache_ttl_s = 30
    cache_key = f"_task_status_cache::{database}.{schema}"
    cache = st.session_state.get(cache_key) or {}
    cache_age = (time.time() - float(cache.get("ts", 0) or 0)) if cache else 1e9

    # Current task state
    try:
        if refresh or ("tasks_df" not in cache) or (cache_age > cache_ttl_s):
            tasks_df = session.sql(f"SHOW TASKS IN SCHEMA {database}.{schema}").to_pandas()
            cache["tasks_df"] = tasks_df
            cache["ts"] = time.time()
            st.session_state[cache_key] = cache
        else:
            tasks_df = cache["tasks_df"]
        # Normalize column names.
        # In some environments pandas may preserve quotes in the column names (e.g. '"name"').
        def _norm_col(c):
            s = str(c).strip()
            # strip wrapping quotes repeatedly
            while (len(s) >= 2) and ((s[0] == s[-1]) and s[0] in ("'", '"')):
                s = s[1:-1].strip()
            return s.lower()
        tasks_df.columns = [_norm_col(c) for c in tasks_df.columns]
        if not tasks_df.empty:
            # Focus on relevant tasks (backfill + core ingestion tasks)
            interesting = {"TASK_ADSB_BACKFILL_ONCE", "TASK_INGEST_ADSB", "TASK_FLIGHT_SCHEDULE"}
            if "name" not in tasks_df.columns:
                st.warning(f"Could not fetch task status: missing column 'name'. Columns: {list(tasks_df.columns)[:20]}")
                tasks_df = None
            else:
                tasks_df["name_upper"] = tasks_df["name"].astype(str).str.upper()
        if tasks_df is not None and not tasks_df.empty:
            show_df = tasks_df[tasks_df["name_upper"].isin(interesting)].copy()
            if show_df.empty:
                show_df = tasks_df.copy()
            cols = [c for c in [
                "name", "state", "schedule", "warehouse", "last_suspended_on",
                "last_succeeded_on", "last_failed_on", "error_message"
            ] if c in show_df.columns]
            st.dataframe(show_df[cols], use_container_width=True, hide_index=True)
        elif tasks_df is not None:
            st.info("No tasks found in this schema.")
    except Exception as e:
        st.warning(f"Could not fetch task status: {str(e)[:200]}")

    # Recent task history can be permission-restricted in Streamlit contexts, and it costs extra queries.
    # Make it explicit/opt-in.
    show_history = st.checkbox(
        "Show recent task history (may require extra permissions)",
        value=False,
        help="Uses INFORMATION_SCHEMA.TASK_HISTORY(); may fail depending on your Streamlit execution context."
    )
    if show_history:
        try:
            hist_cache_key = f"_task_history_cache::{database}.{schema}"
            hcache = st.session_state.get(hist_cache_key) or {}
            h_age = (time.time() - float(hcache.get("ts", 0) or 0)) if hcache else 1e9
            if refresh or ("hist_df" not in hcache) or (h_age > cache_ttl_s):
                hist_df = session.sql(f"""
                    SELECT *
                    FROM TABLE({database}.INFORMATION_SCHEMA.TASK_HISTORY())
                    WHERE SCHEMA_NAME = '{schema}'
                      AND NAME ILIKE '%TASK_%'
                    ORDER BY SCHEDULED_TIME DESC
                    LIMIT 50
                """).to_pandas()
                hcache["hist_df"] = hist_df
                hcache["ts"] = time.time()
                st.session_state[hist_cache_key] = hcache
            else:
                hist_df = hcache["hist_df"]

            if not hist_df.empty:
                cols = [c for c in [
                    "name", "state", "scheduled_time", "query_start_time",
                    "completed_time", "error_code", "error_message"
                ] if c in hist_df.columns]
                st.caption("Recent task runs")
                st.dataframe(hist_df[cols], use_container_width=True, hide_index=True)
            else:
                st.caption("No recent history rows returned.")
        except Exception:
            # Keep UI clean; SHOW TASKS is the main view
            st.caption("Task history unavailable in this context.")


# ============================================================================
# MAIN APP
# ============================================================================

def main():
    st.markdown('<p class="main-header">✈️ Airport Analytics Installer</p>', unsafe_allow_html=True)
    st.markdown('<p class="sub-header">Generate and execute Snowflake setup scripts for any airport</p>', unsafe_allow_html=True)
    
    if IN_SNOWFLAKE:
        st.success("✅ Running in Snowflake Streamlit")
    else:
        st.info("ℹ️ Running locally (SQL execution disabled)")
    
    # Load airports
    airports_df = load_airports()
    
    if airports_df.empty:
        st.error("No airports loaded.")
        st.markdown(
            "This installer requires Snowflake Streamlit access to "
            "`OVERTURE_MAPS__BASE.CARTO.INFRASTRUCTURE`.\n\n"
            "Before running the installer, install these Snowflake Marketplace listings:\n"
            "- [Overture Maps - Base](https://app.snowflake.com/marketplace/listing/GZT0Z4CM1E9KV/carto-overture-maps-base)\n"
            "- [Overture Maps - Buildings](https://app.snowflake.com/marketplace/listing/GZT0Z4CM1E9KN/carto-overture-maps-buildings)\n"
            "- [Overture Maps - Transportation](https://app.snowflake.com/marketplace/listing/GZT0Z4CM1E9KJ/carto-overture-maps-transportation)\n"
        )
        return
    
    # Sidebar
    st.sidebar.header("⚙️ Configuration")
    
    # Use stable row indices as the selectbox value to avoid relying on IATA being present/unique.
    airport_idx = st.sidebar.selectbox(
        "🛫 Select Airport",
        options=list(airports_df.index),
        format_func=lambda i: (
            f"{airports_df.loc[i, 'AIRPORT_NAME']} "
            f"({airports_df.loc[i, 'AIRPORT_CODE_IATA'] or airports_df.loc[i, 'AIRPORT_CODE_ICAO']})"
        ),
    )
    selected_airport = airports_df.loc[airport_idx]
    # selected_airport is a Series row now
    
    st.sidebar.divider()
    st.sidebar.subheader("🔑 API Key")
    # API key must be manually entered by user - no auto-loading from files/env
    api_key = st.sidebar.text_input(
        "Aviationstack API Key (Optional)",
        type="password",
        help="Required for flight schedule ingestion. Get a key at aviationstack.com",
    )
    if not api_key:
        st.sidebar.caption("⚠️ Flight schedule ingestion requires API key")

    st.sidebar.divider()
    st.sidebar.subheader("🗂️ Historical Backfill")
    adsb_history_backfill_days = st.sidebar.number_input(
        "ADS-B history backfill days (UTC, ending yesterday)",
        min_value=0,
        max_value=30,
        value=5,
        step=1,
        help="How many full UTC days of ADS-B history to backfill on install (from globe_history GitHub releases). 0 disables the one-time history backfill.",
    )
    
    # Get warehouse from current session (uses the same warehouse as Streamlit app)
    if IN_SNOWFLAKE and session:
        try:
            warehouse_result = session.sql("SELECT CURRENT_WAREHOUSE()").collect()
            warehouse = warehouse_result[0][0] if warehouse_result else "COMPUTE_WH"
        except Exception:
            warehouse = "COMPUTE_WH"
    else:
        warehouse = "COMPUTE_WH"
    
    
    
    # Main content
    col1, col2 = st.columns([2, 1])
    
    airport = {
        'name': selected_airport['AIRPORT_NAME'],
        'iata_code': selected_airport['AIRPORT_CODE_IATA'],
        'icao_code': selected_airport['AIRPORT_CODE_ICAO'],
        'airport_id': selected_airport.get('AIRPORT_ID'),
        # Geometry/centroid are fetched by id (keeps airport inventory query simpler).
        'geometry': None,
        'lat': None,
        'lon': None,
    }

    # Fetch shape/centroid from Overture for the selected airport record id.
    details = load_airport_geometry_by_id(airport.get("airport_id"))
    if details:
        airport["geometry"] = details.get("GEOMETRY")
        airport["lat"] = details.get("CENTER_LAT")
        airport["lon"] = details.get("CENTER_LON")
    else:
        st.warning("Could not fetch airport geometry for the selected record. Base install may fail until Overture data is available.")

    # Prefer IATA for naming, but allow ICAO fallback if IATA is missing.
    db_suffix = (airport.get('iata_code') or '').strip().upper() or (airport.get('icao_code') or '').strip().upper()
    database = f"AIRPORT_{db_suffix}"
    schema = "PUBLIC"
    
    with col1:
        st.subheader("📍 Selected Airport")
        st.metric("Database", f"{database}.{schema}")
        st.caption(f"{airport['name']} • {airport['iata_code']}/{airport['icao_code']}")
        if pd.notna(airport['lat']):
            st.caption(f"📍 {airport['lat']:.4f}°, {airport['lon']:.4f}°")

    # Git repo stage base for loading bundled CSVs (e.g., airlines.csv) via SQL COPY.
    # Must point at a Snowflake Git Repository object (not a schema stage).
    with st.expander("Advanced: Git repo stage path", expanded=False):
        git_repo_stage_base_input = st.text_input(
            "Git repo stage base",
            value="@AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main",
            help="Example: @REPO_NAME/branches/main (or fully-qualified @DB.SCHEMA.REPO_NAME/branches/main). Do not include a trailing slash.",
        )
        git_repo_stage_base = _normalize_git_repo_stage_base(git_repo_stage_base_input)
        st.caption(f"Normalized: `{git_repo_stage_base}`")
    
    st.divider()
    
    # Buttons
    col_btn1, col_btn2, col_btn3 = st.columns(3)
    
    with col_btn1:
        generate_clicked = st.button("🔨 Generate SQL", type="primary", use_container_width=True)
    
    with col_btn2:
        execute_clicked = st.button(
            "⚡ Execute in Snowflake",
            disabled=not IN_SNOWFLAKE,
            use_container_width=True,
            help="Run the SQL directly in Snowflake" if IN_SNOWFLAKE else "Only available in Snowflake Streamlit"
        )
    
    if generate_clicked or execute_clicked:
        with st.spinner("Generating SQL..."):
            sql_files = generate_all_sql(
                airport, database, schema, warehouse, 
                api_key if api_key else None,
                git_repo_stage_base=git_repo_stage_base,
                adsb_history_backfill_days=int(adsb_history_backfill_days),
            )
            
            st.session_state['sql_files'] = sql_files
            st.session_state['database'] = database
        
        st.success(f"✅ Generated {len(sql_files)} SQL files")

    # Preview generated SQL before execution
    if 'sql_files' in st.session_state and st.session_state['sql_files']:
        st.divider()
        st.subheader("🧾 SQL Preview")
        st.caption("Review the generated SQL below before clicking **Execute in Snowflake**.")
        for filename, sql_content in st.session_state['sql_files'].items():
            with st.expander(f"📄 {filename}", expanded=False):
                st.code(_mask_sql_secrets(sql_content), language="sql")
    
    # Execute if requested
    if execute_clicked and IN_SNOWFLAKE and 'sql_files' in st.session_state:
        st.divider()
        st.subheader("⚡ Executing SQL...")
        
        def split_sql_statements(sql_content):
            """Split SQL into statements, respecting $$ procedure blocks."""
            statements = []
            current = []
            in_dollar_block = False
            
            lines = sql_content.split('\n')
            for line in lines:
                stripped = line.strip()
                
                # Skip standalone comments and empty lines when not building a statement
                if not current and not in_dollar_block:
                    if not stripped or stripped.startswith('--'):
                        continue
                
                # Check for $$ delimiter (used by all procedures now)
                if '$$' in line:
                    dollar_count = line.count('$$')
                    if dollar_count % 2 == 1:  # Odd number toggles state
                        in_dollar_block = not in_dollar_block
                
                # Add line to current statement
                current.append(line)
                
                # Check if statement is complete
                # Only end statement if: NOT in dollar block AND line ends with semicolon
                if not in_dollar_block and stripped.endswith(';'):
                    stmt = '\n'.join(current).strip()
                    if stmt and not stmt.startswith('--'):
                        statements.append(stmt)
                    current = []
            
            # Add any remaining content
            if current:
                stmt = '\n'.join(current).strip()
                if stmt and not stmt.startswith('--'):
                    statements.append(stmt)
            
            return statements
        
        overall_error_count = 0
        for filename, sql_content in st.session_state['sql_files'].items():
            with st.expander(f"📄 {filename}", expanded=True):
                try:
                    statements = split_sql_statements(sql_content)

                    # Remove USE statements entirely (we fully-qualify object names)
                    statements = [s for s in statements if not s.strip().upper().startswith('USE ')]
                    
                    st.info(f"Found {len(statements)} statements to execute")
                    
                    success_count = 0
                    error_count = 0
                    
                    # Create a list of placeholders for all statements
                    placeholders = []
                    for i, stmt in enumerate(statements):
                        placeholders.append(st.empty())
                        stmt_preview = stmt[:100].replace('\n', ' ') + ('...' if len(stmt) > 100 else '')
                        placeholders[i].write(f"⚪ {i+1}. `{stmt_preview}` (Pending)")
                    
                    for i, stmt in enumerate(statements):
                        # Show abbreviated statement
                        stmt_preview = stmt[:100].replace('\n', ' ') + ('...' if len(stmt) > 100 else '')
                        
                        # Update status to In Progress
                        placeholders[i].write(f"⏳ {i+1}. `{stmt_preview}` (Running...)")
                        
                        try:
                            session.sql(stmt).collect()
                            placeholders[i].write(f"✅ {i+1}. `{stmt_preview}`")
                            success_count += 1
                        except Exception as e:
                            placeholders[i].error(f"❌ {i+1}. `{stmt_preview}`\n   Error: {str(e)[:200]}")
                            error_count += 1
                    
                    if error_count == 0:
                        st.success(f"✅ All {success_count} statements executed successfully!")
                    else:
                        st.warning(f"⚠️ Completed with {error_count} errors out of {success_count + error_count} statements")
                    overall_error_count += error_count
                        
                except Exception as e:
                    st.error(f"Error processing file: {e}")
                    overall_error_count += 1

        # Airline reference is loaded via SQL (COPY INTO) during base install.
    
    # Display generated SQL
    if 'sql_files' in st.session_state:
        st.divider()
        st.subheader("📄 Generated SQL")
        
        tabs = st.tabs(list(st.session_state['sql_files'].keys()))
        for tab, (filename, content) in zip(tabs, st.session_state['sql_files'].items()):
            with tab:
                masked = _mask_sql_secrets(content)
                st.code(masked, language="sql")
                st.download_button(f"📥 Download {filename}", masked, file_name=filename, mime="text/plain")
    
    # Instructions - always show with the currently selected airport
    st.divider()
    st.subheader("📋 Next Steps")
    
    if IN_SNOWFLAKE:
        st.markdown(f"""
        1. Click **Execute in Snowflake** to run the SQL directly
        2. **Everything runs automatically:**
           - Flight Schedule window: last 2 days + next 2 days
           - ADS-B historical backfill: configurable (UTC days ending yesterday)
           - Tasks started (daily ADS-B batch, Flight Schedule daily)
           - Derived tables refreshed
        3. Monitor the database: `{database}.PUBLIC`
        """)
    else:
        st.markdown(f"""
        1. Download the SQL files
        2. Run them in Snowflake worksheets in order (01_, 02_, 03_, 04_, 05_, 06_)
        3. **Everything runs automatically** - no manual steps needed!
        4. Deploy the dashboard Streamlit app pointing to `{database}.PUBLIC`
        """)

    # Task monitor for the selected airport (Snowflake only)
    render_task_monitor(database, schema)


if __name__ == "__main__":
    main()

