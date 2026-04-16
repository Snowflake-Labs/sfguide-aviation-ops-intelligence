"""
TSA Throughput Analysis Page - Checkpoint passenger throughput trends
Analyze TSA checkpoint throughput by hour, day, and checkpoint
"""

import streamlit as st
import pandas as pd
import pydeck as pdk
import plotly.graph_objects as go
from plotly.subplots import make_subplots
from snowflake.snowpark.context import get_active_session
from datetime import datetime, timedelta
import altair as alt
import json
import sys
sys.path.append('..')
import utils
from config import BAR_CONFIG, TOOLTIP_FORMAT
from config.colors import Hex as COLORS, get_intensity_color_3point
import ui_components

st.set_page_config(
    page_title="TSA Throughput",
    page_icon="🛂",
    layout="wide"
)

utils.apply_custom_css()

session = get_active_session()

db = utils.get_selected_database()
schema = 'PUBLIC'
db_prefix = f"{db}.{schema}"

with st.sidebar:
    selected_db = ui_components.render_airport_selector(sidebar=True)
if not selected_db:
    st.warning("No airport databases found yet. Run the installer first.")
    st.stop()

st.title("🛂 TSA Checkpoint Throughput")
st.markdown("Analyze passenger checkpoint throughput from TSA FOIA data")

@st.cache_data(ttl=300)
def get_airport_iata(_session):
    query = f"""
    SELECT UPPER(airport_code) AS airport_code
    FROM {db_prefix}.PROPERTIES_AIRPORT
    LIMIT 1
    """
    try:
        result = _session.sql(query).to_pandas()
        if not result.empty:
            return result.iloc[0]['AIRPORT_CODE']
    except Exception:
        pass
    return None

airport_iata = get_airport_iata(session)
if not airport_iata:
    st.warning("Airport properties not found. Run the installer first.")
    st.stop()

@st.cache_data(ttl=300)
def check_tsa_table_exists(_session):
    try:
        _session.sql(f"SELECT 1 FROM {db_prefix}.TSA_THROUGHPUT LIMIT 0").collect()
        return True
    except Exception:
        return False

if not check_tsa_table_exists(session):
    st.info("TSA throughput data is not available for this airport. The TSA throughput pipeline may not have been installed.")
    st.stop()

@st.cache_data(ttl=300)
def get_tsa_date_range(_session, iata):
    query = f"""
    SELECT
        MIN(TRY_TO_DATE(date, 'MM/DD/YYYY')) AS min_date,
        MAX(TRY_TO_DATE(date, 'MM/DD/YYYY')) AS max_date
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') IS NOT NULL
    """
    result = _session.sql(query).to_pandas()
    if not result.empty and result.iloc[0]['MIN_DATE'] is not None:
        return result.iloc[0]['MIN_DATE'], result.iloc[0]['MAX_DATE']
    return None, None

tsa_min_date, tsa_max_date = get_tsa_date_range(session, airport_iata)
if tsa_min_date is None:
    st.info(f"No TSA throughput records found for airport **{airport_iata}**. This airport may not have TSA checkpoint data.")
    st.stop()

with st.sidebar:
    tsa_min_dt = pd.to_datetime(tsa_min_date).date()
    tsa_max_dt = pd.to_datetime(tsa_max_date).date()
    default_start = max(tsa_min_dt, tsa_max_dt - timedelta(days=7))

    start_date = st.date_input(
        "Start Date",
        value=default_start,
        min_value=tsa_min_dt,
        max_value=tsa_max_dt,
        key="tsa_start_date"
    )
    end_date = st.date_input(
        "End Date",
        value=tsa_max_dt,
        min_value=tsa_min_dt,
        max_value=tsa_max_dt,
        key="tsa_end_date"
    )

    st.divider()

