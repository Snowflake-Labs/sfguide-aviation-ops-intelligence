# Friction Log: aviation-installer Skill E2E Test

**Date:** 2026-04-15 15:48 UTC
**Airport:** San Diego International (SAN / KSAN)
**Account:** wgb26798
**Tester:** Cortex Code (automated)

---

## Summary

| Metric | Value |
|--------|-------|
| Sub-skills executed | 4 of 5 (flight-schedules skipped: no API key) |
| Total objects created | ~80+ (34 tables, 23 procedures, 13 dynamic tables, 3 views, 7 tasks, 1 streamlit, 1 warehouse, 3 EAIs, 3 network rules, 3 UDFs, 1 stage, 2 tags) |
| Friction items (bugs) | 1 |
| Friction items (info) | 2 |
| Severity breakdown | P2: 1, Info: 2 |

---

## Friction Items

### F1 — Task resume ordering requires suspend-resume dance for child tasks
- **Severity:** P2 (minor — workaround straightforward but unexpected)
- **Sub-skill:** installer router (Step 7)
- **Symptom:** `ALTER TASK AIRPORT_SAN.PUBLIC.TASK_ENRICH_ADSB RESUME` fails with `Unable to update graph with root task AIRPORT_SAN.PUBLIC.TASK_INGEST_ADSB since that root task is not suspended`
- **Root cause:** The SKILL.md says to resume tasks in leaf-to-root order, but TASK_REFRESH_ANALYTICS and TASK_REFRESH_DERIVED were already resumed by the derived-analytics sub-skill (06c-operations.md). When Step 7 then resumed TASK_INGEST_ADSB (root), the root was now STARTED. Trying to resume TASK_ENRICH_ADSB (a child of the now-started root) fails because Snowflake requires the root task to be SUSPENDED when modifying child task state.
- **Fix applied:** Suspended root task, resumed child task, then re-resumed root task.
- **Recommendation:** In SKILL.md Step 7, add a note: "If derived-analytics sub-skill already resumed some child tasks, you may need to suspend the root task first, resume the remaining children, then re-resume the root." OR: ensure 06c-operations.md does NOT resume tasks, leaving that entirely to the router.

### I1 — 01-network-rules-eai.md only has adsb.lol rule
- **Severity:** Info
- **Sub-skill:** adsb-ingestion
- **File:** `adsb-ingestion/references/01-network-rules-eai.md`
- **Observation:** The file only contains the adsb.lol network rule and EAI. The GitHub and PyPI network rules/EAIs are defined in `06a-backfill-infra.md` (GitHub) and implied by the procedure definitions (PyPI). The SKILL.md says Step 1 creates 3 network rules and Step 2 creates 3 EAIs, but reference file 01 only has 1 of each.
- **Impact:** None — I created all 3 based on the SKILL.md description and the patterns in the reference files. But a strictly literal reader of just `01-network-rules-eai.md` would miss 2 of the 3.
- **Recommendation:** Either consolidate all network rules/EAIs into `01-network-rules-eai.md`, or update the SKILL.md step descriptions to accurately reflect which file contains which rules.

### I2 — Derived analytics 06c-operations.md resumes tasks before router Step 7
- **Severity:** Info
- **Sub-skill:** derived-analytics
- **File:** `derived-analytics/references/06c-operations.md`
- **Observation:** The operations file resumes all DTs and tasks as part of its workflow. The router's Step 7 also resumes tasks. This creates a conflict when the router tries to resume tasks that are already started (see F1).
- **Recommendation:** Decide whether task resumption belongs to the sub-skill or the router, and remove it from the other.

---

## Expected Gaps (Not Friction)

### E1 — FLIGHT_SCHEDULE table does not exist (stub created)
- **Sub-skill:** flight-schedules (skipped)
- **Impact:** Resolved by derived-analytics creating a stub table with all required columns.

### E2 — All Dynamic Tables have 0 rows
- **Impact:** Expected — data arrives via backfill tasks and real-time ingestion which are now running.

---

## Object Inventory (Final State)

### AIRPORT_SAN.PUBLIC

| Object Type | Count | Status |
|-------------|-------|--------|
| Base Tables | 34 | All created (incl. FLIGHT_SCHEDULE stub) |
| Dynamic Tables | 13 | All ACTIVE, 0 rows (awaiting data) |
| Views | 3 | V_AIR_OPS_TIMELINE, V_AIR_OPS_DAILY_KPIS, HELPER_LANDING_LIVE_TIMETABLE |
| Procedures | 23 | All created and callable |
| Functions/UDFs | 3 | UDF_TZID_FROM_LATLON, GET_OSM_TAG, ST_GETPOLYGONS |
| Tasks | 7 | All started (5 DAG + 2 backfill) |

### AIRPORT_SAN.TAGS

| Tag | Status |
|-----|--------|
| SOLUTION | Created |
| COMPONENT | Created |

### AVIA_INSTALLER.PUBLIC

| Object | Status |
|--------|--------|
| AVIA_OPS_REPO (Git Repo) | Exists (pre-existing) |
| AIRPORT_ANALYTICS_DASHBOARD (Streamlit) | Created (url_id: q7y7ln7rl5g4c3l2wijn) |

### Warehouse

| Object | Status |
|--------|--------|
| AVIA_SAN_WH (XSMALL) | Created, AUTO_SUSPEND=60, AUTO_RESUME=TRUE |

### Network & Integration Objects

| Object | Status |
|--------|--------|
| PUBLIC_adsb_lol_rule | Created |
| PUBLIC_github_rule | Created |
| PUBLIC_pypi_network_rule | Created |
| AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI | Created |
| AIRPORT_SAN_PUBLIC_GITHUB_EAI | Created |
| AIRPORT_SAN_PUBLIC_PYPI_ACCESS_INTEGRATION | Created |

---

## Verification Results

| Check | Result |
|-------|--------|
| PROPERTIES_AIRPORT | 1 row |
| PROPERTIES_INFRASTRUCTURE | 750 rows |
| PROPERTIES_GATES | 51 rows |
| PROPERTIES_RUNWAYS | 1 row |
| HELPER_AIRLINE_DIM | 1222 rows |
| Dynamic Tables | 13 ACTIVE |
| Tasks | 7 started |
| Streamlit | Deployed |
| Backfill | Started (TASK_ADSB_BACKFILL_ONCE running) |
