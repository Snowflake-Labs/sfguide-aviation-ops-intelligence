"""
User interface configuration: labels, titles, captions, formatting.
Everything visible to the user.
"""

# =============================================================================
# DISPLAY LABELS
# =============================================================================

class Labels:
    """User-facing text labels"""
    
    # Metrics
    METRIC_FLIGHT_COUNT = "Flight Count"
    METRIC_DURATION = "Duration (min)"
    METRIC_AIRCRAFT_COUNT = "Aircraft Count"
    METRIC_CROSSINGS = "Crossings"
    METRIC_DWELL_TIME = "Dwell Time (min)"
    
    # Aggregation
    AGG_SUM = "Sum"
    AGG_DAILY_AVG = "Daily Average"
    
    # Hexagon Sizes
    HEXAGON_SMALL = "Small"
    HEXAGON_MEDIUM = "Medium"
    HEXAGON_LARGE = "Large"
    
    # KPI Metrics
    KPI_TOTAL_CROSSINGS = "Total Crossings"
    KPI_AVG_DAILY_CROSSINGS = "Avg Daily Crossings"
    KPI_UNIQUE_FLIGHTS = "Unique Flights"
    KPI_AVG_DAILY_FLIGHTS = "Avg Daily Flights"
    KPI_TOTAL_DURATION = "Total Duration"
    KPI_AVG_DAILY_DURATION = "Avg Daily Duration"
    KPI_AVG_DURATION = "Avg Duration"

# =============================================================================
# CHART CONFIGURATION
# =============================================================================

class Charts:
    """Chart sizing, formatting, and styling configuration"""
    
    # Bar chart sizing - Horizontal
    BAR_HORIZONTAL_STEP = 20
    BAR_HORIZONTAL_SIZE = 15
    BAR_HORIZONTAL_LABEL_LIMIT = 200
    
    # Bar chart sizing - Vertical
    BAR_VERTICAL_STEP = 50
    BAR_VERTICAL_SIZE = 40
    
    # Axis configuration
    AXIS_LABEL_LIMIT_SHORT = 150
    AXIS_LABEL_LIMIT_MEDIUM = 200
    AXIS_LABEL_LIMIT_LONG = 300
    
    # Tooltip formatting strings
    TOOLTIP_FORMAT_INTEGER = ',.0f'
    TOOLTIP_FORMAT_DECIMAL_1 = ',.1f'
    TOOLTIP_FORMAT_DECIMAL_2 = ',.2f'
    TOOLTIP_FORMAT_PERCENT = '.1%'
    
    # Heatmap color schemes (Altair)
    HEATMAP_SCHEME = 'turbo'
    HEATMAP_SCHEME_TEALS = 'teals'
    HEATMAP_SCHEME_DIVERGING = 'redyellowgreen'
    HEATMAP_SCHEME_SEQUENTIAL = 'blues'
    
    # Map settings
    MAP_DEFAULT_HEIGHT = 700
    MAP_DEFAULT_PITCH = 50
    MAP_STYLE = 'light'

# =============================================================================
# CONTENT (Titles, Captions, Help Text)
# =============================================================================