@st.cache_data(ttl=300)
def get_checkpoints(_session, iata, start_dt, end_dt):
    query = f"""
    SELECT DISTINCT checkpoint
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
      AND checkpoint IS NOT NULL AND checkpoint != ''
      AND LEN(checkpoint) < 40
    ORDER BY checkpoint
    """
    result = _session.sql(query).to_pandas()
    return result['CHECKPOINT'].tolist() if not result.empty else []

all_checkpoints = get_checkpoints(session, airport_iata, start_date, end_date)

with st.sidebar:
    selected_checkpoints = st.multiselect(
        "Checkpoints",
        options=all_checkpoints,
        default=all_checkpoints,
        key="tsa_checkpoints"
    )

checkpoint_filter = "1=1"
if selected_checkpoints and len(selected_checkpoints) < len(all_checkpoints):
    escaped = "','".join([c.replace("'", "''") for c in selected_checkpoints])
    checkpoint_filter = f"checkpoint IN ('{escaped}')"

@st.cache_data(ttl=300)
def get_daily_throughput(_session, iata, start_dt, end_dt, chk_filter):
    query = f"""
    SELECT
        TRY_TO_DATE(date, 'MM/DD/YYYY') AS tsa_date,
        SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS total_pax,
        COUNT(DISTINCT checkpoint) AS checkpoint_count
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
      AND LEN(checkpoint) < 40
      AND {chk_filter}
    GROUP BY tsa_date
    ORDER BY tsa_date
    """
    return _session.sql(query).to_pandas()

@st.cache_data(ttl=300)
def get_hourly_pattern(_session, iata, start_dt, end_dt, chk_filter):
    query = f"""
    SELECT
        TRY_TO_NUMBER(SPLIT_PART(hour_of_day, ':', 1)) AS hour_of_day,
        SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS total_pax
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
      AND TRY_TO_NUMBER(SPLIT_PART(hour_of_day, ':', 1)) IS NOT NULL
      AND LEN(checkpoint) < 40
      AND {chk_filter}
    GROUP BY hour_of_day
    ORDER BY hour_of_day
    """
    return _session.sql(query).to_pandas()

@st.cache_data(ttl=300)
def get_checkpoint_breakdown(_session, iata, start_dt, end_dt, chk_filter):
    query = f"""
    SELECT
        checkpoint,
        SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS total_pax
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
      AND checkpoint IS NOT NULL AND checkpoint != ''
      AND LEN(checkpoint) < 40
      AND {chk_filter}
    GROUP BY checkpoint
    ORDER BY total_pax DESC
    """
    return _session.sql(query).to_pandas()

@st.cache_data(ttl=300)
def get_heatmap_data(_session, iata, start_dt, end_dt, chk_filter):
    query = f"""
    SELECT
        TRY_TO_NUMBER(SPLIT_PART(hour_of_day, ':', 1)) AS hour,
        DAYOFWEEK(TRY_TO_DATE(date, 'MM/DD/YYYY')) AS day_of_week,
        SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS total_pax
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
      AND TRY_TO_NUMBER(SPLIT_PART(hour_of_day, ':', 1)) IS NOT NULL
      AND LEN(checkpoint) < 40
      AND {chk_filter}
    GROUP BY hour, day_of_week
    ORDER BY day_of_week, hour
    """
    return _session.sql(query).to_pandas()

with st.spinner("Loading TSA throughput data..."):
    daily_data = get_daily_throughput(session, airport_iata, start_date, end_date, checkpoint_filter)
    hourly_data = get_hourly_pattern(session, airport_iata, start_date, end_date, checkpoint_filter)
    checkpoint_data = get_checkpoint_breakdown(session, airport_iata, start_date, end_date, checkpoint_filter)
    heatmap_data = get_heatmap_data(session, airport_iata, start_date, end_date, checkpoint_filter)

if daily_data.empty:
    st.info(f"No TSA throughput data found for **{airport_iata}** in the selected date range.")
    st.stop()

