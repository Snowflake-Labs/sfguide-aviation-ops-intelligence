"""
Gate Analysis Page - Gate utilization and dwell analytics
"""

import streamlit as st
import pandas as pd
import pydeck as pdk
from snowflake.snowpark.context import get_active_session
from datetime import datetime, timedelta
import json
import sys
import plotly.graph_objects as go
import altair as alt
sys.path.append('..')
import utils
import colors

# Page configuration
st.set_page_config(
    page_title="Gate Analysis",
    page_icon="🛬",
    layout="wide"
)

utils.apply_custom_css()

# Get session
session = get_active_session()

# Get the selected database
db = utils.get_selected_database()
schema = 'PUBLIC'
db_prefix = f"{db}.{schema}"

# Header
st.title("🛬 Gate Analysis")
st.info("🏷️ **Level 2 relevant** — Gate dwell time impacts slot coordination and capacity management")
utils.render_timezone_caption(session, db_prefix)

# Sidebar filters
with st.sidebar:
    selected_db = utils.render_airport_selector(sidebar=True)

    if not selected_db:
        st.warning("No airport databases found yet. Run the installer first.")
        st.stop()

    st.subheader("Filters")
    min_date, max_date = utils.get_date_range(session)
    try:
        local_today = datetime.fromisoformat(utils.get_airport_local_today(session, db_prefix)).date()
    except Exception:
        local_today = datetime.now().date()
    start_date, end_date = (
        (max_date - timedelta(days=7), max_date) if max_date else (local_today - timedelta(days=7), local_today)
    )
    date_range = st.date_input(
        "Date Range",
        value=(start_date, end_date)
    )
    if isinstance(date_range, tuple) and len(date_range) == 2:
        start_date, end_date = date_range
    else:
        start_date = end_date = date_range
@st.cache_data(ttl=300)
def get_gate_fill_rate(_session, start_dt, end_dt, _db_prefix):
    """Calculate gate fill rate from GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS vs GATE_ANALYSIS_FLIGHT_GATE_TIME."""
    q = f"""
    WITH total AS (
        SELECT COUNT(DISTINCT ground_session_id) AS cnt
        FROM {_db_prefix}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS
        WHERE service_date BETWEEN '{start_dt}'::DATE AND '{end_dt}'::DATE
    ),
    with_gate AS (
        SELECT COUNT(DISTINCT ground_session_id) AS cnt
        FROM {_db_prefix}.GATE_ANALYSIS_FLIGHT_GATE_TIME
        WHERE service_date BETWEEN '{start_dt}'::DATE AND '{end_dt}'::DATE
    )
    SELECT 
        t.cnt AS total_rows,
        COALESCE(w.cnt, 0) AS with_gate,
        ROUND(COALESCE(w.cnt, 0) / NULLIF(t.cnt, 0) * 100, 1) AS fill_rate_pct
    FROM total t
    CROSS JOIN with_gate w
    """
    try:
        df = _session.sql(q).to_pandas()
        if df is not None and not df.empty:
            return int(df.iloc[0]['TOTAL_ROWS']), int(df.iloc[0]['WITH_GATE']), float(df.iloc[0]['FILL_RATE_PCT'])
    except Exception:
        pass
    return 0, 0, 0.0

# Airline utility
def to_airline_name(code: str, name_map: dict) -> str:
    """Get airline name from code using the provided mapping"""
    try:
        return name_map.get(str(code), str(code)) if code else 'Unknown'
    except Exception:
        return str(code) if code else 'Unknown'

@st.cache_data(ttl=300)
def get_airline_utilization(_session, start_dt, end_dt):
    """Dwell minutes and flights by airline (uses derived table; callsign not required)."""
    q = f"""
    SELECT 
      airline_code,
      SUM(dwell_minutes) AS dwell_minutes,
      SUM(flights) AS flights
    FROM {db_prefix}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
    WHERE date BETWEEN '{start_dt}'::DATE AND '{end_dt}'::DATE
    GROUP BY airline_code
    ORDER BY dwell_minutes DESC
    """
    return _session.sql(q).to_pandas()

