# Skill Execution Logs

This directory collects error reports and friction logs from skill executions. Logs help improve skills by capturing real-world failures, unexpected states, and workarounds.

## When to Log

### Error Logs (on failure only)

Log an entry whenever a skill execution encounters:
- **SQL errors** — query compilation failures, runtime exceptions, permission denied
- **Missing objects** — table/view/schema/database/stage not found when expected
- **Unexpected data** — 0 rows returned, NULL columns, wrong row counts, data type mismatches
- **Service failures** — SPCS container errors, health checks failing, dashboard not reachable
- **Deployment failures** — Docker build errors, image push failures, Streamlit deployment issues
- **Workarounds applied** — any time you had to deviate from the documented steps to make something work
- **Ambiguous instructions** — steps in the SKILL.md that were unclear, missing, or contradictory

### Friction Logs (every run — mandatory)

A friction log is generated after EVERY `aviation-installer` execution, regardless of outcome. Unlike error logs (created only on failure), friction logs are ALWAYS created — even when everything goes smoothly.

## Log File Format

### Error Logs

One file per skill execution. **File name:** `{skill-name}_{YYYY-MM-DD}_{HH-MM}.md`

Example: `aviation-installer_2026-04-16_14-30.md`

#### Template

```markdown
# {Skill Name} — Execution Log

- **Date:** {YYYY-MM-DD HH:MM}
- **Skill:** {skill-name}
- **Connection:** {snowflake connection name}
- **Role:** {current role}
- **Warehouse:** {current warehouse}
- **Outcome:** {COMPLETED_WITH_ISSUES | FAILED | COMPLETED_WITH_WORKAROUNDS}

## Issues

### Issue 1: {Short title}

- **Step:** {Step number/name from SKILL.md}
- **Severity:** {BLOCKER | ERROR | WARNING | INFO}
- **Category:** {SQL_ERROR | MISSING_OBJECT | UNEXPECTED_DATA | SERVICE_FAILURE | DEPLOYMENT_FAILURE | PERMISSION_ERROR | DOCS_GAP | WORKAROUND}

**What happened:**
{Description of the issue}

**SQL/Command that failed:**
```sql
{The exact SQL or bash command}
```

**Error message:**
```
{The exact error message returned}
```

**Resolution:**
{How was it resolved, or "UNRESOLVED" if it blocked execution}

**Suggested fix:**
{What should change in the SKILL.md or reference files to prevent this}

---

### Issue 2: ...
```

## Severity Levels

| Level | Meaning |
|-------|---------|
| BLOCKER | Execution cannot continue, skill failed |
| ERROR | Step failed but was recoverable or skippable |
| WARNING | Unexpected state that didn't block but may indicate a problem |
| INFO | Minor issue or documentation improvement suggestion |

## Categories

| Category | Examples |
|----------|----------|
| SQL_ERROR | Syntax error, compilation failure, runtime exception |
| MISSING_OBJECT | Table/view/schema/database/function/stage not found |
| UNEXPECTED_DATA | 0 rows, NULL values, wrong counts, type mismatch |
| SERVICE_FAILURE | SPCS service won't start, dashboard health check fails |
| DEPLOYMENT_FAILURE | Docker build fails, image push fails, Streamlit deploy fails |
| PERMISSION_ERROR | Insufficient privileges, role doesn't have access |
| DOCS_GAP | SKILL.md instructions unclear, missing, or wrong |
| WORKAROUND | Had to deviate from documented steps |

---

## Friction Logs (Mandatory for aviation-installer)

A friction log is generated after EVERY `aviation-installer` execution, regardless of outcome. Unlike error logs (created only on failure), friction logs are ALWAYS created.

**File name:** `friction-log_{YYYY-MM-DD}_{HH-MM}.md`

### Template

