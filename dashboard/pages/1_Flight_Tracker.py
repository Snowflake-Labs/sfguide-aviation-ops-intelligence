"""
Flight Tracker - Main Page
Track individual flights with infrastructure context
"""

import streamlit as st
import pandas as pd
import pydeck as pdk
from snowflake.snowpark.context import get_active_session
from datetime import datetime, timedelta
import json
import plotly.graph_objects as go
import utils
from config.colors import get_intensity_color_3point
import re
import ui_components

# Page configuration
st.set_page_config(
    page_title="Flight Tracker",
    page_icon="✈️",
    layout="wide"
)

utils.apply_custom_css()

# Get session
session = get_active_session()

# Sidebar: airport selector should run BEFORE any queries that depend on db/schema
with st.sidebar:
    selected_db = ui_components.render_airport_selector(sidebar=True)

# Resolve selected DB after selector renders
if not selected_db:
    st.error("No airport selected / no airport databases found. Check permissions and installer output.")
    st.stop()

db = utils.get_selected_database()
schema = 'PUBLIC'
db_prefix = f"{db}.{schema}"

# Render something early so reruns don't look like a "blank page" while queries run
st.title("✈️ Flight Tracker")
utils.render_timezone_caption(session, db_prefix)

tzid = utils.get_airport_tzid(session, db_prefix)

try:
    local_today = datetime.fromisoformat(utils.get_airport_local_today(session, db_prefix)).date()
except Exception:
    local_today = datetime.now().date()

def _format_local_time(value, fmt: str = "%H:%M:%S") -> str:
    try:
        local_dt = utils.to_airport_local_time(pd.Series([value]), tzid).iloc[0]
        return local_dt.strftime(fmt) if pd.notna(local_dt) else "N/A"
    except Exception:
        return "N/A"

# Get date range (depends on selected db)
min_date, max_date = utils.get_date_range(session)
if max_date is None:
    st.info(
        "No ADS-B data available yet for the selected database/schema. "
        "This is expected right after reinstall—wait for `TASK_INGEST_ADSB` to run, "
        "or verify `ADSB_DATA` is being populated and `ADSB_DATA_LOCAL` has refreshed."
    )

