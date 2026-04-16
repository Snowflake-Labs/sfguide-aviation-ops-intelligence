# Friction Log: aviation-installer Skill E2E Test

**Date:** 2026-04-16
**Airport:** San Diego International (SAN / KSAN)
**Account:** wgb26798
**Tester:** Cortex Code (automated, skill-only)

---

## Summary

| Metric | Value |
|--------|-------|
| Sub-skills executed | 4 of 5 (flight-schedules skipped: no API key) |
| Total objects created | 35 tables, 26 procedures, 13 dynamic tables, 3 views, 9 tasks, 1 streamlit, 1 warehouse, 3 EAIs, 3 network rules, 1 git repo, 3 stages |
| Friction items | 4 |
| Severity breakdown | P2: 2, P3: 1, Info: 1 |

---

## Friction Items

### F1 — Airlines CSV path in skill references doesn't match Git repo

- **Severity:** P2 (0 rows loaded on first attempt)
- **Sub-skill:** base-setup
- **File:** `base-setup/references/sql-pipeline-properties.md` (Step 8)
- **Symptom:** `INSERT INTO HELPER_AIRLINE_DIM` returned 0 rows when using path `@AIRPORT_SAN.PUBLIC.AVIA_OPS_REPO/branches/main/.cortex/skills/aviation-installer/base-setup/data/airlines.csv`
- **Root cause:** The `airlines.csv` file exists at `installer/airlines.csv` on the remote Git repo (main branch), not at `.cortex/skills/aviation-installer/base-setup/data/airlines.csv`. The skill reference file points to the local skill `data/` directory which may not be committed to the remote repo.
- **Fix applied:** Used the correct path `@AIRPORT_SAN.PUBLIC.AVIA_OPS_REPO/branches/main/installer/airlines.csv` — loaded 1222 rows successfully.
- **Recommendation:** Either (a) commit `airlines.csv` to `.cortex/skills/aviation-installer/base-setup/data/` in the remote repo, or (b) update `sql-pipeline-properties.md` Step 8 to reference `{GIT_REPO_STAGE_BASE}/installer/airlines.csv` instead.
- **Status:** Workaround applied. Skill file NOT fixed.

### F2 — PROC_PROCESS_TSA_PDF fails on final REMOVE statement

- **Severity:** P2 (data extracted successfully but procedure returns error)
- **Sub-skill:** tsa-throughput
- **File:** `tsa-throughput/references/02-procedures.md`
- **Symptom:** `PROC_PROCESS_TSA_PDF` returns error at line `session.sql(f"REMOVE {pages_stage} PATTERN='.*'").collect()` — 52,546 rows were successfully extracted and inserted, but the cleanup REMOVE fails.
- **Root cause:** The `REMOVE` SQL command with `PATTERN` may not be supported in the stored procedure context, or the pattern syntax is incompatible. The error occurs after all data has been successfully inserted.
- **Fix applied:** Manually cleaned up the pages stage after the procedure call.
- **Recommendation:** Either (a) wrap the REMOVE in a try/except so the procedure returns success even if cleanup fails, or (b) move the cleanup to a separate procedure or handle it in the task DAG.
- **Status:** Not fixed in skill file.

### F3 — INFORMATION_SCHEMA.DYNAMIC_TABLES not accessible

- **Severity:** P3 (minor; verification query fails)
- **Sub-skill:** derived-analytics (verification step)
- **Symptom:** `SELECT ... FROM AIRPORT_SAN.INFORMATION_SCHEMA.DYNAMIC_TABLES` returns `Object does not exist or not authorized`
- **Root cause:** `INFORMATION_SCHEMA.DYNAMIC_TABLES` is not available in all accounts/regions. Use `SHOW DYNAMIC TABLES IN AIRPORT_SAN.PUBLIC` instead.
- **Fix applied:** Used `SHOW DYNAMIC TABLES` for verification.
- **Recommendation:** Update `derived-analytics/SKILL.md` Step 9 verification query to use `SHOW DYNAMIC TABLES` instead of `INFORMATION_SCHEMA.DYNAMIC_TABLES`.
- **Status:** Not fixed in skill file.

