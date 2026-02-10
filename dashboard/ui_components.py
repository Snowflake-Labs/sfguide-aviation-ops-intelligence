"""
Reusable UI components for the Aviation Operations Dashboard
"""

import streamlit as st
from datetime import datetime, timedelta
import utils
from config import core, ui, Metrics, Aggregation, Labels, Defaults


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


def render_airport_selector(sidebar=True):
    """
    Render the airport selector dropdown.
    Call this at the top of each page that needs database selection.
    
    Args:
        sidebar: If True, render in sidebar. If False, render in main content.
    
    Returns:
        The selected database name.
    """
    airports = utils.get_available_airports()
    
    if not airports:
        st.warning("No airport databases found.")
        return None
    
    # Use the database name as the widget value to avoid manual rerun loops.
    options = [a["database"] for a in airports]

    # Ensure selected_database is initialized and valid
    if st.session_state.get("selected_database") not in set(options):
        st.session_state["selected_database"] = options[0]

    container = st.sidebar if sidebar else st
    prev_db = st.session_state.get("_prev_selected_database")
    selected_db = container.selectbox(
        "Select Airport",
        options=options,
        index=options.index(st.session_state["selected_database"]),
        key="selected_database",
        format_func=lambda db_name: next(
            (f"{a['airport_name']} ({a['iata_code']})" for a in airports if a["database"] == db_name),
            db_name,
        ),
    )

    # Guardrail: Streamlit caches are global to the app process and do NOT automatically
    # incorporate session_state. If the selected DB changes, cached query results from
    # the previously selected airport can "bleed" into the UI. Clear caches on change.
    if prev_db != selected_db:
        st.session_state["_prev_selected_database"] = selected_db
        try:
            st.cache_data.clear()
        except Exception:
            pass
        try:
            st.cache_resource.clear()
        except Exception:
            pass

    return selected_db


def render_map_layers_selector(session, db_prefix: str, sidebar: bool = True,
                               default_preset: str = "none", key_prefix: str = "infra"):
    """
    Render infrastructure layer selector with presets and custom multiselect.
    
    Args:
        session: Snowflake session
        db_prefix: Database prefix (e.g., 'AIRPORT_YVR.PUBLIC')
        sidebar: If True, render in sidebar
        default_preset: One of 'none', 'airport_ops', 'all', 'custom'
        key_prefix: Prefix for widget keys to avoid conflicts between pages
    
    Returns:
        dict with keys:
            - 'layers': List of selected layer types (strings)
            - 'show_tags': Boolean indicating if tags should be displayed in tooltips
    """
    container = st.sidebar if sidebar else st
    
    # Get available types
    types_df = utils.get_available_infrastructure_types(session, db_prefix)
    
    if types_df.empty:
        container.info("No infrastructure data available.")
        return {'layers': [], 'show_tags': False}
    
    # Separate aeroway (aviation) vs other types
    aeroway_types = types_df[types_df['IS_AEROWAY'] == True].copy()
    other_types = types_df[types_df['IS_AEROWAY'] == False].copy()
    
    # Build options with counts
    def format_option(row):
        return f"{row['LAYER_TYPE']} ({int(row['OBJECT_COUNT'])})"
    
    aeroway_options = {format_option(row): row['LAYER_TYPE'] for _, row in aeroway_types.iterrows()}
    other_options = {format_option(row): row['LAYER_TYPE'] for _, row in other_types.iterrows()}
    
    all_layer_types = set(types_df['LAYER_TYPE'].tolist())
    airport_ops_available = all_layer_types & utils.AIRPORT_OPS_TYPES
    
    # Preset selector
    container.markdown("**Map Layers**")
    
    preset_options = ["None", "Airport Ops", "All", "Custom"]
    preset_index = {"none": 0, "airport_ops": 1, "all": 2, "custom": 3}.get(default_preset, 0)
    
    preset = container.radio(
        "Map Layers",
        options=preset_options,
        index=preset_index,
        key=f"{key_prefix}_preset",
        label_visibility="collapsed"
    )
    
    selected_layers = []
    
    if preset == "None":
        selected_layers = []
    
    elif preset == "Airport Ops":
        selected_layers = list(airport_ops_available)
        if selected_layers:
            container.caption(f"Showing: {', '.join(sorted(selected_layers))}")
    
    elif preset == "All":
        selected_layers = list(all_layer_types)
        container.caption(f"{len(selected_layers)} layer types selected")
    
    else:  # Custom
        selected_aeroway = []
        selected_other = []
        
        if aeroway_options:
            default_aeroway = [k for k, v in aeroway_options.items() if v in airport_ops_available]
            selected_aeroway_labels = container.multiselect(
                "Aviation Infrastructure",
                options=list(aeroway_options.keys()),
                default=default_aeroway,
                key=f"{key_prefix}_aeroway"
            )
            selected_aeroway = [aeroway_options[lbl] for lbl in selected_aeroway_labels]
        
        if other_options:
            selected_other_labels = container.multiselect(
                "Other Features",
                options=list(other_options.keys()),
                default=[],
                key=f"{key_prefix}_other"
            )
            selected_other = [other_options[lbl] for lbl in selected_other_labels]
        
        selected_layers = selected_aeroway + selected_other
    
    # Always set show_tags to False (removed checkbox)
    show_tags = False
    
    return {'layers': selected_layers, 'show_tags': show_tags}


