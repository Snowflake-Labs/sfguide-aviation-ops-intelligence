# Configuration Files Consolidation Analysis

## Current State

### File Inventory

1. **`constants.py`** (NEW - just created)
   - H3 resolution mappings
   - Metric types and labels
   - Aggregation types and labels
   - Default values
   - Cache TTL

2. **`chart_config.py`**
   - Bar chart sizing configurations
   - Chart colors (Altair/general)
   - Heatmap color schemes
   - Axis configurations
   - Tooltip formatting

3. **`colors.py`**
   - RGB intensity gradients
   - Color range arrays
   - Color calculation functions (get_intensity_color_3point, get_intensity_color_2point)
   - Crossing colors
   - Bar colors (duplicate of chart_config)
   - Plotly intensity scale

4. **`display_constants.py`**
   - Chart titles
   - Chart captions/descriptions
   - Metric labels (DUPLICATE of constants.py)
   - Operational tags
   - Vocabulary
   - Color scheme documentation (DUPLICATE of colors.py)
   - Help text

## Identified Issues

### 1. Duplication
- **METRIC_LABELS**: Defined in both `constants.py` and `display_constants.py`
- **Colors**: Partial overlap between `chart_config.py` and `colors.py`
- **Color schemes**: Documented in both `colors.py` and `display_constants.py`
- **BAR_COLORS**: Exists in both `chart_config.py` (COLORS) and `colors.py` (BAR_COLORS)

### 2. Unclear Separation of Concerns
- `chart_config.py` has colors (which belong in `colors.py`)
- `display_constants.py` has color documentation (which belongs in `colors.py`)
- `colors.py` has both data (RGB values) and functions (gradient calculations)

### 3. Naming Inconsistency
- `constants.py` vs `chart_config.py` vs `display_constants.py` - unclear hierarchy
- Some files use SCREAMING_CASE, others use lowercase_with_underscores

## Proposed Unified Structure

### Option A: Three-File System (RECOMMENDED)

```
config/
├── __init__.py
├── core.py          # Core application constants
├── ui.py            # UI/display constants and styling
└── colors.py        # Color definitions and functions
```

#### `config/core.py`
```python
"""
Core application configuration and constants.
Business logic, data processing, and technical settings.
"""

# Data Processing
CACHE_TTL_SECONDS = 600
MAX_QUERY_ROWS = 10000
DEFAULT_SAMPLE_PERCENT = 100

# H3 Geospatial
HEXAGON_SIZES = {"Small": 14, "Medium": 13, "Large": 12}
DEFAULT_HEXAGON_SIZE = "Medium"

# Metrics
class Metrics:
    FLIGHT_COUNT = "flight_count"
    DURATION = "total_duration"
    
class Aggregation:
    SUM = "sum"
    DAILY_AVG = "daily_average"

# Defaults
class Defaults:
    METRIC = Metrics.FLIGHT_COUNT
    AGGREGATION = Aggregation.SUM
    PERCENTILE = 0
    DAYS_BACK = 7
```

#### `config/ui.py`
```python
"""
User interface configuration: labels, titles, captions, formatting.
Everything visible to the user.
"""

# Display Labels
class Labels:
    # Metrics
    METRIC_FLIGHT_COUNT = "Flight Count"
    METRIC_DURATION = "Duration (min)"
    
    # Aggregation
    AGG_SUM = "Sum"
    AGG_DAILY_AVG = "Daily Average"
    
    # Hexagon Sizes
    HEXAGON_SMALL = "Small"
    HEXAGON_MEDIUM = "Medium"
    HEXAGON_LARGE = "Large"

# Chart Configuration
class Charts:
    # Bar sizing
    BAR_HORIZONTAL_STEP = 20
    BAR_HORIZONTAL_SIZE = 15
    BAR_VERTICAL_STEP = 50
    BAR_VERTICAL_SIZE = 40
    
    # Axis
    AXIS_LABEL_LIMIT_SHORT = 150
    AXIS_LABEL_LIMIT_MEDIUM = 200
    AXIS_LABEL_LIMIT_LONG = 300
    
    # Tooltips
    TOOLTIP_FORMAT_INTEGER = ',.0f'
    TOOLTIP_FORMAT_DECIMAL_1 = ',.1f'
    TOOLTIP_FORMAT_DECIMAL_2 = ',.2f'
    TOOLTIP_FORMAT_PERCENT = '.1%'
    
    # Heatmaps
    HEATMAP_SCHEME = 'teals'
    HEATMAP_SCHEME_DIVERGING = 'redyellowgreen'
    HEATMAP_SCHEME_SEQUENTIAL = 'blues'

# Titles and Captions
class Content:
    TITLES = {
        'aircraft_on_ground_by_hour': '🕐 Aircraft on Ground by Hour',
        'crossing_density_heatmap': '📍 Crossing Density Heatmap',
        # ... rest of titles
    }
    
    CAPTIONS = {
        'aircraft_on_ground_by_hour': 'Shows the sum of aircraft present during each hour',
        # ... rest of captions
    }
    
    HELP_TEXT = {
        'metric_selector': 'Distinct Aircraft Count: Count unique aircraft...',
        # ... rest of help text
    }
    
    OPERATIONAL_TAGS = {
        'level2_relevant': '🏷️ **Level 2 relevant**...',
    }

# Legacy compatibility dictionaries (for gradual migration)
METRIC_LABELS = {
    "flight_count": Labels.METRIC_FLIGHT_COUNT,
    "total_duration": Labels.METRIC_DURATION
}

AGG_LABELS = {
    "sum": Labels.AGG_SUM,
    "daily_average": Labels.AGG_DAILY_AVG
}

BAR_CONFIG = {
    'horizontal': {
        'step': Charts.BAR_HORIZONTAL_STEP,
        'size': Charts.BAR_HORIZONTAL_SIZE,
        'label_limit': Charts.AXIS_LABEL_LIMIT_MEDIUM
    },
    'vertical': {
        'step': Charts.BAR_VERTICAL_STEP,
        'size': Charts.BAR_VERTICAL_SIZE,
    },
    # ... rest of configs
}

TOOLTIP_FORMAT = {
    'integer': Charts.TOOLTIP_FORMAT_INTEGER,
    'decimal_1': Charts.TOOLTIP_FORMAT_DECIMAL_1,
    # ... rest of formats
}
```