total_pax = int(daily_data['TOTAL_PAX'].sum())
num_days = daily_data['TSA_DATE'].nunique()
daily_avg = int(total_pax / num_days) if num_days > 0 else 0
num_checkpoints = int(daily_data['CHECKPOINT_COUNT'].max()) if not daily_data.empty else 0

peak_hour_label = "N/A"
if not hourly_data.empty:
    peak_row = hourly_data.loc[hourly_data['TOTAL_PAX'].idxmax()]
    peak_hour_label = f"{int(peak_row['HOUR_OF_DAY']):02d}:00"

col1, col2, col3, col4 = st.columns(4)
col1.metric("Total Passengers", f"{total_pax:,}")
col2.metric("Daily Average", f"{daily_avg:,}")
col3.metric("Peak Hour", peak_hour_label)
col4.metric("Checkpoints", num_checkpoints)

st.divider()

@st.cache_data(ttl=300)
def get_checkpoint_geo_data(_session, iata, start_dt, end_dt, chk_filter):
    try:
        _session.sql(f"SELECT 1 FROM {db_prefix}.V_TSA_CHECKPOINT_GEO LIMIT 0").collect()
    except Exception:
        return pd.DataFrame()
    query = f"""
    SELECT
        checkpoint,
        terminal_name,
        lat,
        lon,
        terminal_geojson::VARCHAR AS terminal_geojson,
        match_type,
        SUM(passengers) AS total_passengers,
        COUNT(DISTINCT throughput_date) AS num_days,
        ROUND(SUM(passengers) / NULLIF(COUNT(DISTINCT throughput_date), 0)) AS daily_avg_passengers
    FROM {db_prefix}.V_TSA_CHECKPOINT_GEO
    WHERE throughput_date BETWEEN '{start_dt}' AND '{end_dt}'
      AND {chk_filter}
    GROUP BY 1, 2, 3, 4, 5, 6
    ORDER BY total_passengers DESC NULLS LAST
    """
    return _session.sql(query).to_pandas()

@st.cache_data(ttl=3600)
def get_airport_center(_session):
    query = f"SELECT center_lat, center_lon FROM {db_prefix}.PROPERTIES_AIRPORT LIMIT 1"
    result = _session.sql(query).to_pandas()
    if not result.empty:
        return float(result.iloc[0]['CENTER_LAT']), float(result.iloc[0]['CENTER_LON'])
    return 32.73, -117.19

geo_data = get_checkpoint_geo_data(session, airport_iata, start_date, end_date, checkpoint_filter)