```markdown
# Friction Log — Aviation Installer

- **Date:** {YYYY-MM-DD HH:MM}
- **Airport:** {Airport Name} ({IATA} / {ICAO})
- **Connection:** {snowflake connection name}
- **Role:** {current role}
- **Warehouse:** {warehouse name}
- **Outcome:** {SUCCESS | COMPLETED_WITH_ISSUES | FAILED}

## Configuration

| Parameter | Value |
|-----------|-------|
| Target Database | {TARGET_DB} |
| Schema | {SCHEMA} |
| Warehouse | {WAREHOUSE} |
| Aviationstack Key | {provided / skipped} |
| TSA Throughput | {enabled / skipped} |
| Backfill Days | {N} |
| Dashboard Type | {Streamlit / React-SPCS} |
| Overture Maps ID | {AIRPORT_ID} |

## Step Timing

| Step | Status | Duration | Notes |
|------|--------|----------|-------|
| 1: Query tag | {OK/FAILED/SKIPPED} | {duration} | |
| 2: Marketplace deps | {OK/FAILED/SKIPPED} | {duration} | |
| 3: Select airport | {OK/FAILED/SKIPPED} | {duration} | |
| 4: Gather config | {OK/FAILED/SKIPPED} | {duration} | |
| 5: Git repo stage | {OK/FAILED/SKIPPED} | {duration} | |
| 6a: Base setup | {OK/FAILED/SKIPPED} | {duration} | {object counts} |
| 6b: ADS-B ingestion | {OK/FAILED/SKIPPED} | {duration} | {proc/task counts} |
| 6c: Flight schedules | {OK/FAILED/SKIPPED} | {duration} | |
| 6d: TSA throughput | {OK/FAILED/SKIPPED} | {duration} | {row count} |
| 6e: Derived analytics | {OK/FAILED/SKIPPED} | {duration} | {DT count} |
| 6f: Dashboard | {OK/FAILED/SKIPPED} | {duration} | {Streamlit or SPCS} |
| 7: Start task DAG | {OK/FAILED/SKIPPED} | {duration} | {task count} |
| 8: Initial data load | {OK/FAILED/SKIPPED} | {duration} | {ADSB_DATA rows} |
| 9: Verify install | {OK/FAILED/SKIPPED} | {duration} | |
| 10: Friction log | {OK/FAILED/SKIPPED} | {duration} | This file |

## Objects Created

| Category | Count |
|----------|-------|
| Database | {N} |
| Schemas | {N} |
| Tables | {N} |
| Dynamic Tables | {N} |
| Views | {N} |
| Procedures | {N} |
| Functions (UDFs) | {N} |
| Tasks | {N} |
| Tags | {N} |
| Stages | {N} |
| Network Rules | {N} |
| External Access Integrations | {N} |

## Initial Data

| Table | Rows |
|-------|------|
| PROPERTIES_AIRPORT | {N} |
| PROPERTIES_INFRASTRUCTURE | {N} |
| PROPERTIES_GATES | {N} |
| PROPERTIES_RUNWAYS | {N} |
| HELPER_AIRLINE_DIM | {N} |
| ADSB_DATA | {N} |
| TSA_THROUGHPUT | {N} |

## Friction Points

### F1: {Short title}

- **Step:** {Step number/name}
- **Severity:** {High | Medium | Low}
- **What happened:** {Description of the friction}
- **Resolution:** {What was done during this run to work around or fix the problem}
- **Recommendation:** {What should change in the skill, reference docs, or tooling to prevent this in future runs}

---

### F2: ...

{If no friction points: "No friction points encountered."}

## Verification Checklist

- [ ] PROPERTIES_AIRPORT: {N} row(s)
- [ ] PROPERTIES_GATES: {N} gates
- [ ] PROPERTIES_RUNWAYS: {N} runways
- [ ] HELPER_AIRLINE_DIM: {N} airlines
- [ ] ADSB_DATA: {N} initial positions
- [ ] Dynamic Tables: All ACTIVE
- [ ] Tasks: All STARTED
- [ ] EAIs: All ENABLED
- [ ] Dashboard: {deployed / not deployed}

## Summary

- **Total execution time:** {X minutes}
- **Objects created:** {total count}
- **Issues encountered:** {count} friction points ({N} high, {N} medium, {N} low)
- **Recommendations count:** {number of actionable recommendations for skill improvements}
```
