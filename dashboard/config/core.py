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

# =============================================================================
# AIRPORT CLASSIFICATION
# =============================================================================

class IATALevel:
    """IATA Level classification for airports (Schedule Coordination)"""
    LEVEL_1 = 1  # Adequate capacity
    LEVEL_2 = 2  # Schedule Facilitated (requires voluntary schedule coordination)
    LEVEL_3 = 3  # Fully Coordinated (slot allocation required)

# Airport IATA Level configuration (3-letter code -> level)
AIRPORT_IATA_LEVELS = {
    # Example airports by level
    # Level 2 - Schedule Facilitated
    'SAN': IATALevel.LEVEL_2,
    'YVR': IATALevel.LEVEL_2,
    'SJC': IATALevel.LEVEL_2,
    
    # Level 3 - Fully Coordinated (major hubs)
    'LHR': IATALevel.LEVEL_3,
    'JFK': IATALevel.LEVEL_3,
    'LAX': IATALevel.LEVEL_3,
    
    # Default to Level 1 for airports not listed
}

# Visualization defaults by IATA Level
class VisualizationDefaults:
    """Default visualization settings based on airport IATA level"""
    
    # Level 2 - Schedule Facilitated (hotspots-first approach)
    LEVEL_2 = {
        'hotspots_only': True,
        'percentile_threshold': 90,
        'elevation_scale': 60,
        'opacity': 0.8,
        'coverage': 0.8
    }
    
    # Non-Level 2 (Level 1 or 3, or unknown)
    DEFAULT = {
        'hotspots_only': False,
        'percentile_threshold': 75,
        'elevation_scale': 35,
        'opacity': 0.65,
        'coverage': 0.8
    }
