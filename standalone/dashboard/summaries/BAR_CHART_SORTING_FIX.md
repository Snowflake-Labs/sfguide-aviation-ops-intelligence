# Bar Chart Sorting Fix - Descending Display

## Problem

All bar charts were displaying in **ascending order** (smallest bars at top, largest at bottom), which is counter-intuitive for operations dashboards where users expect to see the most important items first.

Additionally, **colored segments within stacked bars** appeared in arbitrary order rather than being sorted by size.

## Root Cause

**Plotly's horizontal bar charts (`orientation='h'`)** display Y-axis categories in the order they appear in the DataFrame:
- **First row** in DataFrame → **Bottom** of chart
- **Last row** in DataFrame → **Top** of chart

We were sorting DataFrames `ascending=False` (largest first), but this placed the largest values at the **top of the DataFrame**, which Plotly displayed at the **bottom of the chart**.

## Solution

### 1. Reverse Row Order
After sorting descending, reverse the DataFrame with `.iloc[::-1]` before passing to Plotly:

```python
# Sort descending (largest total first)
pivot = pivot.sort_values('_total', ascending=False)

# Reverse for horizontal bars (Plotly displays first row at bottom)
pivot = pivot.iloc[::-1]
```

**Result:** Largest values now appear at **top** of chart.

### 2. Sort Colored Segments (Stacked Bars Only)
For stacked bars, sort columns by their total contribution so largest segments appear first (leftmost):

```python
# Sort airlines/gates by total contribution (largest segments first)
column_totals = pivot.sum(axis=0).sort_values(ascending=False)
sorted_columns = column_totals.index.tolist()
pivot = pivot[sorted_columns]
```

**Result:** Largest segments now appear first in each stacked bar.

## Changes Applied

### Chart 1: Gate Utilization by Airline (Lines 209-251)
**Changes:**
- Sort gates by total utilization → reorder columns (line 222)
- Reverse airline row order with `.iloc[::-1]` (line 225)

**Before:** 
- Air Nippon (tiny bar) at top
- Southwest (huge bar) at bottom
- Random gate segment order

**After:**
- Southwest (huge bar) at top
- Air Nippon (tiny bar) at bottom
- Largest gate segments appear first

### Chart 2: Gate Utilization by Gate - Dwell Minutes (Lines 282-329)
**Changes:**
- Sort airlines by total contribution → reorder columns (lines 289-292)
- Reverse gate row order with `.iloc[::-1]` (line 294)

**Before:** Gates with least dwell at top
**After:** Gates with most dwell at top, largest airline segments first

### Chart 3: Gate Utilization by Gate - Flights (Lines 337-383)
**Changes:**
- Sort airlines by total contribution → reorder columns (lines 344-347)
- Reverse gate row order with `.iloc[::-1]` (line 351)

**Before:** Gates with fewest flights at top
**After:** Gates with most flights at top, largest airline segments first

### Chart 4: Top 20 Flights by Dwell Time (Lines 391-419)
**Changes:**
- Reverse flight row order with `.iloc[::-1]` (line 402)

**Before:** Shortest dwell times at top
**After:** Longest dwell times at top

## Implementation Pattern

For **all future horizontal bar charts**, use this pattern:

```python
# 1. Calculate totals
df['_total'] = df.sum(axis=1)

# 2. Sort by total (descending = largest first)
df = df.sort_values('_total', ascending=False)
df = df.drop(columns=['_total'])

# 3. For stacked bars: sort columns by contribution
if stacked:
    col_totals = df.sum(axis=0).sort_values(ascending=False)
    df = df[col_totals.index.tolist()]

# 4. CRITICAL: Reverse for Plotly horizontal bars
df = df.iloc[::-1]

# 5. Create chart
fig = go.Figure()
for col in df.columns:  # Iterate in sorted order
    fig.add_trace(go.Bar(
        x=df[col],
        y=df.index,
        orientation='h',
        name=col
    ))
```

## Validation

For each chart, verify:

1. **First bar (top) = longest/highest value**
2. **Last bar (bottom) = shortest/lowest value**
3. **Stacked bars:** Largest segments appear first (leftmost)
4. **Hover over bars:** Values decrease from top to bottom
5. **Visual scan:** Chart is "upside down" compared to before

## User Impact

### Before
- Counter-intuitive: "Why is the busiest airline at the bottom?"
- Hard to find top operations: Required scrolling to bottom
- Segments in random order: Couldn't quickly identify main contributors
- Inconsistent with industry standards

### After
- Intuitive: Top operations at top of chart
- Quick scanning: Most important info immediately visible
- Segments sorted: Largest contributors always first
- Professional appearance: Matches aviation ops expectations

## Files Modified

- `dashboard/pages/5_Gate_Analysis.py`
  - Line 222: Reorder gate columns by total
  - Line 225: Reverse airline rows (Chart 1)
  - Lines 289-292: Reorder airline columns by total
  - Line 294: Reverse gate rows (Chart 2)
  - Lines 344-347: Reorder airline columns by total
  - Line 351: Reverse gate rows (Chart 3)
  - Line 402: Reverse flight rows (Chart 4)

## Technical Notes

- **No SQL changes:** All sorting in pandas
- **No data changes:** Same values, different display order
- **No layout changes:** Heights, colors, margins unchanged
- **Filter-safe:** Works correctly with "Hide Unknown" and airline filters
- **Natural sort preserved:** Gate heatmap still uses natural sort (A1, A2, A10)

## References

- Plotly horizontal bar chart ordering: https://plotly.com/python/horizontal-bar-charts/
- pandas iloc reverse: `df.iloc[::-1]` reverses row order
- San Diego Airport Ops feedback: "Need busiest operations at top"