# Sidebar controls
with st.sidebar:
    # Date picker (single date for flight selection)
    st.subheader("Date")
    selected_date = st.date_input(
        "Select Date",
        value=max_date if max_date else local_today,
        min_value=min_date if min_date else local_today - timedelta(days=365),
        max_value=max_date if max_date else local_today
    )
    
    # Vehicle type filter - MOVED BEFORE flight list to enable filtering
    st.divider()
    vehicle_filter = ui_components.render_vehicle_type_filter(
        key_prefix="flight_tracker",
        sidebar=True,
        default_all=True  # Default to all types
    )
    
    # Load available flights
    @st.cache_data(ttl=300)
    def get_flight_list(_session, date, _db_prefix, vehicle_sql_filter="1=1", limit: int = 500):
        """Return a bounded list of flights for the given date with header fields.
        Reads from FLIGHT_TRACKER_FLIGHT_LIST (dynamic table)."""
        try:
            query = f"""
              SELECT
              flight_id AS flight,
              airline_name,
              origin_airport,
              destination_airport,
              schedule_flight_number,
              points,
              VEHICLE_CATEGORY
            FROM {_db_prefix}.FLIGHT_TRACKER_FLIGHT_LIST
            WHERE service_date = '{date}'::DATE
              AND {vehicle_sql_filter}
            QUALIFY ROW_NUMBER() OVER (ORDER BY points DESC, flight_id ASC) <= {int(limit)}
            """
            return _session.sql(query).to_pandas()
        except Exception:
            try:
                import pandas as _pd
                return _pd.DataFrame(columns=['FLIGHT', 'AIRLINE_NAME', 'ORIGIN_AIRPORT', 'DESTINATION_AIRPORT', 'SCHEDULE_FLIGHT_NUMBER', 'POINTS', 'VEHICLE_CATEGORY'])
            except Exception:
                import pandas as _pd
                return _pd.DataFrame(columns=['FLIGHT', 'AIRLINE_NAME', 'ORIGIN_AIRPORT', 'DESTINATION_AIRPORT', 'SCHEDULE_FLIGHT_NUMBER', 'POINTS', 'VEHICLE_CATEGORY'])
    
    with st.spinner("Loading available flights..."):
        flights_df = get_flight_list(session, selected_date, db_prefix, vehicle_filter['sql_filter'], limit=500)
    
    # Enrich labels from FLIGHT_SCHEDULE when missing (UTC/local date boundary tolerant)
    try:
        headers_df = utils.get_flight_headers_from_schedule(
            session,
            selected_date,
            flights_df['FLIGHT'].tolist() if flights_df is not None and not flights_df.empty else [],
            db_prefix=db_prefix
        )
    except Exception:
        headers_df = pd.DataFrame()

    if flights_df is not None and not flights_df.empty and headers_df is not None and not headers_df.empty:
        # Normalize casing for merge
        h = headers_df.copy()
        # headers_df may come back with either Snowflake-style (uppercase) or python-style (lowercase) columns.
        rename_map = {}
        if 'FLIGHT_ID' in h.columns:
            rename_map['FLIGHT_ID'] = 'FLIGHT'
        if 'flight_id' in h.columns:
            rename_map['flight_id'] = 'FLIGHT'
        if 'AIRLINE_NAME' in h.columns:
            rename_map['AIRLINE_NAME'] = 'AIRLINE_NAME'
        if 'airline_name' in h.columns:
            rename_map['airline_name'] = 'AIRLINE_NAME'
        if 'ORIGIN_AIRPORT' in h.columns:
            rename_map['ORIGIN_AIRPORT'] = 'ORIGIN_AIRPORT'
        if 'origin_airport' in h.columns:
            rename_map['origin_airport'] = 'ORIGIN_AIRPORT'
        if 'DESTINATION_AIRPORT' in h.columns:
            rename_map['DESTINATION_AIRPORT'] = 'DESTINATION_AIRPORT'
        if 'destination_airport' in h.columns:
            rename_map['destination_airport'] = 'DESTINATION_AIRPORT'
        if 'SCHEDULE_FLIGHT_NUMBER' in h.columns:
            rename_map['SCHEDULE_FLIGHT_NUMBER'] = 'SCHEDULE_FLIGHT_NUMBER'
        if 'schedule_flight_number' in h.columns:
            rename_map['schedule_flight_number'] = 'SCHEDULE_FLIGHT_NUMBER'
        if rename_map:
            h = h.rename(columns=rename_map)
        flights_df = flights_df.merge(h[['FLIGHT','AIRLINE_NAME','ORIGIN_AIRPORT','DESTINATION_AIRPORT','SCHEDULE_FLIGHT_NUMBER']], on='FLIGHT', how='left', suffixes=('', '_SCHED'))
        # Fill from schedule when base is empty
        for c in ['AIRLINE_NAME','ORIGIN_AIRPORT','DESTINATION_AIRPORT','SCHEDULE_FLIGHT_NUMBER']:
            sched_c = c + '_SCHED'
            if sched_c in flights_df.columns:
                flights_df[c] = flights_df[c].where(flights_df[c].notna() & (flights_df[c].astype(str).str.strip() != ''), flights_df[sched_c])
        flights_df = flights_df.drop(columns=[c for c in flights_df.columns if c.endswith('_SCHED')])
    
    # Flight dropdown (show airline + OD in label, but keep value as flight id)
    if flights_df is not None and not flights_df.empty:
        flight_options = [""] + flights_df['FLIGHT'].tolist()
        labels = {}

        # Snowpark -> pandas column casing can vary between environments; normalize access.
        col_airline = "AIRLINE_NAME" if "AIRLINE_NAME" in flights_df.columns else "airline_name"
        col_o = "ORIGIN_AIRPORT" if "ORIGIN_AIRPORT" in flights_df.columns else "origin_airport"
        col_d = "DESTINATION_AIRPORT" if "DESTINATION_AIRPORT" in flights_df.columns else "destination_airport"
        col_sched = "SCHEDULE_FLIGHT_NUMBER" if "SCHEDULE_FLIGHT_NUMBER" in flights_df.columns else "schedule_flight_number"

        def _clean_txt(x):
            s = ("" if x is None else str(x)).strip()
            return "" if s.lower() == "nan" else s

        # Airline fallback map (includes HELPER_AIRLINE_DIM fallback inside utils)
        try:
            code_to_name = utils.get_airline_name_map(session, selected_date, selected_date)
        except Exception:
            code_to_name = {}

        for _, r in flights_df.iterrows():
            fid = _clean_txt(r.get("FLIGHT"))
            airline = _clean_txt(r.get(col_airline))
            o = _clean_txt(r.get(col_o))
            d = _clean_txt(r.get(col_d))

            od = f"{o}→{d}" if o and d else ""

            # If airline missing, derive from callsign prefix using standing airline dim.
            if not airline and fid:
                try:
                    prefix = re.sub(r"[^A-Z]", "", fid.upper())[:3]
                    # prefer 3-letter ICAO, else 2-letter IATA
                    airline = code_to_name.get(prefix) or code_to_name.get(prefix[:2]) or ""
                except Exception:
                    airline = ""

            # Label format requirement: Callsign | Airline | O→D (no schedule flight number digits).
            parts = [p for p in [fid, airline, od] if p]
            labels[fid] = " | ".join(parts)
        selected_flight = st.selectbox(
            "Choose Flight to track",
            options=flight_options,
            format_func=lambda x: labels.get(str(x), str(x)) if x != "" else ""
        )
    else:
        st.warning(f"No flights found for {selected_date}")
        selected_flight = ""
    
    st.divider()
    
    # Infrastructure Layers - use new dynamic selector
    infra_selection = ui_components.render_map_layers_selector(
        session, db_prefix, 
        sidebar=True, 
        default_preset="all",
        key_prefix="flight_tracker"
    )
    selected_infra_layers = infra_selection['layers']
    show_infra_tags = infra_selection['show_tags']