#### `config/colors.py` (Enhanced)
```python
"""
Color definitions, palettes, and color utility functions.
Aviation-standard intensity gradients and operational colors.
"""

# Primary RGB definitions
class RGB:
    # Intensity gradient
    LOW = (79, 195, 247)      # Teal
    MEDIUM = (255, 193, 7)    # Yellow
    HIGH = (255, 87, 34)      # Orange
    EXTREME = (211, 47, 47)   # Red
    CRITICAL = (136, 14, 79)  # Dark red
    
    # Operational states
    NORMAL = (255, 152, 0)    # Orange
    ALERT = (244, 67, 54)     # Red

# Hex color palettes
class Hex:
    # Chart colors (for Altair)
    BLUE = '#4FC3F7'
    GREEN = '#66BB6A'
    RED = '#EF5350'
    ORANGE = '#FF9800'
    PURPLE = '#9C27B0'
    
    # Semantic colors
    DEFAULT = BLUE
    HIGHLIGHTED = ORANGE
    ALERT = '#F44336'
    NEUTRAL = '#78909C'

# RGBA arrays (for PyDeck)
class RGBA:
    @staticmethod
    def from_rgb(rgb, alpha=220):
        """Convert RGB tuple to RGBA list"""
        return [rgb[0], rgb[1], rgb[2], alpha]
    
    LOW = from_rgb.__func__(RGB.LOW, 128)
    MEDIUM = from_rgb.__func__(RGB.MEDIUM, 160)
    HIGH = from_rgb.__func__(RGB.HIGH, 200)
    EXTREME = from_rgb.__func__(RGB.EXTREME, 230)

# Color gradients for maps
INTENSITY_COLOR_RANGE = [
    [79, 195, 247, 0],
    [79, 195, 247, 128],
    [255, 193, 7, 160],
    [255, 152, 0, 200],
    [255, 87, 34, 230],
    [211, 47, 47, 255],
]

# Plotly color scales
PLOTLY_INTENSITY_SCALE = [
    [0.0, Hex.BLUE],
    [0.33, '#FFC107'],
    [0.67, '#FF5722'],
    [1.0, '#D32F2F'],
]

# Color calculation functions
def get_intensity_color_3point(normalized_value):
    """
    Returns RGB color for a value normalized between 0-1.
    Uses 3-point gradient: teal → yellow → red
    """
    if normalized_value < 0.5:
        t = normalized_value * 2
        low = RGB.LOW
        high = RGB.MEDIUM
    else:
        t = (normalized_value - 0.5) * 2
        low = RGB.MEDIUM
        high = RGB.EXTREME
    
    r = int(low[0] + t * (high[0] - low[0]))
    g = int(low[1] + t * (high[1] - low[1]))
    b = int(low[2] + t * (high[2] - low[2]))
    return [r, g, b, 220]

def get_intensity_color_2point(normalized_value):
    """
    Returns RGB color for a value normalized between 0-1.
    Uses 2-point gradient: teal → red
    """
    low = RGB.LOW
    high = RGB.EXTREME
    t = max(0.0, min(1.0, normalized_value))
    
    r = int(low[0] + t * (high[0] - low[0]))
    g = int(low[1] + t * (high[1] - low[1]))
    b = int(low[2] + t * (high[2] - low[2]))
    return [r, g, b, 220]

# Legacy compatibility dictionaries
COLORS = {
    'blue': Hex.BLUE,
    'green': Hex.GREEN,
    'red': Hex.RED,
    'orange': Hex.ORANGE,
    'default': Hex.DEFAULT,
    'highlighted': Hex.HIGHLIGHTED,
    'alert': Hex.ALERT,
    # ... rest of legacy mappings
}

INTENSITY_GRADIENT = {
    'low_rgb': RGB.LOW,
    'medium_rgb': RGB.MEDIUM,
    'high_rgb': RGB.HIGH,
    'extreme_rgb': RGB.EXTREME,
    'critical_rgb': RGB.CRITICAL,
}
```