if not geo_data.empty and geo_data['TOTAL_PASSENGERS'].notna().any():
    st.subheader("🗺️ Checkpoint Throughput Map")
    st.caption("Terminal polygons and checkpoint locations sized by passenger throughput. Unmatched checkpoints shown at airport center.")

    center_lat, center_lon = get_airport_center(session)

    max_pax = geo_data['TOTAL_PASSENGERS'].max() if geo_data['TOTAL_PASSENGERS'].notna().any() else 1
    if pd.isna(max_pax) or max_pax == 0:
        max_pax = 1

    geo_data['NORM'] = geo_data['TOTAL_PASSENGERS'].fillna(0) / max_pax
    geo_data['COLOR'] = geo_data['NORM'].apply(get_intensity_color_3point)
    geo_data['RADIUS'] = (geo_data['NORM'].fillna(0) * 150 + 30).astype(float)
    geo_data['DISPLAY_PAX'] = geo_data['TOTAL_PASSENGERS'].fillna(0).astype(int).apply(lambda x: f"{x:,}")
    geo_data['DISPLAY_AVG'] = geo_data['DAILY_AVG_PASSENGERS'].fillna(0).astype(int).apply(lambda x: f"{x:,}")
    geo_data['DISPLAY_MATCH'] = geo_data['MATCH_TYPE'].apply(
        lambda x: 'Terminal Matched' if x == 'matched' else 'Airport Center (no match)')

    layers = []

    polys_with_geojson = geo_data[geo_data['TERMINAL_GEOJSON'].notna() & (geo_data['MATCH_TYPE'] == 'matched')]
    if not polys_with_geojson.empty:
        features = []
        seen = set()
        for _, row in polys_with_geojson.iterrows():
            key = row.get('TERMINAL_NAME', '')
            if key in seen or not row['TERMINAL_GEOJSON']:
                continue
            seen.add(key)
            try:
                raw_geojson = row['TERMINAL_GEOJSON']
                if isinstance(raw_geojson, str):
                    geom = json.loads(raw_geojson)
                elif isinstance(raw_geojson, dict):
                    geom = raw_geojson
                else:
                    continue
                norm_val = float(row['NORM']) if pd.notna(row['NORM']) else 0
                color = get_intensity_color_3point(norm_val)
                features.append({
                    "type": "Feature",
                    "geometry": geom,
                    "properties": {
                        "terminal_name": str(row.get('TERMINAL_NAME', '')),
                        "passengers": str(row.get('DISPLAY_PAX', '0')),
                        "fill_color": color[:3],
                        "fill_alpha": 100,
                    }
                })
            except (json.JSONDecodeError, TypeError):
                continue

        if features:
            geojson_data = {"type": "FeatureCollection", "features": features}
            layers.append(pdk.Layer(
                "GeoJsonLayer",
                data=geojson_data,
                pickable=True,
                stroked=True,
                filled=True,
                get_fill_color="[properties.fill_color[0], properties.fill_color[1], properties.fill_color[2], properties.fill_alpha]",
                get_line_color=[200, 200, 200, 180],
                get_line_width=2,
                line_width_min_pixels=1,
            ))

    scatter_data = geo_data[['LAT', 'LON', 'COLOR', 'RADIUS', 'CHECKPOINT', 'DISPLAY_PAX', 'DISPLAY_AVG', 'DISPLAY_MATCH', 'MATCH_TYPE']].copy()
    scatter_data = scatter_data.rename(columns={'LAT': 'lat', 'LON': 'lon'})
    scatter_data['lat'] = scatter_data['lat'].astype(float)
    scatter_data['lon'] = scatter_data['lon'].astype(float)
    scatter_data['RADIUS'] = scatter_data['RADIUS'].astype(float)

    layers.append(pdk.Layer(
        "ScatterplotLayer",
        data=scatter_data,
        get_position='[lon, lat]',
        get_fill_color='COLOR',
        get_radius='RADIUS',
        radius_min_pixels=8,
        radius_max_pixels=60,
        pickable=True,
        opacity=0.85,
    ))

    centroid_data = scatter_data[scatter_data['MATCH_TYPE'] == 'centroid']
    if not centroid_data.empty:
        layers.append(pdk.Layer(
            "ScatterplotLayer",
            data=centroid_data,
            get_position='[lon, lat]',
            get_fill_color=[180, 180, 180, 120],
            get_line_color=[255, 255, 255, 200],
            get_radius='RADIUS',
            radius_min_pixels=6,
            radius_max_pixels=40,
            stroked=True,
            line_width_min_pixels=2,
            pickable=True,
            opacity=0.7,
        ))

    r = pdk.Deck(
        layers=layers,
        initial_view_state=pdk.ViewState(
            latitude=center_lat,
            longitude=center_lon,
            zoom=14,
            pitch=30,
        ),
        tooltip={
            "html": "<b>{CHECKPOINT}</b><br/>Passengers: {DISPLAY_PAX}<br/>Daily Avg: {DISPLAY_AVG}<br/>{DISPLAY_MATCH}",
            "style": {"backgroundColor": "#1a2332", "color": "white", "fontSize": "12px"}
        }
    )
    st.pydeck_chart(r, use_container_width=True, height=500, key="tsa_checkpoint_map")

    match_summary = geo_data.groupby('MATCH_TYPE').agg(
        checkpoints=('CHECKPOINT', 'nunique'),
        passengers=('TOTAL_PASSENGERS', 'sum')
    ).reset_index()
    cols = st.columns(len(match_summary))
    for i, (_, row) in enumerate(match_summary.iterrows()):
        label = "Terminal Matched" if row['MATCH_TYPE'] == 'matched' else "Airport Center"
        pax_val = int(row['passengers']) if pd.notna(row['passengers']) else 0
        cols[i].metric(f"{label} ({int(row['checkpoints'])} checkpoints)", f"{pax_val:,} pax")

    st.divider()

