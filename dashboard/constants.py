"""
Constants used across the Aviation Operations Dashboard
"""

# H3 Resolution mapping
HEXAGON_SIZES = {
    "Small": 14,
    "Medium": 13,
    "Large": 12
}

# Metric type mappings
METRIC_FLIGHT_COUNT = "flight_count"
METRIC_DURATION = "total_duration"

# Metric display names
METRIC_LABELS = {
    "flight_count": "Flight Count",
    "total_duration": "Duration (min)"
}

# Aggregation types
AGG_SUM = "sum"
AGG_DAILY_AVG = "daily_average"

# Aggregation display names
AGG_LABELS = {
    "sum": "Sum",
    "daily_average": "Daily Average"
}

# Default values
DEFAULT_HEXAGON_SIZE = "Medium"
DEFAULT_AGGREGATION = AGG_SUM
DEFAULT_PERCENTILE = 0
DEFAULT_METRIC = METRIC_FLIGHT_COUNT

# Cache TTL (seconds)
CACHE_TTL_SECONDS = 600
