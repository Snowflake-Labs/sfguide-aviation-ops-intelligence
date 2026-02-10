"""
Display Constants for Aviation Ops Intelligence Dashboard
Centralized strings for charts, labels, descriptions, and operational semantics.
This file enables Cortex Code to reason about and modify display semantics programmatically.
"""

# Chart Titles
CHART_TITLES = {
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

# Chart Descriptions/Captions
CHART_CAPTIONS = {
    'aircraft_on_ground_by_hour': 'Shows the sum of aircraft present during each hour',
    'runway_crossings': 'Detects aircraft crossing the runway while taxiing on the ground (wheels-on-ground only). Filters out takeoffs, landings, and airborne traffic using: max speed ≤45 kts, time on runway ≤120 sec, and straight-line distance ≤220m.',
    'activity_heatmap': 'Color intensity shows aircraft count: darker blue = more aircraft',
    'crossing_heatmap': 'Color intensity shows crossing count: darker blue = more crossings',
    'gate_heatmap': 'Color intensity shows total dwell time in minutes: darker blue = more time spent at gate',
    'hexagon_dual_encoding': 'Bar height and color represent the same metric.',
    'color_legend_intensity': 'Teal (low) → Yellow (medium) → Red (high)',
}

# Metric Type Labels
METRIC_LABELS = {
    'distinct_aircraft_count': 'Distinct Aircraft Count',
    'total_time_spent_minutes': 'Total Time Spent (minutes)',
    'aircraft_count': 'Aircraft Count',
    'crossings': 'Crossings',
    'dwell_time_minutes': 'Dwell Time (min)',
}

# Operational Tags
OPERATIONAL_TAGS = {
    'level2_relevant': '🏷️ **Level 2 relevant** — This metric is operationally sensitive for slot-controlled airports',
    'gate_dwell_level2': '🏷️ **Level 2 relevant** — Gate dwell time impacts slot coordination and capacity management',
}

# Standardized Vocabulary
VOCABULARY = {
    'on_ground_operations': 'on-ground operations',
    'arrivals': 'arrivals',
    'departures': 'departures',
    'aircraft_on_ground': 'aircraft on ground',
    'wheels_on_ground': 'wheels-on-ground only',
}

# Color Scheme Documentation
COLOR_SCHEMES = {
    'intensity_gradient': {
        'low_rgb': (79, 195, 247),
        'medium_rgb': (255, 193, 7),
        'high_rgb': (255, 87, 34),
        'extreme_rgb': (211, 47, 47),
        'description': 'Aviation-standard intensity gradient: Teal (low) → Yellow (medium) → Orange (high) → Red (extreme)',
    },
    'plotly_intensity': {
        'colorscale': [[0, '#4FC3F7'], [0.5, '#FFC107'], [1, '#D32F2F']],
        'description': 'Custom Plotly colorscale: Teal → Yellow → Red for operational intensity',
    }
}

# Help Text
HELP_TEXT = {
    'metric_selector': 'Distinct Aircraft Count: Count unique aircraft | Total Time Spent (minutes): Number of datapoints (proxy for time in location)',
    'h3_resolution': 'Higher resolution for detailed airport activity analysis. 12 = larger hexagons, 15 = smaller hexagons',
    'visualization_type': 'Choose how to visualize traffic density',
}
