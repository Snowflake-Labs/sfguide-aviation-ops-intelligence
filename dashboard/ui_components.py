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
        index=1,  # Default to Daily Average
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


def render_vehicle_type_filter(key_prefix="", sidebar=False, default_all=True):
    """
    Render hierarchical vehicle type filter with collapsible sections.
    
    Args:
        key_prefix: Unique prefix for widget keys
        sidebar: Whether to render in sidebar
        default_all: Default state for checkboxes
        
    Returns:
        dict: {
            'aircraft_all': bool,
            'aircraft_categories': list of selected aircraft types,
            'ground_all': bool,
            'ground_categories': list of selected ground types,
            'sql_filter': str (ready-to-use SQL WHERE clause)
        }
    """
    container = st.sidebar if sidebar else st
    
    container.markdown("**🔹 Vehicle Type Filter**")
    
    # =================================================================
    # AIRCRAFT SECTION
    # =================================================================
    aircraft_col1, aircraft_col2 = container.columns([3, 1])
    with aircraft_col1:
        container.markdown("**✈️ AIRCRAFT**")
    with aircraft_col2:
        aircraft_all = st.checkbox(
            "All", 
            value=default_all,
            key=f"{key_prefix}_aircraft_all",
            help="Select/deselect all aircraft types"
        )
    
    # Detailed aircraft categories (collapsible)
    with container.expander("🔽 Detailed Aircraft Categories", expanded=False):
        ac_col1, ac_col2 = st.columns(2)
        
        with ac_col1:
            heavy = st.checkbox(
                "Heavy (A380, B777)",
                value=aircraft_all,
                key=f"{key_prefix}_heavy",
                disabled=aircraft_all,
                help="14.55% - Wide-body jets"
            )
            medium = st.checkbox(
                "Medium (B737, A320)",
                value=aircraft_all,
                key=f"{key_prefix}_medium",
                disabled=aircraft_all,
                help="31.39% - Standard jets"
            )
            large = st.checkbox(
                "Large (A321, B38M)",
                value=aircraft_all,
                key=f"{key_prefix}_large",
                disabled=aircraft_all,
                help="9.24% - Narrow-body jets"
            )
            
        with ac_col2:
            small = st.checkbox(
                "Small (DHC-8, SF34)",
                value=aircraft_all,
                key=f"{key_prefix}_small",
                disabled=aircraft_all,
                help="12.33% - Regional turboprops"
            )
            light = st.checkbox(
                "Light (Cessna, Piper)",
                value=aircraft_all,
                key=f"{key_prefix}_light",
                disabled=aircraft_all,
                help="11.36% - General aviation"
            )
            helicopter = st.checkbox(
                "Helicopters",
                value=aircraft_all,
                key=f"{key_prefix}_helicopter",
                disabled=aircraft_all,
                help="5.21% - Rotorcraft"
            )
    
    # Build aircraft categories list
    aircraft_categories = []
    if aircraft_all or heavy:
        aircraft_categories.append('HEAVY_AIRCRAFT')
    if aircraft_all or medium:
        aircraft_categories.append('MEDIUM_AIRCRAFT')
    if aircraft_all or large:
        aircraft_categories.append('LARGE_AIRLINER')
    if aircraft_all or small:
        aircraft_categories.append('SMALL_COMMUTER')
    if aircraft_all or light:
        aircraft_categories.append('LIGHT_AIRCRAFT')
    if aircraft_all or helicopter:
        aircraft_categories.append('HELICOPTER')
    if aircraft_all:
        # Include minor categories only when "all" selected
        aircraft_categories.extend([
            'HIGH_PERFORMANCE_MILITARY',
            'ULTRALIGHT_EXPERIMENTAL'
        ])
    
    container.divider()
    
    # =================================================================
    # GROUND OPERATIONS SECTION
    # =================================================================
    ground_col1, ground_col2 = container.columns([3, 1])
    with ground_col1:
        container.markdown("**🚗 GROUND OPERATIONS**")
    with ground_col2:
        ground_all = st.checkbox(
            "All",
            value=default_all,
            key=f"{key_prefix}_ground_all",
            help="Select/deselect all ground types"
        )
    
    # Detailed ground categories (collapsible)
    with container.expander("🔽 Detailed Ground Categories", expanded=False):
        gr_col1, gr_col2 = st.columns(2)
        
        with gr_col1:
            towers = st.checkbox(
                "🗼 Towers",
                value=ground_all,
                key=f"{key_prefix}_towers",
                disabled=ground_all,
                help="5.04% - Tower vehicles (TWR)"
            )
            service = st.checkbox(
                "🚗 Service Vehicles",
                value=ground_all,
                key=f"{key_prefix}_service",
                disabled=ground_all,
                help="1.96% - Airport service equipment"
            )
            
        with gr_col2:
            ground_vehicles = st.checkbox(
                "🚜 Ground Vehicles",
                value=ground_all,
                key=f"{key_prefix}_ground_vehicles",
                disabled=ground_all,
                help="7.49% - Unidentified ground equipment"
            )
            light_surface = st.checkbox(
                "🚑 Light Surface",
                value=ground_all,
                key=f"{key_prefix}_light_surface",
                disabled=ground_all,
                help="0.14% - Emergency vehicles"
            )
    
    # Build ground categories list
    ground_categories = []
    if ground_all or towers:
        ground_categories.append('TOWER')
    if ground_all or service:
        ground_categories.append('SERVICE_VEHICLE')
    if ground_all or ground_vehicles:
        ground_categories.append('GROUND_VEHICLE')
    if ground_all or light_surface:
        ground_categories.append('LIGHT_SURFACE_VEHICLE')
    if ground_all:
        # Include minor categories when "all" selected
        ground_categories.extend(['UNKNOWN_SURFACE'])
    
    # Build SQL filter
    all_selected = aircraft_categories + ground_categories
    
    if not all_selected:
        # Nothing selected = show nothing
        sql_filter = "VEHICLE_CATEGORY = 'NONE'"
    else:
        quoted_types = [f"'{t}'" for t in all_selected]
        sql_filter = f"VEHICLE_CATEGORY IN ({','.join(quoted_types)})"
    
    # Add summary
    total_selected = len(all_selected)
    if total_selected == 0:
        container.caption("⚠️ No vehicle types selected")
    elif aircraft_all and ground_all:
        container.caption("✅ All vehicle types selected")
    else:
        container.caption(f"📊 {total_selected} vehicle types selected")
    
    return {
        'aircraft_all': aircraft_all,
        'aircraft_categories': aircraft_categories,
        'ground_all': ground_all,
        'ground_categories': ground_categories,
        'sql_filter': sql_filter,
        'selected_types': all_selected
    }