st.subheader("📅 Daily Throughput Trend")

if not daily_data.empty:
    fig = make_subplots(specs=[[{"secondary_y": True}]])

    fig.add_trace(
        go.Scatter(
            x=daily_data['TSA_DATE'],
            y=daily_data['TOTAL_PAX'],
            name="Total Passengers",
            line=dict(color=COLORS.BLUE, width=3),
            fill='tozeroy',
            fillcolor='rgba(79, 195, 247, 0.2)'
        ),
        secondary_y=False
    )

    fig.add_trace(
        go.Scatter(
            x=daily_data['TSA_DATE'],
            y=daily_data['CHECKPOINT_COUNT'],
            name="Checkpoints Active",
            line=dict(color=COLORS.LIGHT_GREEN, width=2, dash='dot')
        ),
        secondary_y=True
    )

    fig.update_xaxes(title_text="Date")
    fig.update_yaxes(title_text="Passengers", secondary_y=False)
    fig.update_yaxes(title_text="Checkpoints", secondary_y=True)

    fig.update_layout(
        hovermode='x unified',
        height=450,
        template='plotly_white',
        showlegend=True
    )

    st.plotly_chart(fig, use_container_width=True)

st.divider()

col1, col2 = st.columns(2)

with col1:
    st.subheader("🕐 Throughput by Hour of Day")

    if not hourly_data.empty:
        chart_hourly = alt.Chart(hourly_data).mark_bar(color=COLORS.BLUE, size=BAR_CONFIG['vertical']['size']).encode(
            x=alt.X('HOUR_OF_DAY:Q', title='Hour of Day (24h)', scale=alt.Scale(domain=[0, 23])),
            y=alt.Y('TOTAL_PAX:Q', title='Total Passengers'),
            tooltip=[
                alt.Tooltip('HOUR_OF_DAY:Q', title='Hour', format='02d'),
                alt.Tooltip('TOTAL_PAX:Q', title='Passengers', format=TOOLTIP_FORMAT['integer'])
            ]
        ).properties(height=400)

        st.altair_chart(chart_hourly, use_container_width=True)

        peak = hourly_data.loc[hourly_data['TOTAL_PAX'].idxmax()]
        st.info(f"🔝 Peak Hour: **{int(peak['HOUR_OF_DAY']):02d}:00** with **{int(peak['TOTAL_PAX']):,}** passengers")

with col2:
    st.subheader("🏢 Throughput by Checkpoint")

    if not checkpoint_data.empty:
        checkpoint_data_filtered = checkpoint_data[
            checkpoint_data['TOTAL_PAX'].notna() & (checkpoint_data['TOTAL_PAX'] > 0)
        ].copy()

        if not checkpoint_data_filtered.empty:
            num_bars = len(checkpoint_data_filtered)
            step_size = max(30, BAR_CONFIG['horizontal']['step'])
            chart_height = max(200, num_bars * step_size + 40)

            chart_chk = alt.Chart(checkpoint_data_filtered).mark_bar(color=COLORS.LIGHT_GREEN, size=BAR_CONFIG['horizontal']['size']).encode(
                x=alt.X('TOTAL_PAX:Q', title='Total Passengers'),
                y=alt.Y('CHECKPOINT:N', sort='-x', title='Checkpoint',
                        axis=alt.Axis(labelLimit=300)),
                tooltip=[
                    alt.Tooltip('CHECKPOINT:N', title='Checkpoint'),
                    alt.Tooltip('TOTAL_PAX:Q', title='Passengers', format=TOOLTIP_FORMAT['integer'])
                ]
            ).properties(height=chart_height)

            st.altair_chart(chart_chk, use_container_width=True)
        else:
            st.info("All checkpoints have zero throughput in selected period.")
    else:
        st.info("No checkpoint breakdown available.")

