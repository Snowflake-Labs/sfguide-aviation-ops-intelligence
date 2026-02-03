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

st.switch_page("pages/0_Live_View.py")