# Query functions
@st.cache_data(ttl=300)
def get_flight_data(_session, flight, date, _db_prefix, vehicle_sql_filter="1=1"):
    """Get flight tracking data (airport-local day)"""
    f = str(flight or "").strip().upper()
    is_hex = bool(re.fullmatch(r"[0-9A-F]{6}", f))
    where = f"ICAO_HEX = '{f}'" if is_hex else f"FLIGHT = '{flight}'"
    local_date_expr = utils.get_airport_local_date_sql(_db_prefix, "TIMESTAMP")
    query = f"""
    SELECT 
        ICAO_HEX,
        REGISTRATION,
        FLIGHT,
        TIMESTAMP,
        ST_Y(LOCATION) AS LAT,
        ST_X(LOCATION) AS LON,
        ALTITUDE_BARO,
        TRACK,
        VELOCITY,
        SOURCE
    FROM {_db_prefix}.ADSB_DATA_LOCAL
    WHERE {where}
        AND {local_date_expr} = '{date}'::DATE
        AND {vehicle_sql_filter}
        AND LOCATION IS NOT NULL
    ORDER BY TIMESTAMP ASC
    """
    return _session.sql(query).to_pandas()

@st.cache_data(ttl=300)
def get_flight_gate_dwell(_session, flight, date, _db_prefix, radius_meters: int = 120, vehicle_sql_filter="1=1"):
    """Approximate dwell time near the most-likely gate for the selected flight/date (airport-local day).
    Returns a single-row DataFrame with GATE_NAME, DWELL_MINUTES, START_TS, END_TS, POINTS or empty if none."""
    local_date_expr = utils.get_airport_local_date_sql(_db_prefix, "TIMESTAMP")
    query = f"""
    WITH ads AS (
        SELECT TIMESTAMP, ST_X(LOCATION) AS LON, ST_Y(LOCATION) AS LAT
    FROM {_db_prefix}.ADSB_DATA_LOCAL
        WHERE FLIGHT = '{flight}'
          AND {local_date_expr} = '{date}'::DATE
          AND {vehicle_sql_filter}
          AND LOCATION IS NOT NULL
    ),
    gates AS (
        SELECT gate_name AS CLEAN_NAME, gate_geom AS geog
        FROM {_db_prefix}.PROPERTIES_GATES
        WHERE gate_geom IS NOT NULL
    ),
    near AS (
        SELECT 
            a.TIMESTAMP,
            g.CLEAN_NAME
        FROM ads a
        JOIN gates g
          ON ST_DWITHIN(TO_GEOGRAPHY(ST_POINT(a.LON, a.LAT)), g.geog, {int(radius_meters)})
    ),
    top_gate AS (
        SELECT CLEAN_NAME, COUNT(*) AS cnt
        FROM near
        GROUP BY CLEAN_NAME
        ORDER BY cnt DESC
        LIMIT 1
    ),
    near_top AS (
        SELECT n.TIMESTAMP, t.CLEAN_NAME
        FROM near n
        JOIN top_gate t ON t.CLEAN_NAME = n.CLEAN_NAME
    ),
    agg AS (
        SELECT MIN(TIMESTAMP) AS start_ts, MAX(TIMESTAMP) AS end_ts, COUNT(*) AS points
        FROM near_top
    )
    SELECT 
        t.CLEAN_NAME AS gate_name,
        COALESCE(TIMESTAMPDIFF('minute', a.start_ts, a.end_ts), 0) AS dwell_minutes,
        a.start_ts,
        a.end_ts,
        a.points
    FROM top_gate t
    CROSS JOIN agg a
    """
    try:
        return _session.sql(query).to_pandas()
    except Exception:
        return pd.DataFrame()