@st.cache_data(ttl=300)
def get_gate_rankings(_session, start_dt, end_dt):
    """Top gates by total dwell minutes and distinct flights"""
    q = f"""
    SELECT gate_name,
           SUM(dwell_minutes) AS total_dwell_minutes,
           SUM(flights) AS flights
    FROM {db_prefix}.GATE_ANALYSIS_GATE_UTIL_DAILY
    WHERE date BETWEEN '{start_dt}'::DATE AND '{end_dt}'::DATE
    GROUP BY gate_name
    ORDER BY total_dwell_minutes DESC
    """
    return _session.sql(q).to_pandas()

@st.cache_data(ttl=300)
def get_gate_by_airline_breakdown(_session, start_dt, end_dt):
    """Breakdown per gate by airline for dwell minutes and flights"""
    q = f"""
    SELECT gate_name,
           airline_code,
           SUM(dwell_minutes) AS dwell_minutes,
           SUM(flights) AS flights
    FROM {db_prefix}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY
    WHERE date BETWEEN '{start_dt}'::DATE AND '{end_dt}'::DATE
    GROUP BY gate_name, airline_code
    """
    return _session.sql(q).to_pandas()

@st.cache_data(ttl=300)
def get_gate_dow_heatmap(_session, start_dt, end_dt):
    """Aggregate dwell minutes by gate and day-of-week for the selected interval."""
    local_ts_expr = utils.get_airport_local_ts_sql(db_prefix, "ts")
    q = f"""
    SELECT 
      closest_gate_name AS gate_name,
      DAYOFWEEK({local_ts_expr}) AS day_of_week,
      SUM(lag_seconds)/60.0 AS dwell_minutes
    FROM {db_prefix}.GATE_ANALYSIS_ADSB_GROUND_POINTS
    WHERE {local_ts_expr} BETWEEN '{start_dt}'::TIMESTAMP AND '{end_dt}'::TIMESTAMP
      AND closest_gate_name IS NOT NULL
    GROUP BY gate_name, day_of_week
    """
    return _session.sql(q).to_pandas()

@st.cache_data(ttl=300)
def get_top_dwell_flights(_session, start_dt, end_dt, top_n: int = 20):
    """Top N ground sessions by dwell minutes within the given period (pre-joined table)."""
    q = f"""
    SELECT 
      flight_number,
      airline_code,
      airline_name,
      service_date AS day,
      gate_name,
      dwell_minutes
    FROM {db_prefix}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE
    WHERE service_date BETWEEN '{start_dt}'::DATE AND '{end_dt}'::DATE
    ORDER BY dwell_minutes DESC
    LIMIT {int(top_n)}
    """
    return _session.sql(q).to_pandas()

# KPI row now that dates are known
tr, wg, fr = get_gate_fill_rate(session, start_date, end_date, db_prefix)
colk1, colk2, colk3 = st.columns(3)
colk1.metric("Air Ops rows", f"{tr:,}")
colk2.metric("With GATE_ACTUAL", f"{wg:,}")
colk3.metric("Gate Actual Fill‑Rate", f"{fr:.1f}%")

# Airline dropdown (full names)
air_df_all = get_airline_utilization(session, start_date, end_date)
code_to_name = utils.get_airline_name_map(session, start_date, end_date)
if air_df_all is not None and not air_df_all.empty:
    air_df_all['AIRLINE_NAME'] = air_df_all['AIRLINE_CODE'].apply(lambda c: code_to_name.get(str(c), str(c)))
    airline_options = ["All Airlines"] + air_df_all.sort_values('AIRLINE_NAME')['AIRLINE_NAME'].tolist()
else:
    airline_options = ["All Airlines"]

