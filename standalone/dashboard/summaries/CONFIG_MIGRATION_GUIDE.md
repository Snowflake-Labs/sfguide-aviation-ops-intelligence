# Configuration Migration Guide

## Overview

The dashboard configuration has been consolidated from 4 separate files into a unified `config/` package.

### Old Structure (DEPRECATED)
```
constants.py           → config/core.py
chart_config.py        → config/ui.py
display_constants.py   → config/ui.py
colors.py              → config/colors.py
```

## Quick Migration

### 1. Update Imports

**Old:**
```python
import constants
import chart_config
from colors import get_intensity_color_3point
```

**New (Option A - Legacy compatibility):**
```python
from config import CACHE_TTL_SECONDS, HEXAGON_SIZES
from config import BAR_CONFIG, COLORS, TOOLTIP_FORMAT
from config import get_intensity_color_3point
```

**New (Option B - Modern, recommended):**
```python
from config.core import CACHE_TTL_SECONDS, Metrics, Aggregation
from config.ui import Labels, Charts
from config.colors import RGB, Hex, get_intensity_color_3point
```

### 2. Update References

#### Constants

| Old | New (Legacy) | New (Modern) |
|-----|--------------|--------------|
| `constants.CACHE_TTL_SECONDS` | `config.CACHE_TTL_SECONDS` | `config.core.CACHE_TTL_SECONDS` |
| `constants.METRIC_FLIGHT_COUNT` | `config.METRIC_FLIGHT_COUNT` | `config.Metrics.FLIGHT_COUNT` |
| `constants.AGG_SUM` | `config.AGG_SUM` | `config.Aggregation.SUM` |
| `constants.HEXAGON_SIZES` | `config.HEXAGON_SIZES` | `config.core.HEXAGON_SIZES` |

#### Chart Config

| Old | New (Legacy) | New (Modern) |
|-----|--------------|--------------|
| `chart_config.BAR_CONFIG` | `config.BAR_CONFIG` | `config.ui.BAR_CONFIG` |
| `chart_config.COLORS` | `config.COLORS` | `config.colors.Hex.*` |
| `chart_config.TOOLTIP_FORMAT` | `config.TOOLTIP_FORMAT` | `config.ui.TOOLTIP_FORMAT` |

#### Colors

| Old | New (Legacy) | New (Modern) |
|-----|--------------|--------------|
| `colors.get_intensity_color_3point()` | `config.get_intensity_color_3point()` | `config.colors.get_intensity_color_3point()` |
| `colors.INTENSITY_GRADIENT` | `config.INTENSITY_GRADIENT` | `config.colors.RGB.*` |
| `colors.COLORS['blue']` | `config.COLORS['blue']` | `config.colors.Hex.BLUE` |

## Migration Steps by File

### Step 1: Update Ground Activity (DONE)
```python
# Old
import constants
metric_type_selection == constants.METRIC_FLIGHT_COUNT

# New
from config import Metrics
metric_type_selection == Metrics.FLIGHT_COUNT
```

### Step 2: Update Runway Crossings (DONE)
```python
# Old
import constants
@st.cache_data(ttl=constants.CACHE_TTL_SECONDS)

# New
from config import core
@st.cache_data(ttl=core.CACHE_TTL_SECONDS)
```

### Step 3: Update Traffic Analysis
```python
# Old
from chart_config import BAR_CONFIG, COLORS, TOOLTIP_FORMAT

# New (legacy)
from config import BAR_CONFIG, COLORS, TOOLTIP_FORMAT

# New (modern)
from config.ui import BAR_CONFIG, TOOLTIP_FORMAT
from config.colors import Hex
color = Hex.BLUE
```

### Step 4: Update Gate Analysis
Similar to Traffic Analysis

### Step 5: Update Fleet Overview
Similar to Traffic Analysis

## Benefits of New Structure

### 1. Organization
- Clear hierarchy: `config.core` → `config.ui` → `config.colors`
- Logical grouping: Related constants together
- No more duplicate definitions

### 2. Discoverability
```python
from config import core, ui, colors

# IDE auto-complete shows all options:
core.CACHE_TTL_SECONDS
core.Metrics.FLIGHT_COUNT
ui.Labels.METRIC_FLIGHT_COUNT
ui.Charts.BAR_HORIZONTAL_SIZE
colors.RGB.LOW
colors.Hex.BLUE
```

### 3. Type Safety
```python
# Modern approach (type-safe)
if metric == Metrics.FLIGHT_COUNT:  # IDE knows valid values
    ...

# Legacy approach (error-prone)
if metric == "flight_count":  # Easy to typo
    ...
```

### 4. Maintenance
- Single source of truth
- No duplicate definitions
- Easy to find and update

## Backward Compatibility

All old imports still work during migration:

```python
# These all still work:
from config import METRIC_LABELS  # Legacy dict
from config import BAR_CONFIG     # Legacy dict
from config import COLORS         # Legacy dict

# Access like before:
label = METRIC_LABELS["flight_count"]
color = COLORS["blue"]
```

## Best Practices

### DO ✅
```python
# Use class-based access (modern)
from config.core import Metrics, Aggregation
if metric == Metrics.FLIGHT_COUNT:
    ...

# Use dedicated imports
from config.ui import Labels
label = Labels.METRIC_FLIGHT_COUNT

# Use color classes
from config.colors import Hex
color = Hex.BLUE
```

### DON'T ❌
```python
# Don't use raw strings
if metric == "flight_count":  # Error-prone

# Don't import from deprecated files
import constants  # Deprecated
from chart_config import COLORS  # Deprecated

# Don't mix old and new
import constants
from config import Metrics  # Confusing
```

## Migration Checklist

- [x] Create config/ package
- [x] Update ui_components.py
- [x] Update pages/2_Ground_Activity.py
- [x] Update pages/3_Runway_Crossings.py
- [ ] Update pages/4_Traffic_Analysis.py
- [ ] Update pages/5_Gate_Analysis.py
- [ ] Update pages/1_Fleet_Overview.py
- [ ] Update any other files importing from deprecated modules
- [ ] Add deprecation warnings to old files
- [ ] Remove old files (final phase)

## Deprecation Timeline

**Phase 1 (Current)**: New config/ package available, old files still work
**Phase 2 (2 weeks)**: Add deprecation warnings to old files
**Phase 3 (4 weeks)**: Update all remaining files
**Phase 4 (6 weeks)**: Remove old files

## Need Help?

- See `config/__init__.py` for full list of exports
- See `CONFIG_CONSOLIDATION_PLAN.md` for detailed rationale
- See `REFACTORING_SUMMARY.md` for overall refactoring changes