@st.cache_data(ttl=300)
def get_gate_time_from_view(_session, flight, date, _db_prefix):
    """Fetch Gate and Gate Dwell (min) for a flight/date using GATE_ANALYSIS_FLIGHT_GATE_TIME.
    Joins via GATE_ANALYSIS_ADSB_GROUND_POINTS to get the correct ground_session_id keys.
    Returns a single-row DataFrame with columns GATE_NAME and DWELL_MINUTES (or empty)."""
    f = str(flight or "").strip().upper()
    is_hex = bool(re.fullmatch(r"[0-9A-F]{6}", f))
    where = f"ICAO_HEX = '{f}'" if is_hex else f"FLIGHT = '{flight}'"
    query = f"""
    WITH sessions AS (
      SELECT DISTINCT ground_session_id
      FROM {_db_prefix}.GATE_ANALYSIS_ADSB_GROUND_POINTS
      WHERE {where}
        AND service_date = '{date}'::DATE
        AND ground_session_id IS NOT NULL
    )
    SELECT 
      fgt.GATE_NAME AS GATE_NAME,
      ROUND(fgt.DWELL_SECONDS / 60.0) AS DWELL_MINUTES
      FROM {_db_prefix}.GATE_ANALYSIS_FLIGHT_GATE_TIME fgt
    JOIN sessions s
      ON s.ground_session_id = fgt.ground_session_id
    ORDER BY fgt.DWELL_SECONDS DESC NULLS LAST
    LIMIT 1
    """
    try:
        return _session.sql(query).to_pandas()
    except Exception:
        return pd.DataFrame()