with st.sidebar:
    airline_selected = st.selectbox("Airline", options=airline_options, index=0)
    hide_unknown_airlines = st.checkbox("Hide Unknown (UNK)", value=False)

# Gate Utilization by Airline
st.subheader("🏢 Gate Utilization by Airline (Dwell Minutes)")

# Prepare data for comparison
breakdown_all = get_gate_by_airline_breakdown(session, start_date, end_date)
if breakdown_all is not None and not breakdown_all.empty:
    breakdown_all = breakdown_all.copy()
    if hide_unknown_airlines:
        breakdown_all = breakdown_all[breakdown_all['AIRLINE_CODE'].astype(str) != 'UNK']
    breakdown_all['AIRLINE_NAME'] = breakdown_all['AIRLINE_CODE'].apply(lambda c: code_to_name.get(str(c), str(c)))
    if airline_selected != "All Airlines":
        breakdown_all = breakdown_all[breakdown_all['AIRLINE_NAME'] == airline_selected]
    air_gate_pivot = breakdown_all.pivot_table(index='AIRLINE_NAME', columns='GATE_NAME', values='DWELL_MINUTES', aggfunc='sum', fill_value=0)
    air_gate_pivot = air_gate_pivot.round(0)
    
    # Transform pivot to long format for Altair
    df_long = air_gate_pivot.reset_index().melt(
        id_vars='AIRLINE_NAME',
        var_name='GATE_NAME',
        value_name='DWELL_MINUTES'
    )
    
    # Sort within each airline so largest segments appear first
    df_long = df_long.sort_values(
        ['AIRLINE_NAME', 'DWELL_MINUTES'],
        ascending=[True, False]
    )
    
    chart = alt.Chart(df_long).mark_bar(size=15).encode(
        x=alt.X('sum(DWELL_MINUTES):Q', title='Dwell Minutes'),
        y=alt.Y('AIRLINE_NAME:N', 
                sort=alt.EncodingSortField(field='DWELL_MINUTES', op='sum', order='descending'),
                title='Airline',
                axis=alt.Axis(labelLimit=200)),
        color=alt.Color('GATE_NAME:N', legend=None),
        order=alt.Order('DWELL_MINUTES:Q', sort='descending'),
        tooltip=[
            alt.Tooltip('GATE_NAME:N', title='Gate'),
            alt.Tooltip('sum(DWELL_MINUTES):Q', title='Minutes', format=',.0f')
        ]
    ).properties(
        height=alt.Step(20)  # Fixed step size of 20 pixels per bar
    ).configure_mark(
        opacity=0.9
    )
    
    st.altair_chart(chart, use_container_width=True)

else:
    st.info("No utilization data available.")

st.divider()

# Gate-level stacked bars by airline proportions
breakdown_df = get_gate_by_airline_breakdown(session, start_date, end_date)
if airline_selected != "All Airlines" and breakdown_df is not None and not breakdown_df.empty:
    # Filter to selected airline name -> map back to codes
    codes_map = {code_to_name.get(str(c), str(c)): c for c in air_df_all['AIRLINE_CODE'].tolist()} if air_df_all is not None and not air_df_all.empty else {}
    selected_code = codes_map.get(airline_selected)
    if selected_code:
        breakdown_df = breakdown_df[breakdown_df['AIRLINE_CODE'] == selected_code]

# Ensure we have all gates, sort alphabetically
if breakdown_df is None:
    breakdown_df = pd.DataFrame(columns=['GATE_NAME','AIRLINE_CODE','DWELL_MINUTES','FLIGHTS'])

if hide_unknown_airlines and breakdown_df is not None and not breakdown_df.empty:
    breakdown_df = breakdown_df[breakdown_df['AIRLINE_CODE'].astype(str) != 'UNK']