def render_aggregation_selector(key_prefix="", sidebar=True):
    """
    Render standardized aggregation type selector.
    
    Args:
        key_prefix: Unique prefix for widget key
        sidebar: If True, render in sidebar
    
    Returns:
        str: 'sum' or 'daily_average'
    """
    container = st.sidebar if sidebar else st
    return container.radio(
        "Aggregation:",
        options=[Aggregation.SUM, Aggregation.DAILY_AVG],
        format_func=lambda x: Labels.AGG_SUM if x == Aggregation.SUM else Labels.AGG_DAILY_AVG,
        index=0,
        key=f"{key_prefix}_aggregation"
    )


def render_metric_selector(key_prefix="", sidebar=True):
    """
    Render standardized display metric selector.
    
    Args:
        key_prefix: Unique prefix for widget key
        sidebar: If True, render in sidebar
    
    Returns:
        str: 'flight_count' or 'total_duration'
    """
    container = st.sidebar if sidebar else st
    return container.radio(
        "Display metric:",
        options=[Metrics.FLIGHT_COUNT, Metrics.DURATION],
        format_func=lambda x: Labels.METRIC_FLIGHT_COUNT if x == Metrics.FLIGHT_COUNT else Labels.METRIC_DURATION,
        index=1,  # Default to Duration (min)
        key=f"{key_prefix}_metric_selector"
    )


def render_hexagon_size_selector(key_prefix="", sidebar=True):
    """
    Render hexagon size selector with mapping to H3 resolution.
    
    Args:
        key_prefix: Unique prefix for widget key
        sidebar: If True, render in sidebar
    
    Returns:
        int: H3 resolution (12, 13, or 14)
    """
    container = st.sidebar if sidebar else st
    size_label = container.selectbox(
        "Hexagon size",
        options=list(core.HEXAGON_SIZES.keys()),
        index=list(core.HEXAGON_SIZES.keys()).index(Defaults.HEXAGON_SIZE),
        key=f"{key_prefix}_hexagon_size",
        help=ui.Content.HELP_TEXT['hexagon_size']
    )
    return core.HEXAGON_SIZES[size_label]


def render_percentile_filter(key_prefix="", sidebar=True):
    """
    Render percentile threshold slider for hotzone filtering.
    
    Args:
        key_prefix: Unique prefix for widget key
        sidebar: If True, render in sidebar
    
    Returns:
        int: Percentile threshold (0-99)
    """
    container = st.sidebar if sidebar else st
    return container.slider(
        "Percentile threshold:",
        min_value=core.Thresholds.PERCENTILE_MIN,
        max_value=core.Thresholds.PERCENTILE_MAX,
        value=Defaults.PERCENTILE,
        step=core.Thresholds.PERCENTILE_STEP,
        key=f"{key_prefix}_percentile",
        help=ui.Content.HELP_TEXT['percentile_threshold']
    )


def render_kpi_metrics(metrics_data, aggregation_type="sum"):
    """
    Render standardized KPI metrics with aggregation-aware labels.
    
    Args:
        metrics_data: Dict with keys like {
            'crossings': value,
            'flights': value,
            'avg_duration_s': value,
            'total_duration_min': value
        }
        aggregation_type: 'sum' or 'daily_average'
    
    Returns:
        None (renders directly to Streamlit)
    """
    labels = utils.get_aggregation_labels(aggregation_type)
    
    col1, col2, col3, col4 = st.columns(4)
    
    with col1:
        st.metric(
            labels['crossings'],
            f"{int(metrics_data.get('crossings', 0)):,}"
        )
    with col2:
        st.metric(
            labels['flights'],
            f"{int(metrics_data.get('flights', 0)):,}"
        )
    with col3:
        st.metric(
            "Avg Duration",
            f"{metrics_data.get('avg_duration_s', 0):.1f} sec"
        )
    with col4:
        st.metric(
            labels['duration'],
            f"{int(metrics_data.get('total_duration_min', 0)):,} min"
        )