class Content:
    """User-facing content strings"""
    
    # Page titles
    TITLES = {
        'aircraft_on_ground_by_hour': '🕐 Aircraft on Ground by Hour',
        'crossing_density_heatmap': '📍 Crossing Density Heatmap',
        'crossing_heatmap_dow_hour': '📅 Crossing Heatmap (Day of Week × Hour)',
        'activity_heatmap': '🔥 Activity Heatmap',
        'gate_usage_heatmap': '📊 Gate Usage Heatmap by Day of Week',
        'gate_utilization_dwell': '🧭 Gate Utilization by Gate (Dwell Minutes)',
        'gate_utilization_flights': '🧮 Gate Utilization by Gate (Number of Flights)',
        'traffic_trend': '📅 Traffic Trend',
        'traffic_by_hour': '🕐 Traffic by Hour of Day',
        'traffic_by_dow': '📆 Traffic by Day of Week',
        'top_airlines': '🏢 Top Airlines by Activity',
        'ground_activity': '🗺️ Ground Activity & Geographic Analysis',
        'runway_crossings': '🛤️ On-Ground Runway Crossings',
        'gate_analysis': '🛬 Gate Analysis',
    }
    
    # Chart captions/descriptions
    CAPTIONS = {
        'aircraft_on_ground_by_hour': 'Shows the sum of aircraft present during each hour',
        'runway_crossings': 'Detects aircraft crossing the runway while taxiing on the ground (wheels-on-ground only). Filters out takeoffs, landings, and airborne traffic using: max speed ≤45 kts, time on runway ≤120 sec, and straight-line distance ≤220m.',
        'activity_heatmap': 'Color intensity shows aircraft count: darker = more aircraft',
        'crossing_heatmap': 'Color intensity shows crossing count: darker = more crossings',
        'gate_heatmap': 'Color intensity shows total dwell time in minutes: darker = more time spent at gate',
        'hexagon_dual_encoding': 'Bar height and color represent the same metric.',
        'color_legend_intensity': 'Teal (low) → Yellow (medium) → Red (high)',
    }
    
    # Help text for UI controls
    HELP_TEXT = {
        'metric_selector': 'Distinct Aircraft Count: Count unique aircraft | Total Time Spent (minutes): Number of datapoints (proxy for time in location)',
        'hexagon_size': 'Size of hexagons for aggregation. Small = fine detail, Large = broader overview',
        'percentile_threshold': 'Show only hexagons above this percentile (0 = show all)',
        'aggregation': 'Sum: Total for selected period | Daily Average: Average per day',
        'h3_resolution_legacy': 'Higher resolution for detailed airport activity analysis. 12 = larger hexagons, 14 = smaller hexagons',
    }
    
    # Operational tags and badges
    OPERATIONAL_TAGS = {
        'level2_relevant': '🏷️ **IATA Level 2 relevant** — This metric is operationally sensitive for slot-controlled airports',
        'gate_dwell_level2': '🏷️ **IATA Level 2 relevant** — Gate dwell time impacts slot coordination and capacity management',
    }
    
    # Standardized vocabulary
    VOCABULARY = {
        'on_ground_operations': 'on-ground operations',
        'arrivals': 'arrivals',
        'departures': 'departures',
        'aircraft_on_ground': 'aircraft on ground',
        'wheels_on_ground': 'wheels-on-ground only',
    }

# =============================================================================
# LEGACY COMPATIBILITY DICTIONARIES
# =============================================================================
# These allow old code to continue working during migration

METRIC_LABELS = {
    "flight_count": Labels.METRIC_FLIGHT_COUNT,
    "total_duration": Labels.METRIC_DURATION,
    "aircraft_count": Labels.METRIC_AIRCRAFT_COUNT,
    "crossings": Labels.METRIC_CROSSINGS,
}

AGG_LABELS = {
    "sum": Labels.AGG_SUM,
    "daily_average": Labels.AGG_DAILY_AVG,
}

# Bar chart configuration (legacy format)
BAR_CONFIG = {
    'horizontal': {
        'step': Charts.BAR_HORIZONTAL_STEP,
        'size': Charts.BAR_HORIZONTAL_SIZE,
        'label_limit': Charts.BAR_HORIZONTAL_LABEL_LIMIT
    },
    'vertical': {
        'step': Charts.BAR_VERTICAL_STEP,
        'size': Charts.BAR_VERTICAL_SIZE,
    },
    'horizontal_compact': {
        'step': Charts.BAR_HORIZONTAL_STEP,
        'size': Charts.BAR_HORIZONTAL_SIZE,
        'label_limit': Charts.BAR_HORIZONTAL_LABEL_LIMIT
    },
    'horizontal_large': {
        'step': Charts.BAR_HORIZONTAL_STEP,
        'size': Charts.BAR_HORIZONTAL_SIZE,
        'label_limit': Charts.BAR_HORIZONTAL_LABEL_LIMIT
    }
}

# Heatmap colors (legacy format)
HEATMAP_COLORS = {
    'scheme': Charts.HEATMAP_SCHEME_TEALS,
    'diverging': Charts.HEATMAP_SCHEME_DIVERGING,
    'sequential': Charts.HEATMAP_SCHEME_SEQUENTIAL
}

# Axis configuration (legacy format)
AXIS_CONFIG = {
    'label_limit_short': Charts.AXIS_LABEL_LIMIT_SHORT,
    'label_limit_medium': Charts.AXIS_LABEL_LIMIT_MEDIUM,
    'label_limit_long': Charts.AXIS_LABEL_LIMIT_LONG
}

# Tooltip formatting (legacy format)
TOOLTIP_FORMAT = {
    'integer': Charts.TOOLTIP_FORMAT_INTEGER,
    'decimal_1': Charts.TOOLTIP_FORMAT_DECIMAL_1,
    'decimal_2': Charts.TOOLTIP_FORMAT_DECIMAL_2,
    'percent': Charts.TOOLTIP_FORMAT_PERCENT
}

# Chart titles and captions (legacy format)
CHART_TITLES = Content.TITLES
CHART_CAPTIONS = Content.CAPTIONS
