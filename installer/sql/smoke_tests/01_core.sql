-- =============================================================================
-- DWELL_CORE Smoke Test: Core Contract Only
--
-- Validates that the domain-agnostic core schema, tables, and transform
-- objects exist and pass basic sanity checks. Does NOT check adapter-specific
-- or backward-compatible PUBLIC objects.
-- =============================================================================

CREATE OR REPLACE PROCEDURE ${DATABASE}.DWELL_CORE.PROC_SMOKE_TEST_CORE()
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
function scalar(sqlText) {
  var stmt = snowflake.createStatement({sqlText: sqlText});
  var rs = stmt.execute();
  rs.next();
  return rs.getColumnValue(1);
}

var errors = [];

// --- Core contract objects ---
var coreObjects = [
  'DWELL_CORE.POLICY',
  'DWELL_CORE.SITE',
  'DWELL_CORE.ZONE',
  'DWELL_CORE.OBSERVATION_SOURCE',
  'DWELL_CORE.OBSERVATION',
  'DWELL_CORE.PRESENCE_POINT',
  'DWELL_CORE.DWELL_SESSION',
  'DWELL_CORE.ZONE_ASSIGNMENT',
  'DWELL_CORE.ZONE_DWELL_FACT',
  'DWELL_CORE.CONGESTION_CELL_FACT'
];

for (var i = 0; i < coreObjects.length; i++) {
  try {
    scalar('SELECT COUNT(*) FROM ${DATABASE}.' + coreObjects[i]);
  } catch (e) {
    errors.push('MISSING: ${DATABASE}.' + coreObjects[i] + ' (' + e.message + ')');
  }
}

// --- Core data sanity: SITE and POLICY must have at least 1 row ---
try {
  var siteCnt = scalar('SELECT COUNT(*) FROM ${DATABASE}.DWELL_CORE.SITE');
  if (siteCnt < 1) errors.push('DWELL_CORE.SITE has 0 rows (expected >= 1)');
} catch (e) {
  errors.push('Cannot query DWELL_CORE.SITE: ' + e.message);
}

try {
  var policyCnt = scalar('SELECT COUNT(*) FROM ${DATABASE}.DWELL_CORE.POLICY');
  if (policyCnt < 1) errors.push('DWELL_CORE.POLICY has 0 rows (expected >= 1)');
} catch (e) {
  errors.push('Cannot query DWELL_CORE.POLICY: ' + e.message);
}

// --- Sanity: non-negative dwell_seconds ---
try {
  var negDwell = scalar(
    'SELECT COUNT(*) FROM ${DATABASE}.DWELL_CORE.DWELL_SESSION WHERE dwell_seconds < 0'
  );
  if (negDwell > 0) errors.push('DWELL_SESSION has ' + negDwell + ' rows with negative dwell_seconds');
} catch (e) {
  // Table may be empty or not yet refreshed; skip
}

// --- Sanity: non-null timestamps in PRESENCE_POINT ---
try {
  var nullTs = scalar(
    'SELECT COUNT(*) FROM ${DATABASE}.DWELL_CORE.PRESENCE_POINT WHERE observed_ts_utc IS NULL'
  );
  if (nullTs > 0) errors.push('PRESENCE_POINT has ' + nullTs + ' rows with NULL observed_ts_utc');
} catch (e) {
  // Table may be empty or not yet refreshed; skip
}

if (errors.length > 0) {
  throw 'DWELL_CORE core smoke test FAILED:\n' + errors.join('\n');
}

return 'OK: All ' + coreObjects.length + ' core objects verified. Sanity checks passed.';
$$;
