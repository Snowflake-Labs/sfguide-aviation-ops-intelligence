# Plotly vs Altair Prototype - Implementation Summary

## Overview

Created a side-by-side comparison of Plotly (current) vs Altair (proposed) for the "Gate Utilization by Airline" chart in the Gate Analysis dashboard page.

## What Was Implemented

### 1. Dependencies Added
**File:** `dashboard/pyproject.toml`
- Added `altair` to dependencies list

### 2. Gate Analysis Page Updated
**File:** `dashboard/pages/5_Gate_Analysis.py`

**Changes:**
- Added `import altair as alt` (line 13)
- Replaced standalone chart with side-by-side comparison (lines 200-399)
- Added prototype banner at top
- Created two-column layout (col1 = Plotly, col2 = Altair)
- Added expandable code comparison section

### 3. Features Demonstrated

**Left Column (Plotly):**
- Current implementation with ~50 lines of code
- Manual sorting with `categoryorder='array'`
- Manual color palette assignment
- Explicit trace-by-trace construction

**Right Column (Altair):**
- Proposed implementation with ~20 lines of code
- Automatic sorting with `sort=EncodingSortField(...)`
- Automatic color assignment
- Declarative specification

**Code Comparison Expander:**
- Side-by-side code snippets
- Feature comparison table
- Pros/cons for each library
- Migration recommendation

## Key Differences Highlighted

| Aspect | Plotly | Altair |
|--------|--------|--------|
| Lines of code | ~50 | ~20 |
| Sorting approach | Manual category arrays | Declarative sort fields |
| Data format | Wide (pivot) | Long (melted) |
| Color assignment | Manual loop | Automatic |
| Syntax style | Imperative | Declarative |

## Altair Advantages Demonstrated

1. **60% code reduction** - 20 lines vs 50 lines
2. **Intuitive sorting** - `sort=alt.EncodingSortField(field='DWELL_MINUTES', op='sum', order='descending')`
3. **Automatic stacking** - No need for explicit `barmode='stack'`
4. **Cleaner syntax** - Say *what* you want, not *how* to build it
5. **Same interactivity** - Hover tooltips, zoom, pan

## Testing the Prototype

### How to View
1. Navigate to Gate Analysis page in the dashboard
2. Look for "🔬 PROTOTYPE: Comparing visualization libraries" banner at top
3. See both charts side-by-side
4. Expand "📝 Code Comparison" to see implementation details

### What to Verify
- [ ] Both charts display the same data
- [ ] Both charts sort identically (largest bars at top)
- [ ] Both charts show colored segments in descending order
- [ ] Altair tooltips work on hover
- [ ] Altair chart has same visual quality as Plotly
- [ ] Code comparison expander displays correctly

## Next Steps

### If Approved for Migration
1. Migrate remaining 4 bar charts in Gate Analysis (3-4 hours)
2. Migrate Traffic Analysis page bar charts (2 hours)
3. Migrate Runway Crossings page bar charts (2 hours)
4. **Keep Plotly for:** Map visualizations, 3D charts, PyDeck integration
5. Update documentation with Altair examples

**Total migration estimate:** 6-8 hours for all bar charts

### If Not Approved
- Remove prototype section
- Keep improved Plotly implementation with `categoryorder='array'`
- Continue using current stack

## Files Modified

1. `dashboard/pyproject.toml` - Added altair dependency
2. `dashboard/pages/5_Gate_Analysis.py` - Added prototype comparison

## Technical Notes

- **Data transformation:** Altair requires long format, added `.melt()` call
- **Row limit:** Altair has 5K row limit, but Gate Analysis has <500 rows (safe)
- **Bundle size:** Altair adds ~1MB to dependencies
- **Learning curve:** Team will need brief introduction to declarative syntax
- **Compatibility:** Both libraries work seamlessly with Streamlit

## Recommendation

**Migrate to Altair for bar charts** based on:
- Significantly simpler code maintenance
- More intuitive sorting logic (no more category array confusion)
- Industry standard declarative grammar (Vega-Lite)
- Better developer experience
- Same end-user experience

Keep Plotly for maps, 3D visualizations, and PyDeck integration where Altair is not suitable.