st.subheader("🧭 Gate Utilization by Dwell Minutes")
if not breakdown_df.empty:
    dwell_pivot = breakdown_df.pivot_table(index='GATE_NAME', columns='AIRLINE_CODE', values='DWELL_MINUTES', aggfunc='sum', fill_value=0)
    
    # Transform to long format
    df_dwell_long = dwell_pivot.reset_index().melt(
        id_vars='GATE_NAME',
        var_name='AIRLINE_CODE',
        value_name='DWELL_MINUTES'
    )
    
    # Sort within each gate so largest segments appear first
    df_dwell_long = df_dwell_long.sort_values(
        ['GATE_NAME', 'DWELL_MINUTES'],
        ascending=[True, False]
    )
    
    # Add airline names for tooltip
    df_dwell_long['AIRLINE_NAME'] = df_dwell_long['AIRLINE_CODE'].apply(lambda c: code_to_name.get(str(c), str(c)))
    
    chart_dwell = alt.Chart(df_dwell_long).mark_bar(size=10).encode(
        x=alt.X('sum(DWELL_MINUTES):Q', title='Dwell Minutes'),
        y=alt.Y('GATE_NAME:N',
                sort=alt.EncodingSortField(field='DWELL_MINUTES', op='sum', order='descending'),
                title='Gate',
                axis=alt.Axis(labelFontSize=11)),
        color=alt.Color('AIRLINE_CODE:N', legend=None),
        order=alt.Order('DWELL_MINUTES:Q', sort='descending'),
        tooltip=[
            alt.Tooltip('AIRLINE_NAME:N', title='Airline'),
            alt.Tooltip('sum(DWELL_MINUTES):Q', title='Minutes', format=',.0f')
        ]
    ).properties(
        height=alt.Step(15)  # Fixed step size of 15 pixels per bar
    ).configure_mark(
        opacity=0.9
    )
    
    st.altair_chart(chart_dwell, use_container_width=True)
else:
    st.info("No gate dwell data available.")

st.divider()

st.subheader("🧮 Gate Utilization by Number of Flights")
if not breakdown_df.empty:
    flights_pivot = breakdown_df.pivot_table(index='GATE_NAME', columns='AIRLINE_CODE', values='FLIGHTS', aggfunc='sum', fill_value=0)
    
    # Transform to long format
    df_flights_long = flights_pivot.reset_index().melt(
        id_vars='GATE_NAME',
        var_name='AIRLINE_CODE',
        value_name='FLIGHTS'
    )
    
    # Sort within each gate so largest segments appear first
    df_flights_long = df_flights_long.sort_values(
        ['GATE_NAME', 'FLIGHTS'],
        ascending=[True, False]
    )
    
    # Add airline names for tooltip
    df_flights_long['AIRLINE_NAME'] = df_flights_long['AIRLINE_CODE'].apply(lambda c: code_to_name.get(str(c), str(c)))
    
    chart_flights = alt.Chart(df_flights_long).mark_bar(size=10).encode(
        x=alt.X('sum(FLIGHTS):Q', title='Flights'),
        y=alt.Y('GATE_NAME:N',
                sort=alt.EncodingSortField(field='FLIGHTS', op='sum', order='descending'),
                title='Gate',
                axis=alt.Axis(labelFontSize=11)),
        color=alt.Color('AIRLINE_CODE:N', legend=None),
        order=alt.Order('FLIGHTS:Q', sort='descending'),
        tooltip=[
            alt.Tooltip('AIRLINE_NAME:N', title='Airline'),
            alt.Tooltip('sum(FLIGHTS):Q', title='Flights', format=',.0f')
        ]
    ).properties(
        height=alt.Step(15)  # Fixed step size of 15 pixels per bar
    ).configure_mark(
        opacity=0.9
    )
    
    st.altair_chart(chart_flights, use_container_width=True)
else:
    st.info("No gate flights data available.")

st.divider()

