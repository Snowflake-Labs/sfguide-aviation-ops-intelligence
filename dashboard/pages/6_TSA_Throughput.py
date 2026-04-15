"""
TSA Throughput Analysis Page - Checkpoint passenger throughput trends
Analyze TSA checkpoint throughput by hour, day, and checkpoint
"""

import streamlit as st
import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots
from snowflake.snowpark.context import get_active_session
from datetime import datetime, timedelta
import altair as alt
import sys
sys.path.append('..')
import utils
from config import BAR_CONFIG, TOOLTIP_FORMAT
from config.colors import Hex as COLORS
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
      AND {chk_filter}
    GROUP BY tsa_date
    ORDER BY tsa_date
    """
    return _session.sql(query).to_pandas()

@st.cache_data(ttl=300)
def get_hourly_pattern(_session, iata, start_dt, end_dt, chk_filter):
    query = f"""
    SELECT
        TRY_TO_NUMBER(hour_of_day) AS hour_of_day,
        SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS total_pax
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
      AND TRY_TO_NUMBER(hour_of_day) IS NOT NULL
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
      AND {chk_filter}
    GROUP BY checkpoint
    ORDER BY total_pax DESC
    """
    return _session.sql(query).to_pandas()

@st.cache_data(ttl=300)
def get_heatmap_data(_session, iata, start_dt, end_dt, chk_filter):
    query = f"""
    SELECT
        TRY_TO_NUMBER(hour_of_day) AS hour,
        DAYOFWEEK(TRY_TO_DATE(date, 'MM/DD/YYYY')) AS day_of_week,
        SUM(TRY_TO_NUMBER(REPLACE(total_pax_kcm_pax, ',', ''), 10, 0)) AS total_pax
    FROM {db_prefix}.TSA_THROUGHPUT
    WHERE UPPER(airport_code) = '{iata}'
      AND TRY_TO_DATE(date, 'MM/DD/YYYY') BETWEEN '{start_dt}' AND '{end_dt}'
      AND TRY_TO_NUMBER(hour_of_day) IS NOT NULL
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
        chart_chk = alt.Chart(checkpoint_data).mark_bar(color=COLORS.LIGHT_GREEN, size=BAR_CONFIG['horizontal']['size']).encode(
            x=alt.X('TOTAL_PAX:Q', title='Total Passengers'),
            y=alt.Y('CHECKPOINT:N', sort='-x', title='Checkpoint',
                    axis=alt.Axis(labelLimit=BAR_CONFIG['horizontal']['label_limit'])),
            tooltip=[
                alt.Tooltip('CHECKPOINT:N', title='Checkpoint'),
                alt.Tooltip('TOTAL_PAX:Q', title='Passengers', format=TOOLTIP_FORMAT['integer'])
            ]
        ).properties(height=alt.Step(BAR_CONFIG['horizontal']['step']))

        st.altair_chart(chart_chk, use_container_width=True)
    else:
        st.info("No checkpoint breakdown available.")

if not checkpoint_data.empty and len(checkpoint_data) > 1:
    st.divider()
    st.subheader("📊 Checkpoint Share")

    chart_pie = alt.Chart(checkpoint_data).mark_arc(innerRadius=50).encode(
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
          AND {chk_filter}
        ORDER BY date DESC, hour_of_day
        LIMIT 1000
        """
        return _session.sql(query).to_pandas()

    raw = get_raw_data(session, airport_iata, start_date, end_date, checkpoint_filter)
    st.dataframe(raw, use_container_width=True, hide_index=True)