### F4 — Airport search query too generic for IATA codes

- **Severity:** Info (user experience, not blocking)
- **Sub-skill:** aviation-installer (Step 3)
- **File:** `references/airport-search-query.sql`
- **Symptom:** Searching for "SAN" returns 20 results (limit hit), mostly non-SAN airports whose names contain "san" (e.g., "Santa Cruz Airport", "San Jorge Airport"). The actual San Diego airport is not in the first page of results.
- **Root cause:** The HAVING clause uses ILIKE '%{SEARCH}%' which matches "SAN" as a substring in airport names, IATA codes, and ICAO codes. For short IATA codes, this produces too many false positives.
- **Recommendation:** Add priority scoring: exact IATA match first, then exact ICAO match, then name substring match. Or add a separate filter for exact code matches.
- **Status:** Not fixed. Worked around by searching for "San Diego" instead.

---

## Object Inventory (Final State)

### AIRPORT_SAN.PUBLIC

| Object Type | Count | Status |
|-------------|-------|--------|
| Base Tables | 35 | All created (incl. FLIGHT_SCHEDULE stub) |
| Dynamic Tables | 13 | All ACTIVE, 0 rows (awaiting backfill data) |
| Views | 3 | V_AIR_OPS_TIMELINE, V_AIR_OPS_DAILY_KPIS, HELPER_LANDING_LIVE_TIMETABLE |
| Procedures | 26 | All created and callable |
| Functions/UDFs | 3 | UDF_TZID_FROM_LATLON, GET_OSM_TAG, ST_GETPOLYGONS |
| Tasks | 9 | All STARTED |

### AIRPORT_SAN.TAGS

| Tag | Status |
|-----|--------|
| SOLUTION | Created |
| COMPONENT | Created |

### Warehouse

| Object | Status |
|--------|--------|
| AVIA_SAN_WH (XSMALL) | Created, AUTO_SUSPEND=60 |

### Network & Integration Objects

| Object | Status |
|--------|--------|
| PUBLIC_adsb_lol_rule | Created |
| PUBLIC_github_rule | Created |
| PUBLIC_tsa_gov_rule | Created |
| AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI | Created |
| AIRPORT_SAN_PUBLIC_GITHUB_EAI | Created |
| AIRPORT_SAN_PUBLIC_TSA_GOV_EAI | Created |

### Streamlit

| Object | Status |
|--------|--------|
| AIRPORT_ANALYTICS_DASHBOARD | Created (url_id: qnrtat26op2l4e7vb3qq) |

### Data

| Table | Rows |
|-------|------|
| PROPERTIES_AIRPORT | 1 |
| PROPERTIES_INFRASTRUCTURE | 750 |
| PROPERTIES_GATES | 51 |
| PROPERTIES_RUNWAYS | 1 |
| HELPER_AIRLINE_DIM | 1222 |
| TSA_THROUGHPUT | 52,546 |
| ADSB_DATA | 0 (backfill running) |

### Task DAG

```
TASK_INGEST_ADSB (root, CRON 30 1 * * * UTC) — STARTED
├── TASK_ENRICH_ADSB — STARTED
│   └── TASK_REFRESH_DERIVED — STARTED
│       └── TASK_REFRESH_ANALYTICS — STARTED
├── TASK_ENRICH_AIRCRAFT_META (CRON 15 3 * * * UTC) — STARTED
├── TASK_FETCH_TSA_PDF (CRON 0 9 * * 1 America/Los_Angeles) — STARTED
│   └── TASK_EXTRACT_TSA_PDF — STARTED
├── TASK_ADSB_BACKFILL_ONCE (1 MINUTE, self-suspending) — STARTED
└── TASK_ADSB_BACKFILL_RETRY (60 MINUTE) — STARTED
```

---

## Timing

| Phase | Duration (approx) |
|-------|-------------------|
| Base Setup | ~3 min |
| ADS-B Ingestion | ~5 min |
| TSA Throughput | ~8 min (incl. AI_EXTRACT) |
| Derived Analytics | ~5 min |
| Dashboard | ~30 sec |
| Task DAG + Backfill start | ~30 sec |
| **Total** | **~22 min** |
