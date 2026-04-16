# Gate Utilization by Airline - Sorting Implementation

## Change Summary

Updated the "Gate Utilization by Airline (Stacked Minutes by Gate)" chart to sort deterministically based on operational importance.

## What Changed

**File:** `dashboard/pages/5_Gate_Analysis.py` (lines 209-219)

### Before
```python
air_gate_pivot = air_gate_pivot.round(0).sort_index()
gate_names = list(air_gate_pivot.columns)
```
- Airlines sorted alphabetically
- Gates in arbitrary order from pivot

### After
```python
air_gate_pivot = air_gate_pivot.round(0)

# Sort airlines by total utilization (descending)
air_gate_pivot['_total_utilization'] = air_gate_pivot.sum(axis=1)
air_gate_pivot = air_gate_pivot.sort_values('_total_utilization', ascending=False)
air_gate_pivot = air_gate_pivot.drop(columns=['_total_utilization'])

# Sort gates by total utilization across all airlines (descending)
gate_totals = air_gate_pivot.sum(axis=0).sort_values(ascending=False)
gate_names = gate_totals.index.tolist()
```
- Airlines sorted by total dwell minutes (highest first)
- Gates sorted by total utilization (highest first)

## Expected Behavior

### Airline Ordering
- **Top of chart**: Airlines with highest total gate utilization
- **Bottom of chart**: Airlines with lowest total gate utilization
- No alphabetical ordering unless it coincidentally matches utilization

### Gate Ordering
- **First segments** (leftmost in stacked bars): Gates with highest total utilization
- **Last segments**: Gates with lowest total utilization
- Consistent gate ordering across all airlines for easy comparison

## Example

**Before (alphabetical):**
```
Alaska Airlines    [random gate order]
American Airlines  [random gate order]
Southwest Airlines [random gate order]
United Airlines    [random gate order]
```

**After (sorted by utilization):**
```
Southwest Airlines [A2: 500min | A1: 300min | B3: 100min]  ← Highest total
American Airlines  [A2: 200min | A1: 450min | C1: 50min]
United Airlines    [A2: 150min | A1: 100min | B3: 300min]
Alaska Airlines    [A2: 80min | A1: 40min | C1: 100min]    ← Lowest total
```

Where gates (A2, A1, B3, C1...) appear in consistent order based on their global utilization.

## Validation Checklist

To verify the change works correctly:

1. Open Gate Analysis page
2. Set date range with substantial data
3. Check "Gate Utilization by Airline" chart
4. Verify:
   - [ ] First airline has highest total utilization
   - [ ] Last airline has lowest total utilization
   - [ ] Airlines NOT in alphabetical order (unless coincidental)
   - [ ] Gate segments appear in consistent order across airlines
   - [ ] First gate segment represents highest-utilized gate
   - [ ] Chart is immediately readable without hovering

## User Impact

- **San Diego Airport Ops feedback addressed**: High-utilization airlines and gates appear first
- **Improved readability**: No more "random" ordering
- **Operational clarity**: Immediately identify busiest airlines and gates
- **No metric changes**: Only presentation order changed

## Technical Notes

- No SQL query modifications
- No changes to underlying data or calculations
- Sorting happens at pandas DataFrame level
- Compatible with airline filter and "Hide Unknown" checkbox
- Preserves all existing colors and styling