@st.cache_data(ttl=300)
def get_schedule_info(_session, flight_number, date, _db_prefix):
    """Get schedule information"""
    f_raw = str(flight_number or "").strip().upper()
    if not f_raw:
        return None

    # Extract callsign prefix + numeric part (used for safe fallback matching)
    flight_num = ''.join(filter(str.isdigit, f_raw))
    prefix = ''.join([c for c in f_raw if c.isalpha()])[:3]
    prefix2 = prefix[:2]
    prefix3 = prefix[:3]

    # If we don't have digits, we can't schedule-match safely
    if not flight_num:
        return None
    
    query = f"""
    WITH airport AS (
        SELECT UPPER(airport_code) AS airport_code, UPPER(airport_icao) AS airport_icao
        FROM {_db_prefix}.PROPERTIES_AIRPORT
        LIMIT 1
    ),
    candidates AS (
    SELECT
        s.*,
        IFF(UPPER(TRIM(s.FLIGHT_ICAO)) = '{f_raw}', 0,
            IFF(UPPER(TRIM(s.FLIGHT_IATA)) = '{f_raw}', 1, 2)
        ) AS match_rank,
        ABS(DATEDIFF('day', s.FLIGHT_DATE, '{date}'::DATE)) AS date_diff
    FROM {_db_prefix}.FLIGHT_SCHEDULE s
    CROSS JOIN airport a
      WHERE s.FLIGHT_DATE BETWEEN DATEADD('day', -1, '{date}'::DATE) AND DATEADD('day', 1, '{date}'::DATE)
        AND (
          -- Best: exact callsign match against flight identifiers
          UPPER(TRIM(s.FLIGHT_ICAO)) = '{f_raw}'
          OR UPPER(TRIM(s.FLIGHT_IATA)) = '{f_raw}'
          -- Safe fallback: numeric match ONLY when airline code prefix matches (avoids collisions like 3310 across carriers)
          OR (
            s.FLIGHT_NUMBER = '{flight_num}'
            AND (
              (LENGTH('{prefix3}') = 3 AND UPPER(TRIM(s.AIRLINE_ICAO)) = '{prefix3}')
              OR (LENGTH('{prefix2}') = 2 AND UPPER(TRIM(s.AIRLINE_IATA)) = '{prefix2}')
            )
          )
        )
    )
    SELECT
        c.FLIGHT_DATE AS TRAVEL_DATE,
        c.FLIGHT_NUMBER,
        c.AIRLINE_NAME AS MARKETING_CARRIER,
        IFF(
          UPPER(c.DEPARTURE_AIRPORT) IN (a.airport_code, a.airport_icao),
          'departure',
          IFF(UPPER(c.ARRIVAL_AIRPORT) IN (a.airport_code, a.airport_icao), 'arrival', 'unknown')
        ) AS DIRECTION,
        c.DEPARTURE_TERMINAL AS TERMINAL,
        c.DEPARTURE_GATE AS GATE,
        c.DEPARTURE_AIRPORT AS ORIGIN_AIRPORT,
        c.ARRIVAL_AIRPORT AS DESTINATION_AIRPORT,
        IFF(
          UPPER(c.DEPARTURE_AIRPORT) IN (a.airport_code, a.airport_icao),
          c.DEPARTURE_SCHEDULED,
          c.ARRIVAL_SCHEDULED
        ) AS SCHEDULED_TIME,
        c.FLIGHT_STATUS AS STATUS
    FROM candidates c
    CROSS JOIN airport a
    QUALIFY ROW_NUMBER() OVER (ORDER BY c.match_rank ASC, c.date_diff ASC, c.UPDATED_AT DESC) = 1
    """
    try:
        result = _session.sql(query).to_pandas()
        return result if not result.empty else None
    except Exception:
        return None

# Load infrastructure layers based on selection
infra_df = utils.get_infrastructure_layers(session, db_prefix, selected_infra_layers, include_tags=show_infra_tags) if selected_infra_layers else pd.DataFrame()

# Load flight data if selected
flight_data = pd.DataFrame()
schedule_info = None
if selected_flight:
    with st.spinner("Loading flight data..."):
        flight_data = get_flight_data(session, selected_flight, selected_date, db_prefix, vehicle_sql_filter=vehicle_filter['sql_filter'])
        if not flight_data.empty:
            schedule_info = get_schedule_info(session, selected_flight, selected_date, db_prefix)

# Map visualization
layers = []

# Infrastructure layers (componentized rendering)
layers.extend(utils.create_infrastructure_pydeck_layers(infra_df, show_tags=show_infra_tags))

