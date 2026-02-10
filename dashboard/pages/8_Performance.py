"""
Performance (v4)
Operational KPIs from Air Ops timelines and schedule
"""

import streamlit as st
import pandas as pd
import plotly.express as px
from datetime import datetime, timedelta
from snowflake.snowpark.context import get_active_session
import utils
import ui_components

st.set_page_config(page_title="Performance", page_icon="📊", layout="wide")
utils.apply_custom_css()
session = get_active_session()

schema = 'PUBLIC'

# Helpers
@st.cache_data(ttl=3600)
def get_ops_date_range(_session, _db_prefix: str):
    try:
        q = f"""
        SELECT MIN(service_date) AS min_date, MAX(service_date) AS max_date
        FROM {_db_prefix}.V_AIR_OPS_TIMELINE
        """
        r = _session.sql(q).collect()
        if r:
            return r[0]['MIN_DATE'], r[0]['MAX_DATE']
    except Exception:
        pass
    return None, None

with st.sidebar:
    selected_db = ui_components.render_airport_selector(sidebar=True)

if not selected_db:
    st.warning("No airport databases found yet. Run the installer first.")
    st.stop()

db_prefix = f"{selected_db}.{schema}"
min_date, max_date = get_ops_date_range(session, db_prefix)

with st.sidebar:
    start_date, end_date = ui_components.render_date_range_picker(
        min_date,
        max_date,
        key_prefix="performance",
        default_days_back=7
    )
    
    st.divider()

    @st.cache_data(ttl=600)
    def get_airlines(_session, _db_prefix: str):
        try:
            q = f"""
            SELECT DISTINCT airline_name
            FROM {_db_prefix}.V_AIR_OPS_DAILY_KPIS
            ORDER BY airline_name
            """
            df = _session.sql(q).to_pandas()
            return sorted([str(a) for a in df['AIRLINE_NAME'].tolist()]) if df is not None and not df.empty else []
        except Exception:
            return []

    airline_list = ["All"] + get_airlines(session, db_prefix)
    selected_airline = st.selectbox("Airline", airline_list)

@st.cache_data(ttl=600)
def get_daily_kpis(_session, start_d, end_d, airline: str | None):
    base = f"""
    SELECT service_date,
           airline_name,
           ops,
           med_taxi_out_min,
           med_taxi_in_min,
           med_dep_runway_occ_min,
           med_arr_runway_occ_min,
           on_time_dep_out_15m_rate,
           on_time_arr_in_15m_rate,
           head_to_head
    FROM {db_prefix}.V_AIR_OPS_DAILY_KPIS
    WHERE service_date BETWEEN '{start_d}'::DATE AND '{end_d}'::DATE
    """
    if airline and airline != "All":
        esc = airline.replace("'", "''")
        base += f" AND airline_name = '{esc}'"
    base += " ORDER BY service_date"
    try:
        return _session.sql(base).to_pandas()
    except Exception:
        return pd.DataFrame()

df = get_daily_kpis(session, start_date, end_date, selected_airline)

st.title("📊 Performance KPIs")
utils.render_timezone_caption(session, db_prefix)

if df is None or df.empty:
    st.info("No data available for the selected filters.")
else:
    latest = df.iloc[-1]
    col1, col2, col3, col4 = st.columns(4)
    with col1:
        st.metric("Operations (last day)", f"{int(latest['OPS'])}")
    with col2:
        st.metric("Median Taxi‑out (min)", f"{latest['MED_TAXI_OUT_MIN']:.1f}")
    with col3:
        st.metric("Median Taxi‑in (min)", f"{latest['MED_TAXI_IN_MIN']:.1f}")
    with col4:
        st.metric("On‑time Arrivals (<=15m)", f"{latest['ON_TIME_ARR_IN_15M_RATE']*100:.1f}%")

    st.divider()
    c1, c2 = st.columns(2)
    with c1:
        fig = px.line(df, x='SERVICE_DATE', y=['MED_TAXI_OUT_MIN','MED_TAXI_IN_MIN'], render_mode='svg',
                      labels={'value':'Minutes','SERVICE_DATE':'Date'},
                      title='Median Taxi Times')
        st.plotly_chart(fig, use_container_width=True)
    with c2:
        fig2 = px.line(df, x='SERVICE_DATE', y=['ON_TIME_DEP_OUT_15M_RATE','ON_TIME_ARR_IN_15M_RATE'], render_mode='svg',
                       labels={'value':'Rate','SERVICE_DATE':'Date'},
                       title='On‑time Rates (<=15m)')
        st.plotly_chart(fig2, use_container_width=True)

    st.divider()
    st.subheader("Head‑to‑Head Indicator (by day)")
    df_h2h = df[['SERVICE_DATE','HEAD_TO_HEAD']].copy()
    df_h2h['Throughput Risk'] = df_h2h['HEAD_TO_HEAD'].apply(lambda x: 'Irregular' if bool(x) else 'Normal')
    fig3 = px.bar(df_h2h, x='SERVICE_DATE', y=df_h2h['HEAD_TO_HEAD'].astype(int),
                  title='Head‑to‑Head Days', labels={'y':'Flag'})
    st.plotly_chart(fig3, use_container_width=True)