#### `config/__init__.py`
```python
"""
Unified configuration package for Aviation Operations Dashboard.

Usage:
    from config import core, ui, colors
    
    # Or import specific items
    from config.core import Metrics, Aggregation, Defaults
    from config.ui import Labels, Charts, Content
    from config.colors import RGB, Hex, get_intensity_color_3point
    
    # Legacy compatibility
    from config.ui import METRIC_LABELS, AGG_LABELS, BAR_CONFIG
    from config.colors import COLORS, INTENSITY_GRADIENT
"""

# Re-export commonly used items for convenience
from .core import (
    CACHE_TTL_SECONDS,
    HEXAGON_SIZES,
    DEFAULT_HEXAGON_SIZE,
    Metrics,
    Aggregation,
    Defaults
)

from .ui import (
    Labels,
    Charts,
    Content,
    # Legacy
    METRIC_LABELS,
    AGG_LABELS,
    BAR_CONFIG,
    TOOLTIP_FORMAT
)

from .colors import (
    RGB,
    Hex,
    RGBA,
    get_intensity_color_3point,
    get_intensity_color_2point,
    # Legacy
    COLORS,
    INTENSITY_GRADIENT,
    INTENSITY_COLOR_RANGE,
    PLOTLY_INTENSITY_SCALE
)

__all__ = [
    # Modules
    'core',
    'ui',
    'colors',
    
    # Commonly used
    'CACHE_TTL_SECONDS',
    'HEXAGON_SIZES',
    'Metrics',
    'Aggregation',
    'Defaults',
    'Labels',
    'Charts',
    'Content',
    'RGB',
    'Hex',
    'get_intensity_color_3point',
    
    # Legacy compatibility
    'METRIC_LABELS',
    'AGG_LABELS',
    'BAR_CONFIG',
    'TOOLTIP_FORMAT',
    'COLORS',
    'INTENSITY_GRADIENT',
]
```

### Option B: Single File System (Simpler, but less organized)

```
config.py  # Everything in one file with clear sections
```

## Migration Strategy

### Phase 1: Create New Structure (Week 1)
1. Create `config/` directory
2. Create `core.py`, `ui.py`, `colors.py` with new structure
3. Add `__init__.py` with legacy compatibility exports
4. Keep old files in place

### Phase 2: Update Imports (Week 2)
1. Update one page at a time to use new imports
2. Test thoroughly after each page
3. Examples:
   ```python
   # Old
   from constants import METRIC_FLIGHT_COUNT
   from chart_config import COLORS, BAR_CONFIG
   from colors import get_intensity_color_3point
   
   # New (Option 1: Direct imports)
   from config.core import Metrics
   from config.ui import Charts, BAR_CONFIG
   from config.colors import get_intensity_color_3point
   
   # New (Option 2: Legacy compatibility)
   from config import METRIC_LABELS, BAR_CONFIG, COLORS
   from config import get_intensity_color_3point
   ```

### Phase 3: Deprecate Old Files (Week 3)
1. Once all pages migrated, mark old files as deprecated
2. Add deprecation warnings
3. Update documentation

### Phase 4: Remove Old Files (Week 4)
1. Delete `constants.py`, `chart_config.py`, `display_constants.py`
2. Keep `colors.py` logic in `config/colors.py`
3. Update all references

## Benefits of Unified Structure

### Organization
- **Clear hierarchy**: core → ui → colors
- **Logical grouping**: Related constants together
- **Namespace clarity**: `config.core.Metrics` vs just `METRIC_FLIGHT_COUNT`

### Maintainability
- **Single source of truth**: No more duplicates
- **Easy to find**: Know exactly where each constant lives
- **Type safety**: Using classes enables better IDE support

### Discoverability
- **Auto-complete friendly**: `config.core.` shows all core constants
- **Self-documenting**: Class names indicate purpose
- **Legacy support**: Old imports still work during migration

### Performance
- **Lazy loading**: Only load what you need
- **Tree shaking**: Unused constants can be eliminated
- **Caching**: Python imports are cached

## Recommendation

**Implement Option A (Three-File System)** because:

1. ✅ Clearest separation of concerns
2. ✅ Easiest to maintain long-term
3. ✅ Supports gradual migration with legacy dictionaries
4. ✅ Best for large teams and future growth
5. ✅ Follows Python package best practices

## Quick Wins (Can Implement Immediately)

Even without full restructure, we can:

1. **Remove duplication** in `constants.py`:
   ```python
   # Remove METRIC_LABELS from constants.py
   # Use display_constants.METRIC_LABELS instead
   ```

2. **Merge BAR_COLORS**:
   ```python
   # In colors.py, remove BAR_COLORS
   # Use chart_config.COLORS instead
   ```

3. **Consolidate color documentation**:
   ```python
   # Remove COLOR_SCHEMES from display_constants.py
   # Keep only in colors.py
   ```

These three changes would eliminate ~50 lines of duplicate code immediately.
