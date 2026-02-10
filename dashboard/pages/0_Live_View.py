"""
Live View Page - Live Airport State

Shows:
  - Live aircraft positions from ADSB_DATA_LOCAL (last 60 minutes)
  - 2-hour trajectories for those live aircraft (default ON)
  - Live timetable enriched with Aviationstack schedule + planned gate + actual gate
"""

import streamlit as st
import pandas as pd
import pydeck as pdk
from snowflake.snowpark.context import get_active_session
from datetime import datetime
from zoneinfo import ZoneInfo
import sys
import re

sys.path.append("..")
import utils
import colors


st.set_page_config(page_title="Live View", page_icon="🛫", layout="wide")
utils.apply_custom_css()

session = get_active_session()

schema = 'PUBLIC'

with st.sidebar:
    selected_db = utils.render_airport_selector(sidebar=True)

if not selected_db:
    st.warning("No airport databases found yet. Run the installer first.")
    st.stop()

db_prefix = f"{selected_db}.{schema}"

st.title("🛫 Live View")
utils.render_timezone_caption(session, db_prefix)

tzid = utils.get_airport_tzid(session, db_prefix)

# Controls
with st.sidebar:
    st.subheader("Live Controls")
    lookback_min = st.slider("Live window (minutes)", min_value=1, max_value=120, value=60, step=1)
    show_trajectories = st.checkbox("Show trajectories", value=False, help="Display flight trajectory trails")
    if show_trajectories:
        trails_hours = st.select_slider("Trajectory window (hours)", options=[1, 2, 3, 4, 6], value=2)
    else:
        trails_hours = 2  # Default value when not shown
    st.divider()

    infra_selection = utils.render_infrastructure_selector(
        session,
        db_prefix,
        sidebar=True,
        default_preset="airport_ops",
        key_prefix="landing",
    )
    selected_infra_layers = infra_selection["layers"]
    show_infra_tags = infra_selection["show_tags"]


# Load timetable first (it contains latest positions + enrichment)
with st.spinner("Loading live flights..."):
    live_df = utils.get_live_timetable(session, db_prefix, lookback_minutes=lookback_min, max_flights=None)

now_utc = datetime.utcnow()
now_local = datetime.now(ZoneInfo(tzid))
now_local_str = now_local.strftime("%Y-%m-%d %H:%M:%S")

# Airline name fallback: when schedule match is missing, infer airline from callsign prefix via HELPER_AIRLINE_DIM.
# (We do this in-page as a last-mile guardrail in case the installer helper view isn't regenerated yet.)
try:
    if live_df is not None and not live_df.empty and "FLIGHT" in live_df.columns:
        code_to_name = utils.get_airline_name_map(session)

        def _derive_airline_code(flt: str) -> str | None:
            s = str(flt or "").strip().upper()
            if not s:
                return None
            m3 = re.match(r"^([A-Z]{3})", s)
            if m3:
                return m3.group(1)
            m2 = re.match(r"^([A-Z]{2})", s)
            if m2:
                return m2.group(1)
            return None

        live_df = live_df.copy()
        live_df["_AIRLINE_CODE_DERIVED"] = live_df["FLIGHT"].apply(_derive_airline_code)
        if "AIRLINE_NAME" not in live_df.columns:
            live_df["AIRLINE_NAME"] = None
        name_series = live_df["AIRLINE_NAME"]
        missing = name_series.isna() | name_series.astype(str).str.strip().isin(["", "None", "nan", "NaN"])
        live_df.loc[missing, "AIRLINE_NAME"] = live_df.loc[missing, "_AIRLINE_CODE_DERIVED"].map(code_to_name)
        # Clean up display: avoid literal "None" strings
        live_df["AIRLINE_NAME"] = live_df["AIRLINE_NAME"].fillna("")
except Exception:
    pass

# KPIs
live_count = int(len(live_df)) if live_df is not None else 0
with_gate = 0
try:
    with_gate = int(live_df["ACTUAL_GATE"].notna().sum()) if live_count else 0
except Exception:
    with_gate = 0

