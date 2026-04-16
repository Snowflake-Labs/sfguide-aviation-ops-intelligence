"""
Unified configuration package for Aviation Operations Dashboard.

This package consolidates all configuration constants, replacing:
- constants.py (deprecated)
- chart_config.py (deprecated)  
- display_constants.py (deprecated)
- Portions of colors.py (deprecated)

New Structure:
- config.core: Business logic constants (cache, H3, metrics, thresholds)
- config.ui: Display constants (labels, titles, chart formatting)
- config.colors: Color definitions and utility functions

Usage Examples:

    # Modern imports (recommended)
    from config.core import Metrics, Aggregation, Defaults, CACHE_TTL_SECONDS
    from config.ui import Labels, Charts, Content
    from config.colors import RGB, Hex, get_intensity_color_3point
    
    # Access via classes (organized, IDE-friendly)
    if metric_type == Metrics.FLIGHT_COUNT:
        label = Labels.METRIC_FLIGHT_COUNT
    
    # Legacy imports (for backward compatibility during migration)
    from config import METRIC_LABELS, AGG_LABELS, BAR_CONFIG, COLORS
    from config import INTENSITY_GRADIENT, get_intensity_color_3point
    
    # Access via dictionaries (old style, still works)
    label = METRIC_LABELS["flight_count"]
    color = COLORS["blue"]

Migration Path:
    Phase 1: Import from config with legacy compatibility
    Phase 2: Gradually update to use class-based access
    Phase 3: Remove legacy dictionary usage
    Phase 4: Deprecate old files (constants.py, chart_config.py, etc.)
"""

# =============================================================================
# RE-EXPORT CORE CONSTANTS
# =============================================================================

from .core import (
    # Data processing
    CACHE_TTL_SECONDS,
    MAX_QUERY_ROWS,
    DEFAULT_SAMPLE_PERCENT,
    MAX_H3_CELLS,
    
    # Geospatial
    HEXAGON_SIZES,
    DEFAULT_HEXAGON_SIZE,
    
    # Classes
    Metrics,
    Aggregation,
    Defaults,
    Thresholds,
)

# =============================================================================
# RE-EXPORT UI CONSTANTS
# =============================================================================

from .ui import (
    # Classes
    Labels,
    Charts,
    Content,
    
    # Legacy dictionaries (for backward compatibility)
    METRIC_LABELS,
    AGG_LABELS,
    BAR_CONFIG,
    HEATMAP_COLORS,
    AXIS_CONFIG,
    TOOLTIP_FORMAT,
    CHART_TITLES,
    CHART_CAPTIONS,
)

# =============================================================================
# RE-EXPORT COLOR CONSTANTS AND FUNCTIONS
# =============================================================================

from .colors import (
    # Classes
    RGB,
    Hex,
    RGBA,
    
    # Functions
    get_intensity_color_3point,
    get_intensity_color_2point,
    rgb_to_hex,
    hex_to_rgb,
    
    # Arrays and scales
    INTENSITY_COLOR_RANGE,
    PLOTLY_INTENSITY_SCALE,
    
    # Legacy dictionaries (for backward compatibility)
    COLORS,
    INTENSITY_GRADIENT,
    CROSSING_COLORS,
    BAR_COLORS,
)

# =============================================================================
# CONVENIENCE EXPORTS
# =============================================================================

# Commonly used constants (for quick imports)
METRIC_FLIGHT_COUNT = Metrics.FLIGHT_COUNT
METRIC_DURATION = Metrics.DURATION
AGG_SUM = Aggregation.SUM
AGG_DAILY_AVG = Aggregation.DAILY_AVG

# =============================================================================
# MODULE METADATA
# =============================================================================

__version__ = '1.0.0'
__all__ = [
    # Modules
    'core',
    'ui',
    'colors',
    
    # Core constants
    'CACHE_TTL_SECONDS',
    'HEXAGON_SIZES',
    'DEFAULT_HEXAGON_SIZE',
    'MAX_QUERY_ROWS',
    'MAX_H3_CELLS',
    
    # Core classes
    'Metrics',
    'Aggregation',
    'Defaults',
    'Thresholds',
    
    # UI classes
    'Labels',
    'Charts',
    'Content',
    
    # Color classes
    'RGB',
    'Hex',
    'RGBA',
    
    # Color functions
    'get_intensity_color_3point',
    'get_intensity_color_2point',
    'rgb_to_hex',
    'hex_to_rgb',
    
    # Color arrays
    'INTENSITY_COLOR_RANGE',
    'PLOTLY_INTENSITY_SCALE',
    
    # Legacy compatibility (deprecated but supported)
    'METRIC_LABELS',
    'AGG_LABELS',
    'BAR_CONFIG',
    'HEATMAP_COLORS',
    'AXIS_CONFIG',
    'TOOLTIP_FORMAT',
    'CHART_TITLES',
    'CHART_CAPTIONS',
    'COLORS',
    'INTENSITY_GRADIENT',
    'CROSSING_COLORS',
    'BAR_COLORS',
    
    # Convenience exports
    'METRIC_FLIGHT_COUNT',
    'METRIC_DURATION',
    'AGG_SUM',
    'AGG_DAILY_AVG',
]