st.subheader("🏅 Top 20 Flights by Dwell Time (Minutes)")
top_df = get_top_dwell_flights(session, start_date, end_date, top_n=20)
if top_df is not None and not top_df.empty:
    display_df = top_df.copy()
    if hide_unknown_airlines:
        display_df = display_df[display_df['AIRLINE_CODE'].astype(str).str.strip().str.upper() != 'UNK']
    
    display_df = display_df.sort_values('DWELL_MINUTES', ascending=False)
    
    if 'AIRLINE_NAME' not in display_df.columns:
        display_df['AIRLINE_NAME'] = None
    display_df['AIRLINE_NAME'] = display_df['AIRLINE_NAME'].fillna(
        display_df['AIRLINE_CODE'].apply(lambda c: code_to_name.get(str(c), str(c)))
    )
    display_df['LABEL'] = display_df.apply(lambda r: f"{str(r.get('FLIGHT_NUMBER',''))} — {r.get('AIRLINE_NAME','')} — {r.get('DAY','')} ({r.get('GATE_NAME','N/A')})", axis=1)
    
    chart_top = alt.Chart(display_df).mark_bar(color='#4FC3F7', size=10).encode(
        x=alt.X('DWELL_MINUTES:Q', title='Dwell Minutes'),
        y=alt.Y('LABEL:N', sort='-x', title='Flight (Gate)',
                axis=alt.Axis(labelLimit=300)),
        tooltip=[
            alt.Tooltip('FLIGHT_NUMBER:N', title='Flight'),
            alt.Tooltip('AIRLINE_NAME:N', title='Airline'),
            alt.Tooltip('GATE_NAME:N', title='Gate'),
            alt.Tooltip('DWELL_MINUTES:Q', title='Dwell Minutes', format='.0f')
        ]
    ).properties(
        height=alt.Step(20)
    )
    
    st.altair_chart(chart_top, use_container_width=True)
else:
    st.info("No flights with dwell time found in selected range.")

st.divider()

st.subheader("📊 Gate Usage Heatmap by Day of Week")
st.caption("**Color Scale:** Teal (low) → Yellow (medium) → Red (high) dwell time. Color intensity shows total time aircraft spent at each gate by day of week.")
hm_df = get_gate_dow_heatmap(session, start_date, end_date)
if hm_df is not None and not hm_df.empty:
    day_names = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
    hm_df = hm_df.copy()
    hm_df['DAY_NAME'] = hm_df['DAY_OF_WEEK'].apply(lambda x: day_names[int(x) % 7])
    
    # Sort gates by natural order (A1, A2, A10 instead of A1, A10, A2)
    try:
        import re
        def natural_sort_key(s):
            return [int(text) if text.isdigit() else text.lower() for text in re.split('([0-9]+)', str(s))]
        sorted_gates = sorted(hm_df['GATE_NAME'].unique(), key=natural_sort_key)
    except Exception:
        sorted_gates = sorted(hm_df['GATE_NAME'].unique())
    
    # Ensure day order
    hm_df['DAY_NAME'] = pd.Categorical(hm_df['DAY_NAME'], categories=day_names, ordered=True)
    hm_df['GATE_NAME'] = pd.Categorical(hm_df['GATE_NAME'], categories=sorted_gates, ordered=True)
    
    chart_hm = alt.Chart(hm_df).mark_rect().encode(
        x=alt.X('GATE_NAME:O', title='Gate', sort=sorted_gates),
        y=alt.Y('DAY_NAME:O', title='Day of Week', sort=day_names),
        color=alt.Color('DWELL_MINUTES:Q', 
                       title='Dwell Time (min)',
                       scale=alt.Scale(scheme='turbo')),
        tooltip=[
            alt.Tooltip('DAY_NAME:O', title='Day'),
            alt.Tooltip('GATE_NAME:O', title='Gate'),
            alt.Tooltip('DWELL_MINUTES:Q', title='Dwell Minutes', format='.0f')
        ]
    ).properties(
        height=500
    )
    
    st.altair_chart(chart_hm, use_container_width=True)
else:
    st.info("No gate/day-of-week data available for the selected range.")