arrivals = 0
departures = 0
try:
    if live_count:
        dir_series = live_df.get("DIRECTION")
        if dir_series is not None:
            arrivals = int((dir_series.astype(str).str.lower() == "arrival").sum())
            departures = int((dir_series.astype(str).str.lower() == "departure").sum())
except Exception:
    pass

# Data freshness: minutes since latest ADS-B point in the live set (UTC)
freshness_min = None
try:
    if live_df is not None and not live_df.empty and "LAST_SEEN" in live_df.columns:
        last_seen_max = pd.to_datetime(live_df["LAST_SEEN"], errors="coerce").max()
        if pd.notna(last_seen_max):
            freshness_min = int(max(0, (now_utc - last_seen_max.to_pydatetime()).total_seconds() // 60))
except Exception:
    freshness_min = None

c1, c2, c3, c4, c5 = st.columns([1, 1, 1, 1, 2])
c1.metric("Live aircraft", f"{live_count:,}")
c2.metric("Arrivals (matched)", f"{arrivals:,}")
c3.metric("Departures (matched)", f"{departures:,}")
c4.metric("With actual gate", f"{with_gate:,}")
if freshness_min is None:
    c5.metric("Last data", "N/A", delta=f"Now (local): {now_local_str}", delta_color="off")
else:
    c5.metric("Last data", f"{freshness_min} min ago", delta=f"Now (local): {now_local_str}", delta_color="off")


# Map
layers = []

# Infrastructure layers
if selected_infra_layers:
    infra_df = utils.get_infrastructure_layers(
        session, db_prefix, selected_infra_layers, include_tags=show_infra_tags
    )
    layers.extend(utils.create_infrastructure_pydeck_layers(infra_df, show_tags=show_infra_tags))

if live_df is None:
    live_df = pd.DataFrame()

# Normalize column casing (Snowflake -> pandas tends to uppercase)
df = live_df.copy()

def _col(name: str) -> str:
    # Return actual column name if present (upper or lower)
    if name in df.columns:
        return name
    up = name.upper()
    if up in df.columns:
        return up
    low = name.lower()
    if low in df.columns:
        return low
    return name

lat_c = _col("lat")
lon_c = _col("lon")
flight_c = _col("flight")
last_seen_c = _col("last_seen")

points_df = df.copy()
if lat_c in points_df.columns and lon_c in points_df.columns:
    points_df = points_df.dropna(subset=[lat_c, lon_c])
else:
    points_df = pd.DataFrame()

# pydeck JSON serialization is strict: numpy/Decimal scalars can break it
# (e.g., TypeError: vars() argument must have __dict__ attribute).
def _to_float(v):
    try:
        if v is None:
            return None
        # handle pandas/numpy/Decimal scalars
        return float(v)
    except Exception:
        return None

def _sanitize_path(path_obj):
    """Coerce a Snowflake ARRAY_AGG path into plain python [[lon,lat], ...] floats."""
    if path_obj is None:
        return None
    
    # Handle JSON string (Snowflake sometimes returns arrays as JSON strings)
    if isinstance(path_obj, str):
        try:
            import json
            path_obj = json.loads(path_obj)
        except Exception:
            return None
    
    try:
        out = []
        for pt in list(path_obj):
            if pt is None:
                continue
            try:
                lon = _to_float(pt[0])
                lat = _to_float(pt[1])
            except Exception:
                # Some drivers may return dict-like or nested objects; skip if unexpected
                lon = None
                lat = None
            if lon is None or lat is None:
                continue
            out.append([lon, lat])
        return out if out else None
    except Exception:
        return None

def _build_tooltip(r):
    # Keep tooltips compact (pydeck html)
    f = _safe_str(r.get(_col("flight")))
    reg = _safe_str(r.get(_col("registration")))
    aircraft_desc = _safe_str(r.get(_col("aircraft_desc")))
    airline = _safe_str(r.get(_col("airline_name")))
    direction = _safe_str(r.get(_col("direction")))
    nearest_gate = _safe_str(r.get(_col("nearest_gate")))
    planned_gate = _safe_str(r.get(_col("planned_gate")))
    actual_gate = _safe_str(r.get(_col("actual_gate")))
    sched_status = _safe_str(r.get(_col("schedule_status")))
    # Prefer "minutes ago" for last seen (more useful than an absolute timestamp on the map)
    last_seen = r.get(_col("last_seen"))
    last_seen_min_ago = None
    try:
        dt = pd.to_datetime(last_seen, errors="coerce")
        if pd.notna(dt):
            last_seen_min_ago = int(max(0, (now_utc - dt.to_pydatetime()).total_seconds() // 60))
    except Exception:
        last_seen_min_ago = None
    alt = _safe_str(r.get(_col("altitude_baro")))
    spd = _safe_str(r.get(_col("velocity")))
    return (
        f"<b>{f}</b>"
        + (f"<br/>{airline}" if airline else "")
        + (f"<br/><b>Reg:</b> {reg}" if reg else "")
        + (f"<br/><b>Aircraft:</b> {aircraft_desc}" if aircraft_desc else "")
        + (f"<br/><b>Dir:</b> {direction}" if direction else "")
        + (f"<br/><b>Nearest gate (now):</b> {nearest_gate}" if nearest_gate else "")
        + (f"<br/><b>Planned gate:</b> {planned_gate}" if planned_gate else "")
        + (f"<br/><b>Actual gate:</b> {actual_gate}" if actual_gate else "")
        + (f"<br/><b>Status:</b> {sched_status}" if sched_status else "")
        + (f"<br/><b>Last seen:</b> {last_seen_min_ago} min ago" if last_seen_min_ago is not None else "")
        + (f"<br/><b>Alt:</b> {alt}" if alt else "")
        + (f"<br/><b>Spd:</b> {spd}" if spd else "")
    )

def _safe_str(v):
    try:
        return "" if v is None else str(v)
    except Exception:
        return ""

if not points_df.empty:
    # Ensure lat/lon are plain floats for pydeck serialization
    try:
        points_df[lat_c] = points_df[lat_c].apply(_to_float)
        points_df[lon_c] = points_df[lon_c].apply(_to_float)
        points_df = points_df.dropna(subset=[lat_c, lon_c])
    except Exception:
        pass

    # Color by direction when available
    direction_col = _col("direction")
    def _color_row(r):
        d = str(r.get(direction_col, "") or "").lower()
        if d == "arrival":
            return [66, 133, 244, 200]  # blue
        if d == "departure":
            return [219, 68, 55, 200]  # red
        return [120, 120, 120, 180]    # gray

    points_df["color"] = points_df.apply(_color_row, axis=1)
    points_df["tooltip"] = points_df.apply(_build_tooltip, axis=1)

    # Get heading/track for icon rotation
    track_c = _col("track")

    # IMPORTANT: pydeck serializes the entire `data` object; if we pass the full timetable
    # dataframe it may include non-JSON-safe types (timestamps/variant/decimals) and crash.
    # Only pass the small, fully-primitive subset needed for rendering.
    
    # ScatterplotLayer - colored points for aircraft positions
    points_layer_df = pd.DataFrame({
        "flight": points_df[flight_c].astype(str),
        "lat": points_df[lat_c].apply(_to_float),
        "lon": points_df[lon_c].apply(_to_float),
        "color": points_df["color"].apply(lambda c: [int(c[0]), int(c[1]), int(c[2]), int(c[3])] if isinstance(c, (list, tuple)) and len(c) == 4 else [120, 120, 120, 180]),
        "tooltip": points_df["tooltip"].astype(str),
    }).dropna(subset=["lat", "lon"])

    layers.append(
        pdk.Layer(
            "ScatterplotLayer",
            data=points_layer_df,
            id="aircraft-positions",
            get_position="[lon, lat]",
            get_fill_color="color",
            get_radius=60,
            radius_min_pixels=3,
            radius_max_pixels=10,
            pickable=True,
            auto_highlight=True,
            highlight_color=[255, 255, 0, 200],  # Yellow highlight
        )
    )

    # Trajectories for all aircraft with altitude-based color coding (only if enabled)
    if show_trajectories:
        with st.spinner("Loading trajectories..."):
            flight_ids = [str(x) for x in points_df[flight_c].dropna().astype(str).tolist()]
            traj_df = utils.get_live_trajectories(
                session,
                db_prefix,
                flight_ids,
                lookback_hours=int(trails_hours),
                points_per_flight=None,  # Show all points
            )
        
        if traj_df is not None and not traj_df.empty and "PATH" in traj_df.columns:
            # Get altitude data for each trajectory to enable altitude-based coloring
            # We need to query the raw points with altitude info
            altitude_query = f"""
        WITH now_utc AS (
            SELECT TO_TIMESTAMP_NTZ(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())) AS ts
        ),
        flights AS (
            SELECT column1::STRING AS flight
            FROM VALUES {", ".join([f"('{fid}')" for fid in flight_ids[:200]])}
        )
        SELECT
            a.FLIGHT,
            a.TIMESTAMP AS ts,
            ST_X(a.LOCATION) AS lon,
            ST_Y(a.LOCATION) AS lat,
            a.ALTITUDE_BARO AS altitude
        FROM {db_prefix}.ADSB_DATA_LOCAL a
        JOIN flights f ON f.flight = a.FLIGHT
        CROSS JOIN now_utc
        WHERE a.TIMESTAMP >= DATEADD('hour', -{int(trails_hours)}, now_utc.ts)
          AND a.LOCATION IS NOT NULL
          AND a.ALTITUDE_BARO IS NOT NULL
        ORDER BY a.FLIGHT, a.TIMESTAMP
        """
        
        try:
            altitude_df = session.sql(altitude_query).to_pandas()
        except Exception:
            altitude_df = pd.DataFrame()
        
        # Build complete trajectories per flight with altitude-based coloring
        if not altitude_df.empty:
            # Aviation-standard altitude gradient: Teal (low) -> Yellow -> Red (high)
            def to_float_or_none(val):
                try:
                    return float(val) if pd.notna(val) else None
                except Exception:
                    return None
            
            # Get global altitude range for normalization
            altitudes = altitude_df['ALTITUDE'].apply(to_float_or_none)
            alt_series = altitudes.dropna()
            if not alt_series.empty:
                min_alt = alt_series.min()
                max_alt = alt_series.max()
            else:
                min_alt = 0.0
                max_alt = 1.0
            
            def interp_color(t: float):
                """Interpolate between teal (low), yellow (medium), and red (high) based on normalized altitude."""
                t = 0.0 if t is None else max(0.0, min(1.0, t))
                return colors.get_intensity_color_3point(t)
            
            # Build complete paths per flight (not segments) with average altitude for coloring
            trajectories = []
            for flight_id in altitude_df['FLIGHT'].unique():
                flight_pts = altitude_df[altitude_df['FLIGHT'] == flight_id].sort_values('TS')
                
                if len(flight_pts) >= 2:
                    # Build complete path for this flight
                    path = []
                    for _, row in flight_pts.iterrows():
                        lat, lon = row['LAT'], row['LON']
                        if pd.notna(lat) and pd.notna(lon):
                            path.append([lon, lat])
                    
                    if len(path) >= 2:
                        # Calculate average altitude for this flight's trajectory color
                        avg_alt = flight_pts['ALTITUDE'].apply(to_float_or_none).mean()
                        
                        # FILTER: Only require valid flight ID
                        # - Skip if flight ID is missing, null, empty, or looks like a hex code without callsign
                        # - Show ALL altitudes (including 0 ft for taxiing)
                        # - Show all path lengths (including long taxiing paths)
                        flight_id_str = str(flight_id).strip().upper() if flight_id else ''
                        
                        # Exclude: empty IDs, "NONE", "NAN", pure hex codes (6 digits only)
                        is_valid_flight_id = (
                            flight_id_str and 
                            flight_id_str not in ['', 'NONE', 'NAN', 'NULL'] and
                            not (len(flight_id_str) == 6 and flight_id_str.isalnum() and not any(c.isalpha() and c > 'F' for c in flight_id_str))  # Not a pure hex code
                        )
                        
                        if pd.notna(avg_alt) and avg_alt is not None and is_valid_flight_id:
                            # Normalize altitude to 0-1 range
                            if max_alt > min_alt:
                                t = (avg_alt - min_alt) / (max_alt - min_alt)
                            else:
                                t = 0.0
                            
                            trajectories.append({
                                'path': path,
                                'color': interp_color(t),
                                'flight': flight_id_str,
                                'avg_altitude': int(avg_alt),
                                'min_altitude': int(flight_pts['ALTITUDE'].apply(to_float_or_none).min()),
                                'max_altitude': int(flight_pts['ALTITUDE'].apply(to_float_or_none).max()),
                                'points': len(path)
                            })
            
            if trajectories:
                st.sidebar.success(f"✅ Rendering {len(trajectories)} complete altitude-colored trajectories")
                traj_layer_df = pd.DataFrame(trajectories)
                
                # Enrich trajectories with airline and O/D from live timetable
                if live_df is not None and not live_df.empty:
                    # Create enrichment lookup from live timetable
                    enrich_cols = ['FLIGHT', 'AIRLINE_NAME', 'DEPARTURE_AIRPORT', 'ARRIVAL_AIRPORT', 'DIRECTION']
                    available_cols = [c for c in enrich_cols if c in live_df.columns]
                    
                    if 'FLIGHT' in available_cols:
                        enrich_df = live_df[available_cols].copy()
                        # Normalize flight ID for matching
                        enrich_df['FLIGHT'] = enrich_df['FLIGHT'].astype(str).str.strip().str.upper()
                        traj_layer_df['flight_upper'] = traj_layer_df['flight'].astype(str).str.strip().str.upper()
                        
                        # Merge enrichment data
                        traj_layer_df = traj_layer_df.merge(
                            enrich_df.drop_duplicates(subset=['FLIGHT']),
                            left_on='flight_upper',
                            right_on='FLIGHT',
                            how='left',
                            suffixes=('', '_enrich')
                        )
                
                # Build enhanced tooltips with airline and O/D
                def build_traj_tooltip(r):
                    tooltip = f"<b>{r['flight']}</b>"
                    
                    # Add airline if available
                    airline = r.get('AIRLINE_NAME', None)
                    if airline and pd.notna(airline) and str(airline).strip() not in ['', 'None', 'nan']:
                        tooltip += f"<br/><b>Airline:</b> {airline}"
                    
                    # Add origin-destination if available
                    dep = r.get('DEPARTURE_AIRPORT', None)
                    arr = r.get('ARRIVAL_AIRPORT', None)
                    direction = r.get('DIRECTION', None)
                    
                    if dep and arr and pd.notna(dep) and pd.notna(arr):
                        dep_str = str(dep).strip()
                        arr_str = str(arr).strip()
                        if dep_str not in ['', 'None', 'nan'] and arr_str not in ['', 'None', 'nan']:
                            tooltip += f"<br/><b>Route:</b> {dep_str} → {arr_str}"
                    
                    # Add direction if available
                    if direction and pd.notna(direction) and str(direction).strip() not in ['', 'None', 'nan']:
                        tooltip += f"<br/><b>Direction:</b> {str(direction).capitalize()}"
                    
                    # Add altitude info
                    tooltip += f"<br/><b>Avg Alt:</b> {r['avg_altitude']:,} ft"
                    tooltip += f"<br/><b>Alt Range:</b> {r['min_altitude']:,} - {r['max_altitude']:,} ft"
                    tooltip += f"<br/><b>Points:</b> {r['points']}"
                    
                    return tooltip
                
                traj_layer_df['tooltip'] = traj_layer_df.apply(build_traj_tooltip, axis=1)
                
                layers.append(
                    pdk.Layer(
                        "PathLayer",
                        data=traj_layer_df,
                        id="flight-trajectories",
                        get_path="path",
                        get_color="color",
                        width_scale=3,
                        width_min_pixels=2,
                        pickable=True,
                        auto_highlight=True,
                        highlight_color=[255, 255, 0, 255],  # Yellow highlight
                        width_max_pixels=8,  # Widen on hover
                    )
                )
            else:
                st.sidebar.warning("⚠ No valid trajectories to render")
        else:
            st.sidebar.warning("⚠ No altitude data available for coloring")

# View state (airport default)
view = utils.get_airport_default_view(session)
view_state = pdk.ViewState(
    latitude=float(view["latitude"]),
    longitude=float(view["longitude"]),
    zoom=float(view["zoom"]),
    pitch=0,
    bearing=0,
)

deck_tooltip = {"html": "{tooltip}", "style": {"backgroundColor": "steelblue", "color": "white"}}

# Enable picking radius for better hover detection
r = pdk.Deck(
    layers=layers, 
    initial_view_state=view_state, 
    map_style="light", 
    tooltip=deck_tooltip,
    parameters={
        "picking_radius": 10,  # Larger hover detection area
    }
)
st.pydeck_chart(r, use_container_width=True, height=650, key="live_view")


# Timetable
st.divider()
st.subheader("🗓️ Live Timetable (Flights seen in last window)")

if live_df is None or live_df.empty:
    st.info("No flights found in the selected live window.")
else:
    display_cols = [
        "FLIGHT",
        "REGISTRATION",
        "AIRCRAFT_DESC",
        "AIRLINE_NAME",
        "DIRECTION",
        "DEPARTURE_AIRPORT",
        "ARRIVAL_AIRPORT",
        "DEPARTURE_SCHEDULED",
        "DEPARTURE_ESTIMATED",
        "DEPARTURE_ACTUAL",
        "ARRIVAL_SCHEDULED",
        "ARRIVAL_ESTIMATED",
        "ARRIVAL_ACTUAL",
        "NEAREST_GATE",
        "PLANNED_GATE",
        "ACTUAL_GATE",
        "SCHEDULE_STATUS",
        "LAST_SEEN",
    ]
    cols_present = [c for c in display_cols if c in live_df.columns]

    # Display formatting (keep raw DF intact for map logic)
    display_df = live_df[cols_present].copy()

    # Replace None/NaN/literal "None" strings with empty strings for cleaner display
    for col in display_df.columns:
        try:
            # Replace NaN with empty string
            display_df[col] = display_df[col].fillna("")
            # Replace literal "None" strings with empty string
            display_df[col] = display_df[col].astype(str).replace(["None", "nan", "NaN", "NaT"], "")
        except Exception:
            pass

    def _fmt_time_col(df_in: pd.DataFrame, col: str) -> None:
        """Format timestamp column as HH:MM (airport local) without date."""
        try:
            local_dt = utils.to_airport_local_time(df_in[col], tzid)
            df_in[col] = local_dt.dt.strftime("%H:%M").fillna("")
        except Exception:
            # If parsing fails, leave as-is
            pass

    # Format schedule timestamps to time-only
    for c in [
        "DEPARTURE_SCHEDULED",
        "DEPARTURE_ESTIMATED",
        "DEPARTURE_ACTUAL",
        "ARRIVAL_SCHEDULED",
        "ARRIVAL_ESTIMATED",
        "ARRIVAL_ACTUAL",
    ]:
        if c in display_df.columns:
            _fmt_time_col(display_df, c)

    # Last seen: show minutes ago (and sort by the true timestamp)
    # Be case-insensitive to Snowflake/pandas column casing.
    last_seen_col = None
    for c in display_df.columns:
        if str(c).strip().upper() == "LAST_SEEN":
            last_seen_col = c
            break
    if last_seen_col is not None:
        try:
            last_seen_dt = pd.to_datetime(live_df[last_seen_col], errors="coerce")
            # Vectorized delta in minutes; robust vs timezone-naive timestamps
            mins = ((pd.Timestamp(now_utc) - last_seen_dt).dt.total_seconds() // 60).astype("float")
            display_df[last_seen_col] = mins.apply(lambda m: "" if pd.isna(m) else f"{int(max(0, m))} min ago")
            display_df["_sort_last_seen"] = last_seen_dt
        except Exception:
            display_df["_sort_last_seen"] = pd.NaT
            # Worst-case: still replace with blank to avoid timestamp display
            try:
                display_df[last_seen_col] = ""
            except Exception:
                pass
    else:
        display_df["_sort_last_seen"] = pd.NaT

    st.dataframe(
        display_df.sort_values(by="_sort_last_seen", ascending=False).drop(columns=["_sort_last_seen"]),
        use_container_width=True,
        hide_index=True,
    )