# Flight path layer (always shown when a flight is selected)
if not flight_data.empty:
    # Altitude-colored segments from low (#97E7EF) to high (#D966FF)
    def to_float_or_none(val):
        try:
            s = str(val)
            if s is None or s.strip() == '':
                return None
            # allow numeric strings with decimal or minus
            return float(val)
        except Exception:
            return None

    altitudes = flight_data['ALTITUDE_BARO'].apply(to_float_or_none)
    alt_series = altitudes.dropna()
    if not alt_series.empty:
        min_alt = alt_series.min()
        max_alt = alt_series.max()
    else:
        min_alt = 0.0
        max_alt = 1.0

    def interp_color(t: float):
        t = 0.0 if t is None else max(0.0, min(1.0, t))
        color = get_intensity_color_3point(t)
        color[3] = 255
        return color

    segments = []
    for i in range(len(flight_data) - 1):
        lat1, lon1 = flight_data.iloc[i]['LAT'], flight_data.iloc[i]['LON']
        lat2, lon2 = flight_data.iloc[i + 1]['LAT'], flight_data.iloc[i + 1]['LON']
        alt = altitudes.iloc[i]
        if pd.notna(lat1) and pd.notna(lon1) and pd.notna(lat2) and pd.notna(lon2) and alt is not None:
            if max_alt > min_alt:
                t = (alt - min_alt) / (max_alt - min_alt)
            else:
                t = 0.0
            segments.append({
                'path': [[lon1, lat1], [lon2, lat2]],
                'color': interp_color(t)
            })

    if segments:
        segments_df = pd.DataFrame(segments)
        path_layer = pdk.Layer(
            'PathLayer',
            data=segments_df,
            get_path='path',
            get_color='color',
            width_scale=3,
            width_min_pixels=2,
            pickable=False
        )
        layers.append(path_layer)
    
    # Start and end markers with flight info
    start_point = flight_data.iloc[0]
    end_point = flight_data.iloc[-1]
    
    # Prepare marker data with schedule info
    marker_data = []
    
    # Get flight info for tooltips
    flight_number = selected_flight
    origin = schedule_info.iloc[0]['ORIGIN_AIRPORT'] if schedule_info is not None and not schedule_info.empty else 'N/A'
    destination = schedule_info.iloc[0]['DESTINATION_AIRPORT'] if schedule_info is not None and not schedule_info.empty else 'N/A'
    
    capacity = 'N/A'
    
    marker_data.append({
        'LAT': start_point['LAT'],
        'LON': start_point['LON'],
        'color': [0, 255, 0, 255],
        'FLIGHT_NUMBER': flight_number,
        'ORIGIN': origin,
        'DESTINATION': destination,
        'MARKER_TYPE': 'Start'
    })
    
    marker_data.append({
        'LAT': end_point['LAT'],
        'LON': end_point['LON'],
        'color': [255, 0, 0, 255],
        'FLIGHT_NUMBER': flight_number,
        'ORIGIN': origin,
        'DESTINATION': destination,
        'MARKER_TYPE': 'End'
    })
    
    markers = pd.DataFrame(marker_data)
    # Per-layer tooltip for markers: Flight details only
    markers['TOOLTIP'] = markers.apply(
        lambda r: f"<b>Flight Number:</b> {r['FLIGHT_NUMBER']}<br/><b>Origin:</b> {r['ORIGIN']}<br/><b>Destination:</b> {r['DESTINATION']}",
        axis=1
    )
    
    marker_layer = pdk.Layer(
        'ScatterplotLayer',
        data=markers,
        get_position='[LON, LAT]',
        get_color='color',
        get_radius=30,
        radius_min_pixels=2,
        radius_max_pixels=4,
        pickable=True
    )
    layers.append(marker_layer)

# Calculate map bounds: always use the airport polygon bounds
map_bounds = utils.get_airport_default_view(session)

# Render map
view_state = pdk.ViewState(
    latitude=map_bounds['latitude'],
    longitude=map_bounds['longitude'],
    zoom=map_bounds['zoom'],
    pitch=0,
    bearing=0
)

