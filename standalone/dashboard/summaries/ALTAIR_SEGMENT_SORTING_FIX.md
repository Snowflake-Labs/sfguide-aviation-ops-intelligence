# Altair Segment Sorting Fix

## Problem

In the Altair prototype, colored segments within each stacked bar were not sorted by size. Segments appeared in arbitrary order rather than having the largest segments first (leftmost).

## Root Cause

In Altair's stacked bar charts, the **order of data rows** determines the stacking order, not just the `color` encoding. The `sort` parameter on the color encoding only affects the legend order and global color assignment, not the visual stacking order within each bar.

## Solution

### 1. Pre-sort Data by Airline and Dwell Minutes

Before passing data to Altair, sort the long-format DataFrame so that within each airline, gates are ordered by their dwell minutes (descending):

```python
# CRITICAL: Sort within each airline so largest segments appear first
df_long = df_long.sort_values(
    ['AIRLINE_NAME', 'DWELL_MINUTES'],
    ascending=[True, False]  # Airlines ascending, dwell minutes descending
)
```

### 2. Add Explicit Order Channel

Use Altair's `order` encoding channel to explicitly control segment stacking:

```python
chart = alt.Chart(df_long).mark_bar().encode(
    x=alt.X('sum(DWELL_MINUTES):Q', title='Dwell Minutes'),
    y=alt.Y('AIRLINE_NAME:N', 
            sort=alt.EncodingSortField(field='DWELL_MINUTES', op='sum', order='descending'),
            title='Airline'),
    color=alt.Color('GATE_NAME:N', legend=None),
    order=alt.Order('DWELL_MINUTES:Q', sort='descending'),  # NEW!
    tooltip=[...]
)
```

### 3. Remove Unnecessary Color Sort

The `sort` parameter on `color` encoding was removed because:
- It only affects legend order (we have `legend=None`)
- It doesn't control visual stacking order
- The `order` channel handles segment ordering

## Changes Made

**File:** `dashboard/pages/5_Gate_Analysis.py`

**Lines 276-281:** Added data pre-sorting
```python
# CRITICAL: Sort within each airline so largest segments appear first
# This controls the stacking order in Altair
df_long = df_long.sort_values(
    ['AIRLINE_NAME', 'DWELL_MINUTES'],
    ascending=[True, False]
)
```

**Line 291:** Added order encoding
```python
order=alt.Order('DWELL_MINUTES:Q', sort='descending'),
```

**Lines 289-290:** Simplified color encoding (removed unnecessary sort)
```python
color=alt.Color('GATE_NAME:N', legend=None),
```

**Lines 349-377:** Updated code comparison documentation to reflect the fix

## How It Works

### Data Flow

1. **Start:** Wide pivot with airlines as rows, gates as columns
2. **Melt:** Convert to long format (one row per airline-gate combination)
3. **Sort:** Within each airline, order gates by dwell minutes descending
4. **Encode:** Use `order` channel to explicitly control stacking

### Example

**Before sorting:**
```
AIRLINE_NAME    GATE_NAME    DWELL_MINUTES
Southwest       A5           100
Southwest       B12          500   
Southwest       C3           200
```

**After sorting:**
```
AIRLINE_NAME    GATE_NAME    DWELL_MINUTES
Southwest       B12          500   <- Largest first
Southwest       C3           200
Southwest       A5           100
```

**Result:** In the stacked bar, B12 (largest) appears leftmost, then C3, then A5.

## Key Learnings

### Altair Stacking Behavior

1. **Data row order matters** - Rows appear in the order they exist in the DataFrame
2. **`order` channel** - Explicitly controls mark layering in stacked/layered charts
3. **`sort` on color** - Only affects legend and categorical axis order, NOT stacking

### Correct Pattern for Sorted Stacked Bars

```python
# 1. Prepare data in long format
df_long = pivot.melt(...)

# 2. Sort by grouping variable and value (descending)
df_long = df_long.sort_values(
    ['group', 'value'],
    ascending=[True, False]
)

# 3. Use order channel in encoding
chart = alt.Chart(df_long).mark_bar().encode(
    x='sum(value):Q',
    y=alt.Y('group:N', sort=...),
    color='category:N',
    order=alt.Order('value:Q', sort='descending')
)
```

## Verification

After this fix, verify:
- [ ] Largest segments appear first (leftmost) in each bar
- [ ] Segment order is consistent across all airlines
- [ ] Hover tooltips show correct gate names and values
- [ ] Visual stacking matches Plotly implementation

## Comparison: Plotly vs Altair

| Library | Segment Sorting Approach |
|---------|-------------------------|
| **Plotly** | Iterate through pre-sorted column list when adding traces |
| **Altair** | Pre-sort data + use `order` encoding channel |

Both achieve the same result, but Altair's approach is more declarative once you understand the data-driven paradigm.

## Updated Code Metrics

- **Lines of code:** ~25 (was 20, added data sorting step)
- **Still 50% less than Plotly's 50 lines**
- **Clarity:** Improved with explicit sorting and order channel

## Documentation Updated

- Code comparison section now shows the data pre-sorting step
- Updated line count from 20 to 25 to reflect sorting addition
- Added explanation of `order` channel in comparison table
