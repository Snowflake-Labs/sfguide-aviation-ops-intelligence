-- =============================================================================
-- Smoke Test: Airport Adapter + Backward-Compatible PUBLIC Objects
--
-- Validates that all PUBLIC dashboard objects created by the airport adapter
-- and compatibility layer exist and are queryable. Run this after a full
-- airport install (not applicable for BYO or non-airport adapters).
-- =============================================================================

CREATE OR REPLACE PROCEDURE ${DATABASE}.DWELL_CORE.PROC_SMOKE_TEST_AIRPORT()
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

// --- Backward-compatible PUBLIC objects used by the airport dashboard ---
var publicObjects = [
  '${SCHEMA}.ADSB_DATA',
  '${SCHEMA}.ADSB_DATA_LOCAL',
  '${SCHEMA}.PROPERTIES_AIRPORT',
  '${SCHEMA}.PROPERTIES_GATES',
  '${SCHEMA}.PROPERTIES_RUNWAYS',
  '${SCHEMA}.GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS',
  '${SCHEMA}.GATE_ANALYSIS_ADSB_GROUND_POINTS',
  '${SCHEMA}.GATE_ANALYSIS_FLIGHT_GATE_TIME',
  '${SCHEMA}.GATE_ANALYSIS_GATE_UTIL_DAILY',
  '${SCHEMA}.GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY',
  '${SCHEMA}.GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE',
  '${SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_HOURLY',
  '${SCHEMA}.FLIGHT_TRAFFIC_FACT_ADSB_DAILY',
  '${SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY',
  '${SCHEMA}.FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY',
  '${SCHEMA}.FLIGHT_TRACKER_FLIGHT_LIST',
  '${SCHEMA}.RUNWAY_CROSSINGS_DETAILED',
  '${SCHEMA}.HELPER_LANDING_LIVE_TIMETABLE'
];

for (var j = 0; j < publicObjects.length; j++) {
  try {
    scalar('SELECT COUNT(*) FROM ${DATABASE}.' + publicObjects[j]);
  } catch (e) {
    errors.push('MISSING PUBLIC: ${DATABASE}.' + publicObjects[j] + ' (' + e.message + ')');
  }
}

if (errors.length > 0) {
  throw 'Airport compat smoke test FAILED:\n' + errors.join('\n');
}

return 'OK: All ' + publicObjects.length + ' airport PUBLIC objects verified.';
$$;