# Unified tooltip placeholder - each layer populates its own TOOLTIP field
tooltip_html = {
    "html": "{TOOLTIP}",
    "style": {"backgroundColor": "steelblue", "color": "white"}
}

r = pdk.Deck(
    layers=layers,
    initial_view_state=view_state,
    map_style='light',
    tooltip=tooltip_html
)

try:
    st.pydeck_chart(r, use_container_width=True, height=600, key="flight_tracker")
except Exception as e:
    st.error("Map rendering failed (pydeck). This usually happens due to overly large/invalid geometries.")
    st.exception(e)

# Only show flight details if flight is selected and data exists
if selected_flight and not flight_data.empty:
    st.divider()
    
    # Flight Profile over time
    st.subheader("📈 Flight Profile over Time")
    
    # Prepare data
    profile_data = flight_data.copy()
    profile_data['ALTITUDE'] = profile_data['ALTITUDE_BARO'].apply(
        lambda x: float(x) if pd.notna(x) and str(x).replace('.','').replace('-','').isdigit() else None
    )
    profile_data['SPEED'] = profile_data['VELOCITY'].apply(
        lambda x: float(x) if pd.notna(x) and str(x).replace('.','').replace('-','').isdigit() else None
    )
    profile_data = profile_data.dropna(subset=['ALTITUDE', 'SPEED'])
    profile_data['LOCAL_TIMESTAMP'] = utils.to_airport_local_time(profile_data['TIMESTAMP'], tzid)
    
    if not profile_data.empty:
        # Create dual-axis chart
        fig = go.Figure()
        
        # Altitude trace
        fig.add_trace(go.Scatter(
            x=profile_data['LOCAL_TIMESTAMP'],
            y=profile_data['ALTITUDE'],
            name='Altitude',
            line=dict(color='blue', width=2),
            yaxis='y'
        ))
        
        # Speed trace
        fig.add_trace(go.Scatter(
            x=profile_data['LOCAL_TIMESTAMP'],
            y=profile_data['SPEED'],
            name='Speed',
            line=dict(color='red', width=2),
            yaxis='y2'
        ))
        
        # Update layout
        fig.update_layout(
            xaxis=dict(title='Time'),
            yaxis=dict(title='Altitude (ft)', side='left'),
            yaxis2=dict(title='Speed (knots)', overlaying='y', side='right'),
            hovermode='x unified',
            height=400
        )
        
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No altitude/speed data available for this flight")
    
    st.divider()
    
    # Flight details
    st.subheader("✈️ Flight Details")
    
    flight_info = flight_data.iloc[0]
    
    # Gate and dwell from curated view
    gate_dwell_info = get_gate_time_from_view(session, selected_flight, selected_date, db_prefix)

    # Airline fallback (callsign prefix -> airline name), used when schedule is missing or ambiguous.
    try:
        code_to_name_details = utils.get_airline_name_map(session, selected_date, selected_date)
    except Exception:
        code_to_name_details = {}
    try:
        fid = str(selected_flight or "").strip().upper()
        prefix = ''.join([c for c in fid if c.isalpha()])[:3]
        fallback_carrier = code_to_name_details.get(prefix) or code_to_name_details.get(prefix[:2]) or 'N/A'
    except Exception:
        fallback_carrier = 'N/A'

    if schedule_info is not None and not schedule_info.empty:
        sched = schedule_info.iloc[0]
        direction = str(sched.get('DIRECTION', 'unknown') or 'unknown').capitalize()
        
        col1, col2, col3, col4 = st.columns(4)
        
        with col1:
            st.metric("Flight Number", selected_flight)
        
        with col2:
            st.metric("Aircraft", flight_info['REGISTRATION'] if pd.notna(flight_info['REGISTRATION']) else 'N/A')
        
        with col3:
            st.metric("Direction", direction)
        
        with col4:
            if direction.lower() == 'arrival':
                st.metric("Origin", sched.get('ORIGIN_AIRPORT', 'N/A'))
            else:
                st.metric("Destination", sched.get('DESTINATION_AIRPORT', 'N/A'))
        
        col1, col2, col3, col4 = st.columns(4)
        
        with col1:
            st.metric("Carrier", sched.get('MARKETING_CARRIER', fallback_carrier))
        
        with col2:
            st.metric("Terminal", sched.get('TERMINAL', 'N/A') if pd.notna(sched.get('TERMINAL', None)) else 'N/A')
        
        with col3:
            st.metric("Scheduled Time", _format_local_time(sched.get('SCHEDULED_TIME', None), "%H:%M"))
        
        with col4:
            st.metric("Status", sched.get('STATUS', 'N/A'))

        # Gate + Time Near Gate + First/Last Seen in one row
        col1, col2, col3, col4 = st.columns(4)
        if gate_dwell_info is not None and not gate_dwell_info.empty:
            gate_name = gate_dwell_info.iloc[0].get('GATE_NAME', 'N/A')
            dwell_min = gate_dwell_info.iloc[0].get('DWELL_MINUTES', None)
            try:
                dwell_val = int(dwell_min) if pd.notna(dwell_min) else None
            except Exception:
                dwell_val = None
        else:
            gate_name = 'N/A'
            dwell_val = None
        # Compute first/last seen
        try:
            local_times = utils.to_airport_local_time(flight_data['TIMESTAMP'], tzid)
            start_time = local_times.min()
            end_time = local_times.max()
            start_str = start_time.strftime('%H:%M:%S') if pd.notna(start_time) else 'N/A'
            end_str = end_time.strftime('%H:%M:%S') if pd.notna(end_time) else 'N/A'
        except Exception:
            start_str = 'N/A'
            end_str = 'N/A'
        with col1:
            st.metric("Gate", gate_name if pd.notna(gate_name) else 'N/A')
        with col2:
            st.metric("Time Near Gate", f"{dwell_val} min" if dwell_val is not None else 'N/A')
        with col3:
            st.metric("First Seen", start_str)
        with col4:
            st.metric("Last Seen", end_str)
    else:
        col1, col2, col3, col4 = st.columns(4)
        
        with col1:
            st.metric("Flight Number", selected_flight)
        
        with col2:
            st.metric("Aircraft", flight_info['REGISTRATION'] if pd.notna(flight_info['REGISTRATION']) else 'N/A')
        
        with col3:
            st.metric("ICAO Hex", flight_info['ICAO_HEX'] if pd.notna(flight_info['ICAO_HEX']) else 'N/A')
        
        with col4:
            data_points = len(flight_data)
            st.metric("Data Points", f"{data_points:,}")

        # Show fallback carrier even without schedule
        st.caption(f"Carrier (fallback): {fallback_carrier}")

        # Gate + Time Near Gate + First/Last Seen in one row (no schedule)
        col1, col2, col3, col4 = st.columns(4)
        if gate_dwell_info is not None and not gate_dwell_info.empty:
            gate_name = gate_dwell_info.iloc[0].get('GATE_NAME', 'N/A')
            dwell_min = gate_dwell_info.iloc[0].get('DWELL_MINUTES', None)
            try:
                dwell_val = int(dwell_min) if pd.notna(dwell_min) else None
            except Exception:
                dwell_val = None
        else:
            gate_name = 'N/A'
            dwell_val = None
        try:
            local_times = utils.to_airport_local_time(flight_data['TIMESTAMP'], tzid)
            start_time = local_times.min()
            end_time = local_times.max()
            start_str = start_time.strftime('%H:%M:%S') if pd.notna(start_time) else 'N/A'
            end_str = end_time.strftime('%H:%M:%S') if pd.notna(end_time) else 'N/A'
        except Exception:
            start_str = 'N/A'
            end_str = 'N/A'
        with col1:
            st.metric("Gate", gate_name if pd.notna(gate_name) else 'N/A')
        with col2:
            st.metric("Time Near Gate", f"{dwell_val} min" if dwell_val is not None else 'N/A')
        with col3:
            st.metric("First Seen", start_str)
        with col4:
            st.metric("Last Seen", end_str)
    
    # Remove separate time range row (metrics incorporated above)
