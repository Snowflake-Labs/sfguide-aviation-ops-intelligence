# Altair Bar Spacing Fix - Using Step-Based Height

**Date:** February 10, 2026  
**Issue:** Scale padding parameters (paddingInner=0, paddingOuter=0) were not visually reducing spacing between bars

## Problem

After migrating to Altair, attempts to reduce spacing between bars using `scale=alt.Scale(paddingInner=0, paddingOuter=0)` in the Y-axis encoding did not produce visible changes. The bars still had significant spacing between them.

## Root Cause

In Altair, for horizontal bar charts with categorical Y-axes:
- The `paddingInner` and `paddingOuter` parameters control the *proportion* of space relative to bar width
- However, when using a fixed `height` property, Altair calculates the bar width dynamically based on the total height divided by the number of categories
- This means the actual spacing is determined by the height allocation formula (e.g., `height = 40 * num_bars`), not just the padding parameters

## Solution

Replace fixed height calculations with `alt.Step()` to directly control the pixels allocated per bar:

**Before:**
```python
.properties(
    height=min(max(500, 40 * len(categories)), 1200)
)
```

**After:**
```python
.properties(
    height=alt.Step(20)  # 20 pixels per bar
)
```

## Benefits

1. **Direct control**: Each bar gets exactly the specified number of pixels
2. **Consistent spacing**: The step size directly determines bar thickness and spacing
3. **No arbitrary formulas**: Eliminates need for `min(max(...))` calculations
4. **Predictable behavior**: Smaller step = tighter spacing, larger step = more spacing

## Changes Applied

### 5_Gate_Analysis.py
- **Gate Utilization by Airline (Dwell Minutes)**: `height=alt.Step(20)`
- **Gate Utilization by Dwell Minutes**: `height=alt.Step(15)`
- **Gate Utilization by Number of Flights**: `height=alt.Step(15)`

### 3_Runway_Crossings.py
- **Crossings by Gate and Direction**: `height=alt.Step(20)`

### Step Sizes Used
- **20 pixels**: For airline-level aggregations (fewer bars, more prominent)
- **15 pixels**: For gate-level details (many bars, need compact view)

## Technical Notes

- `alt.Step()` makes the chart height responsive to the number of categories
- No need to manually calculate heights or set min/max bounds
- Removed `scale=alt.Scale(paddingInner=0, paddingOuter=0)` as step-based sizing provides better control
- The `size` parameter in `mark_bar()` still controls the bar thickness (not affected by this change)

## Result

Bars are now significantly more compact with minimal spacing between them, creating the tight, dense visualization requested by the user.