checkpoint_data_for_pie = checkpoint_data[
    checkpoint_data['TOTAL_PAX'].notna() & (checkpoint_data['TOTAL_PAX'] > 0)
].copy() if not checkpoint_data.empty else pd.DataFrame()

if not checkpoint_data_for_pie.empty and len(checkpoint_data_for_pie) > 1:
    st.divider()
    st.subheader("📊 Checkpoint Share")

    chart_pie = alt.Chart(checkpoint_data_for_pie).mark_arc(innerRadius=50).encode(
        theta=alt.Theta('TOTAL_PAX:Q'),
        color=alt.Color('CHECKPOINT:N', legend=alt.Legend(title='Checkpoint')),
        tooltip=[
            alt.Tooltip('CHECKPOINT:N', title='Checkpoint'),
            alt.Tooltip('TOTAL_PAX:Q', title='Passengers', format=',.0f')
        ]
    ).properties(
        height=400
    )

    st.altair_chart(chart_pie, use_container_width=True)

if not heatmap_data.empty:
    st.divider()
    st.subheader("🔥 Throughput Heatmap (Day of Week × Hour)")
    st.caption("Color intensity shows passenger count: darker = more passengers")

    day_names = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
    heatmap_data['DAY_NAME'] = heatmap_data['DAY_OF_WEEK'].apply(lambda x: day_names[int(x)])
    heatmap_data['HOUR_LABEL'] = heatmap_data['HOUR'].apply(lambda h: f"{int(h):02d}:00")

    heatmap_data['DAY_NAME'] = pd.Categorical(heatmap_data['DAY_NAME'], categories=day_names, ordered=True)
    hour_labels = [f"{h:02d}:00" for h in range(24)]
    heatmap_data['HOUR_LABEL'] = pd.Categorical(heatmap_data['HOUR_LABEL'], categories=hour_labels, ordered=True)

    chart_hm = alt.Chart(heatmap_data).mark_rect().encode(
        x=alt.X('HOUR_LABEL:O', title='Hour of Day', sort=hour_labels),
        y=alt.Y('DAY_NAME:O', title='Day of Week', sort=day_names),
        color=alt.Color('TOTAL_PAX:Q',
                       title='Passengers',
                       scale=alt.Scale(scheme='turbo')),
        tooltip=[
            alt.Tooltip('DAY_NAME:O', title='Day'),
            alt.Tooltip('HOUR_LABEL:O', title='Hour'),
            alt.Tooltip('TOTAL_PAX:Q', title='Passengers', format=',.0f')
        ]
    ).properties(
        height=300
    )

    st.caption("**Color Scale:** Teal (low) → Yellow (medium) → Red (high) passenger count.")
    st.altair_chart(chart_hm, use_container_width=True)

with st.expander("📋 Raw Data"):
    @st.cache_data(ttl=300)
    def get_raw_data(_session, iata, start_dt, end_dt, chk_filter):
        query = f"""
        SELECT
            TRY_TO_DATE(date, 'MM/DD/YYYY') AS date,
            hour_of_day,
            checkpoint,
            TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0) AS passengers,
            airport_name,
            city,
            state
        FROM {db_prefix}.TSA_THROUGHPUT
        WHERE UPPER(airport_code) = '{iata}'
          AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
          AND LEN(checkpoint) < 40
          AND {chk_filter}
        ORDER BY date DESC, hour_of_day
        LIMIT 1000
        """
        return _session.sql(query).to_pandas()

    raw = get_raw_data(session, airport_iata, start_date, end_date, checkpoint_filter)
    st.dataframe(raw, use_container_width=True, hide_index=True)
