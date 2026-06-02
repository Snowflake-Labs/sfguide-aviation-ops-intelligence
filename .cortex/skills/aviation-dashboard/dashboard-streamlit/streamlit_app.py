"""
Dashboard Home

Uses Streamlit built-in multipage sidebar navigation (dashboard/pages/*).
We redirect to Live View for a "single entry" experience.
"""

import streamlit as st

import utils


st.set_page_config(page_title="Airport Analytics", page_icon="✈️", layout="wide")
utils.apply_custom_css()

# If no installed airports exist, show guidance instead of redirecting.
airports = utils.get_available_airports()
if not airports:
    st.title("Airport Analytics")
    st.warning("No airport databases found (no `AIRPORT_XXX.PUBLIC.PROPERTIES_AIRPORT`).")
    st.write("Run the installer Streamlit app first, then come back here.")
    st.stop()

# Auto-redirect to Flight Tracker (requires Streamlit 1.26.0+)
# If st.switch_page is not available, users can manually select pages from the sidebar
try:
    st.switch_page("pages/1_Flight_Tracker.py")
except AttributeError:
    st.title("Airport Analytics Dashboard")
    st.info("👈 Select a page from the sidebar to begin exploring airport analytics.")
    st.markdown("""
    ### Available Pages:
    - **Flight Tracker**: Historical flight positions and playback
    - **Ground Activity**: Aircraft movements and taxi patterns
    - **Runway Crossings**: Safety analysis of runway crossings
    - **Traffic Analysis**: Flight volume trends and patterns
    - **Gate Analysis**: Gate utilization and dwell times
    - **Monitoring**: System health and data pipeline status
    - **Performance**: Query performance metrics
    """)


