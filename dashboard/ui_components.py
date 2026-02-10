"""
Reusable UI components for the Aviation Operations Dashboard
"""

import streamlit as st
from datetime import datetime, timedelta


def render_date_range_picker(min_date, max_date, key_prefix="", default_days_back=7):
    """
    Renders a standardized date range picker used across all dashboard pages.
    
    Args:
        min_date: Minimum selectable date
        max_date: Maximum selectable date
        key_prefix: Unique prefix for the widget key to avoid conflicts
        default_days_back: Number of days to go back for default start date
    
    Returns:
        tuple: (start_date, end_date) selected by the user
    """
    st.subheader("Date Range")
    
    # Calculate default date range
    if max_date:
        default_start = max_date - timedelta(days=default_days_back)
        default_end = max_date
    else:
        default_end = datetime.now().date()
        default_start = default_end - timedelta(days=default_days_back)
    
    # Render date input
    date_range = st.date_input(
        "Date Range",
        value=(default_start, default_end),
        key=f"{key_prefix}_date_range" if key_prefix else "date_range"
    )
    
    # Handle single date vs range
    if isinstance(date_range, tuple) and len(date_range) == 2:
        start_date, end_date = date_range
    else:
        start_date = end_date = date_range
    
    return start_date, end_date
