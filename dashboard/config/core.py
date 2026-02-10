"""
Core application configuration and constants.
Business logic, data processing, and technical settings.
"""

# =============================================================================
# DATA PROCESSING
# =============================================================================

# Cache settings
CACHE_TTL_SECONDS = 600

# Query limits
MAX_QUERY_ROWS = 10000
DEFAULT_SAMPLE_PERCENT = 100
MAX_H3_CELLS = 4000

# =============================================================================
# GEOSPATIAL (H3)
# =============================================================================

# H3 Resolution mapping (user-friendly labels to technical values)
HEXAGON_SIZES = {
    "Small": 14,
    "Medium": 13,
    "Large": 12
}

DEFAULT_HEXAGON_SIZE = "Medium"

# =============================================================================
# METRICS
# =============================================================================

class Metrics:
    """Metric type identifiers"""
    FLIGHT_COUNT = "flight_count"
    DURATION = "total_duration"
    AIRCRAFT_COUNT = "aircraft_count"
    CROSSINGS = "crossings"

# =============================================================================
# AGGREGATION
# =============================================================================

class Aggregation:
    """Aggregation type identifiers"""
    SUM = "sum"
    DAILY_AVG = "daily_average"

# =============================================================================
# DEFAULTS
# =============================================================================

class Defaults:
    """Default values for UI controls"""
    METRIC = Metrics.FLIGHT_COUNT
    AGGREGATION = Aggregation.SUM
    PERCENTILE = 0
    DAYS_BACK = 7
    HEXAGON_SIZE = "Medium"

# =============================================================================
# OPERATIONAL THRESHOLDS
# =============================================================================

class Thresholds:
    """Operational thresholds for filtering and classification"""
    # Runway crossing detection
    CROSSING_MAX_SPEED_KTS = 45
    CROSSING_MAX_DURATION_S = 120
    CROSSING_MAX_DISTANCE_M = 220
    
    # Altitude filters (feet)
    GROUND_MAX_ALTITUDE_FT = 100
    
    # Percentile ranges
    PERCENTILE_MIN = 0
    PERCENTILE_MAX = 99
    PERCENTILE_STEP = 5
