"""
Ground Activity Page - Geographic traffic analysis and airport-centric views
Visualize traffic density, ground activity, and geographic patterns
"""

import streamlit as st
import pandas as pd
import pydeck as pdk
from snowflake.snowpark.context import get_active_session
from datetime import datetime, timedelta
import sys
import json
sys.path.append('..')
import utils
import colors
import ui_components

# Page configuration
st.set_page_config(
    page_title="Ground Activity",
    page_icon="🗺️",
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
with st.sidebar:
    selected_db = ui_components.render_airport_selector(sidebar=True)
if not selected_db:
    st.warning("No airport databases found yet. Run the installer first.")
    st.stop()
st.title("🗺️ Ground Activity & Geographic Analysis")
st.markdown("Visualize air traffic density, airport zones, and geographic patterns")
utils.render_timezone_caption(session, db_prefix)

# Sidebar controls
sample_size = None
with st.sidebar:
    
    # Get date range using reusable component
    min_date, max_date = utils.get_date_range(session)
    selected_start_date, selected_end_date = ui_components.render_date_range_picker(
        min_date,
        max_date,
        key_prefix="airport_activity",
        default_days_back=7
    )
    
    # Set time to full day (00:00 to 23:59)
    time_start = datetime.strptime("00:00", "%H:%M").time()
    time_end = datetime.strptime("23:59", "%H:%M").time()
    
    # Infrastructure Layers
    infra_selection = ui_components.render_map_layers_selector(
        session, db_prefix, 
        sidebar=True, 
        default_preset="all",
        key_prefix="airport_activity"
    )
    selected_infra_layers = infra_selection['layers']
    show_infra_tags = infra_selection['show_tags']
    
    st.divider()
    
    # Map controls
    h3_resolution = st.selectbox(
        "H3 Resolution",
        options=[12, 13, 14, 15],
        index=1,
        help="Higher resolution for detailed airport activity analysis. 12 = larger hexagons, 15 = smaller hexagons"
    )
    
    st.divider()
    
    # Display metric
    metric_type_selection = st.radio(
        "Display metric:",
        options=["flight_count", "total_duration"],
        format_func=lambda x: "Flight Count" if x == "flight_count" else "Duration (min)",
        index=0,
        key="airport_activity_metric_selector"
    )
    
    # Aggregation
    aggregation_type = st.radio(
        "Aggregation:",
        options=["sum", "daily_average"],
        format_func=lambda x: "Sum for the selected period" if x == "sum" else "Daily Average",
        index=0,
        key="airport_activity_aggregation"
    )
    
    # Percentile threshold
    percentile_threshold = st.slider(
        "Percentile threshold:",
        min_value=0,
        max_value=99,
        value=0,
        step=5,
        key="hotzone_percentile",
        help="Show only hexagons above this percentile (0 = show all)"
    )
    
    # Map the selection to the format expected by the rest of the code
    metric_type = "Distinct Aircraft Count" if metric_type_selection == "flight_count" else "Total Time Spent (minutes)"

# Altitude filter removed; analyze all data
alt_min, alt_max = 0, 100000

# Query function
@st.cache_data(ttl=300)
def get_schedule_for_flights(_session, date, flight_numbers):
    """
    Fetch origin, destination, and seats for a set of flight numbers on the given date.
    flight_numbers should be a list of numeric strings (e.g., '1234').
    """
    if not flight_numbers:
        return pd.DataFrame(columns=['FLIGHT_NUMBER','ORIGIN_AIRPORT','DESTINATION_AIRPORT','SEATS'])
    # Deduplicate and build IN clause
    nums = sorted({str(n) for n in flight_numbers if str(n)})
    in_clause = ",".join([f"'{n}'" for n in nums])
    query = f"""
    SELECT 
        FLIGHT_NUMBER,
        DEPARTURE_AIRPORT AS ORIGIN_AIRPORT,
        ARRIVAL_AIRPORT AS DESTINATION_AIRPORT,
        NULL::FLOAT AS SEATS
    FROM {db_prefix}.FLIGHT_SCHEDULE
    WHERE FLIGHT_DATE = '{date}'::DATE
      AND FLIGHT_NUMBER IN ({in_clause})
    """
    try:
        return _session.sql(query).to_pandas()
    except Exception:
        return pd.DataFrame(columns=['FLIGHT_NUMBER','ORIGIN_AIRPORT','DESTINATION_AIRPORT','SEATS'])

@st.cache_data(ttl=300)
def get_h3_hexagon_data(_session, start_dt, end_dt, h3_resolution, metric_type, aggregation_type, sample_percent: int = 10, max_cells: int = 4000):
    """
    Get all traffic data aggregated by H3 hexagons using Snowflake's native H3 functions
    Returns H3 cell strings with BOTH distinct flight counts AND observation counts
    Analyzes all datapoints for the given time interval - no limits
    metric_type: 'Distinct Aircraft Count' or 'Total Time Spent (minutes)' - determines which metric is used for visualization (color/height)
    aggregation_type: 'sum' or 'daily_average' - determines if values are summed or averaged by day
    """
    # Determine which metric to use for sorting/limiting and visualization
    if metric_type == "Distinct Aircraft Count":
        order_by_expr = "distinct_aircraft_count"
    else:  # Time Spent
        order_by_expr = "observation_count"
    
    # Calculate number of days in the date range for daily average
    from datetime import datetime
    start_date = datetime.strptime(start_dt.split()[0], '%Y-%m-%d')
    end_date = datetime.strptime(end_dt.split()[0], '%Y-%m-%d')
    num_days = (end_date - start_date).days + 1
    
    # Determine aggregation divisor
    if aggregation_type == "daily_average":
        divisor = max(1, num_days)  # Avoid division by zero
    else:
        divisor = 1
    
    bbox = utils.get_airport_bbox(session)
    local_ts_expr = utils.get_airport_local_ts_sql(db_prefix, "TIMESTAMP")
    query = f"""
    WITH bbox AS (
        SELECT {float(bbox["min_lat"])}::FLOAT AS min_lat,
               {float(bbox["max_lat"])}::FLOAT AS max_lat,
               {float(bbox["min_lon"])}::FLOAT AS min_lon,
               {float(bbox["max_lon"])}::FLOAT AS max_lon
    ),
    points_with_h3 AS (
        SELECT 
            ST_Y(LOCATION) AS LAT,
            ST_X(LOCATION) AS LON,
            FLIGHT,
            LOCATION as point_geom,
            H3_POINT_TO_CELL_STRING(LOCATION, {h3_resolution}) as h3_cell
        FROM {db_prefix}.ADSB_DATA_LOCAL SAMPLE BERNOULLI ({int(sample_percent)})
        CROSS JOIN bbox b
        WHERE {local_ts_expr} BETWEEN '{start_dt}'::TIMESTAMP AND '{end_dt}'::TIMESTAMP
            AND LOCATION IS NOT NULL
            AND FLIGHT IS NOT NULL
            AND ST_Y(LOCATION) BETWEEN b.min_lat AND b.max_lat
            AND ST_X(LOCATION) BETWEEN b.min_lon AND b.max_lon
    ),
    h3_with_bounds AS (
        SELECT 
            h3_cell,
            ROUND(COUNT(DISTINCT FLIGHT) / {divisor}) as distinct_aircraft_count,
            ROUND(COUNT(*) / {divisor}) as observation_count,
            ST_COLLECT(point_geom) as collected_points
        FROM points_with_h3
        WHERE h3_cell IS NOT NULL
        GROUP BY h3_cell
    )
    SELECT 
        h3_cell,
        distinct_aircraft_count,
        observation_count,
        ST_XMIN(collected_points) as min_lon,
        ST_XMAX(collected_points) as max_lon,
        ST_YMIN(collected_points) as min_lat,
        ST_YMAX(collected_points) as max_lat
    FROM h3_with_bounds
    ORDER BY {order_by_expr} DESC
    LIMIT {int(max_cells)}
    """
    return _session.sql(query).to_pandas()

# Density stats removed

# Always use Hexagon visualization
viz_type = "Hexagon"
# Always show 3D elevation
hex_elevation = True
# Always use 100% of points
hex_sample_pct = 100

# Load data
with st.spinner("Loading geographic data..."):
    start_datetime = f"{selected_start_date} {time_start.strftime('%H:%M:%S')}"
    end_datetime = f"{selected_end_date} {time_end.strftime('%H:%M:%S')}"
    bbox = utils.get_airport_bbox(session)
    min_lat = float(bbox["min_lat"]); max_lat = float(bbox["max_lat"])
    min_lon = float(bbox["min_lon"]); max_lon = float(bbox["max_lon"])
    
    # Always use H3 aggregated data for hexagon visualization
    h3_data = get_h3_hexagon_data(
        session,
        start_datetime,
        end_datetime,
        h3_resolution,
        metric_type,
        aggregation_type,
        sample_percent=int(hex_sample_pct),
        max_cells=int(st.session_state.get('hex_max_cells', 4000))
    )
    
    # Apply percentile filter if enabled
    if percentile_threshold > 0 and h3_data is not None and not h3_data.empty:
        # Determine which column to use for filtering based on selected metric
        if metric_type == "Distinct Aircraft Count":
            filter_column = 'DISTINCT_AIRCRAFT_COUNT'
        else:  # Total Time Spent
            filter_column = 'OBSERVATION_COUNT'
        
        # Calculate percentile threshold value
        threshold_value = h3_data[filter_column].quantile(percentile_threshold / 100.0)
        
        # Filter to keep only hexagons above the percentile
        h3_data = h3_data[h3_data[filter_column] >= threshold_value]


# Geographic Coverage Statistics removed

# Main map visualization
has_data = (h3_data is not None and not h3_data.empty)

if has_data:
    # Determine metric labels for dual encoding based on aggregation type
    if aggregation_type == "daily_average":
        prefix = "Avg daily"
    else:
        prefix = "Total"
    
    if metric_type == "Distinct Aircraft Count":
        height_label = f"{prefix} Aircraft Count" if aggregation_type == "daily_average" else "Distinct Aircraft Count"
        color_label = f"{prefix} dwell time (minutes)"
    else:
        height_label = f"{prefix} dwell time (minutes)"
        color_label = f"{prefix} Aircraft Count" if aggregation_type == "daily_average" else "Distinct Aircraft Count"
    
    # Add legend explanation for dual encoding (always show 3D)
    caption_text = f"**Dual Encoding:** Height = {height_label} | Color (Teal→Yellow→Red): {color_label}. Teal=low, Yellow=medium, Red=high. Hover for exact values."
    if percentile_threshold > 0:
        caption_text += f" | **Hotzone Filter:** Showing only top {100 - percentile_threshold}% of hexagons by {metric_type_selection.replace('_', ' ')}."
    st.caption(caption_text)
    
    # Create layers
    layers = []
    
    # Infrastructure layers (componentized rendering)
    infra_df = utils.get_infrastructure_layers(session, db_prefix, selected_infra_layers, include_tags=show_infra_tags) if selected_infra_layers else pd.DataFrame()
    layers.extend(utils.create_infrastructure_pydeck_layers(infra_df, show_tags=show_infra_tags))
    
    # Hexagon visualization with dual encoding
    # Dual encoding: Height = selected metric, Color = secondary metric
    if metric_type == "Distinct Aircraft Count":
        # Height shows aircraft count, color shows dwell time
        h3_data['HEIGHT_METRIC'] = h3_data['DISTINCT_AIRCRAFT_COUNT']
        h3_data['COLOR_METRIC'] = h3_data['OBSERVATION_COUNT']
    else:  # Total Time Spent
        # Height shows dwell time, color shows aircraft count
        h3_data['HEIGHT_METRIC'] = h3_data['OBSERVATION_COUNT']
        h3_data['COLOR_METRIC'] = h3_data['DISTINCT_AIRCRAFT_COUNT']
    
    # Use PyDeck's H3HexagonLayer with H3 string cell IDs
    # Elevation based on HEIGHT_METRIC
    max_height = h3_data['HEIGHT_METRIC'].max()
    max_height = max_height if pd.notna(max_height) and max_height > 0 else 1
    
    # Always use elevation for 3D
    h3_data['elevation'] = (h3_data['HEIGHT_METRIC'] / max_height * 500)
    
    # Color gradient based on COLOR_METRIC (secondary metric)
    max_color = h3_data['COLOR_METRIC'].max()
    max_color = max_color if pd.notna(max_color) and max_color > 0 else 1
    
    # Aviation-standard intensity gradient: Teal -> Yellow -> Red
    def to_color(val):
        t = float(val) / float(max_color)
        t = 0.0 if pd.isna(t) else max(0.0, min(1.0, t))
        return colors.get_intensity_color_3point(t)
    
    h3_data['color'] = h3_data['COLOR_METRIC'].apply(to_color)
    
    # Add tooltip showing BOTH metrics with proper formatting based on aggregation
    def create_tooltip(row):
        dwell_time = row['OBSERVATION_COUNT'] if pd.notna(row['OBSERVATION_COUNT']) else 0
        aircraft_count = row['DISTINCT_AIRCRAFT_COUNT'] if pd.notna(row['DISTINCT_AIRCRAFT_COUNT']) else 0
        
        if aggregation_type == "daily_average":
            # Show as integer for daily averages (rounded in SQL)
            return f"<b>Avg daily dwell time (minutes):</b> {int(dwell_time)}<br/><b>Avg daily Aircraft Count:</b> {int(aircraft_count)}"
        else:
            # Show as integer for sum
            return f"<b>Total dwell time (minutes):</b> {int(dwell_time)}<br/><b>Distinct Aircraft Count:</b> {int(aircraft_count)}"
    
    h3_data['tooltip'] = h3_data.apply(create_tooltip, axis=1)
    
    # Use H3HexagonLayer which works directly with H3 string cell IDs
    layer = pdk.Layer(
        'H3HexagonLayer',
        data=h3_data,
        get_hexagon='H3_CELL',
        get_fill_color='color',
        get_elevation='elevation',
        elevation_scale=1,
        extruded=True,  # Always 3D
        pickable=True,
        auto_highlight=True,
        get_line_color=[255, 255, 255, 100],
        line_width_min_pixels=1
    )
    layers.append(layer)
    
    # Default map bounds to airport polygon
    pitch = 50
    
    # View state: always use airport polygon bounds
    airport_bounds = utils.get_airport_default_view(session)
    view_state = pdk.ViewState(
        latitude=airport_bounds['latitude'],
        longitude=airport_bounds['longitude'],
        zoom=airport_bounds['zoom'],
        pitch=pitch,
        bearing=0
    )
    
    # Create deck with unified tooltip using {tooltip} column (all layers populate this)
    deck_tooltip = {"html": "{tooltip}", "style": {"backgroundColor": "steelblue", "color": "white"}}
    r = pdk.Deck(
        layers=layers,
        initial_view_state=view_state,
        map_style='light',
        tooltip=deck_tooltip
    )
    
    try:
        st.pydeck_chart(r, use_container_width=True, height=700, key="airport_activity")
    except Exception as e:
        if 'MessageSizeError' in str(e):
            # Reduce max cells and rerun
            curr_cells = int(st.session_state.get('hex_max_cells', 4000))
            new_cells = max(500, int(curr_cells * 0.8))
            if new_cells != curr_cells:
                st.session_state['hex_max_cells'] = new_cells
                st.experimental_rerun()
            else:
                st.error("MessageSizeError: Reduce filters or zoom to load less data.")
        else:
            raise

    # H3 analysis section removed

else:
    st.warning("⚠️ No data available for the selected filters. Try adjusting the date or time range.")

st.divider()

