-- discovery-queries.sql
-- Run these queries to discover all sf_sit-is-aviation tagged objects before generating DROP statements.
-- Replace {TARGET_DB} with the specific airport database (e.g., AIRPORT_SAN) or use LIKE 'AIRPORT_%' to find all.

-- ============================================================
-- 1. Discover airport databases
-- ============================================================
SHOW DATABASES LIKE 'AIRPORT_%';

SELECT "name" AS DATABASE_NAME, "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE TRY_PARSE_JSON("comment"):origin::STRING = 'sf_sit-is-aviation';

-- ============================================================
-- 2. Discover Streamlit apps (dashboard)
-- ============================================================
SHOW STREAMLITS;

SELECT "name" AS APP_NAME, "database_name", "schema_name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE TRY_PARSE_JSON("comment"):origin::STRING = 'sf_sit-is-aviation';

-- ============================================================
-- 3. Discover tasks (per airport database)
-- ============================================================
-- Run for each discovered airport database:
SHOW TASKS IN DATABASE {TARGET_DB};

SELECT "name" AS TASK_NAME, "database_name", "schema_name", "state", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE TRY_PARSE_JSON("comment"):origin::STRING = 'sf_sit-is-aviation'
   OR "name" ILIKE 'TASK_%';

-- ============================================================
-- 4. Discover dynamic tables (per airport database)
-- ============================================================
SHOW DYNAMIC TABLES IN DATABASE {TARGET_DB};

SELECT "name" AS DT_NAME, "database_name", "schema_name", "scheduling_state", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE TRY_PARSE_JSON("comment"):origin::STRING = 'sf_sit-is-aviation'
   OR "name" IN (
     'ADSB_DATA_LOCAL',
     'GATE_ANALYSIS_AIRCRAFT_GROUND_SESSIONS',
     'GATE_ANALYSIS_ADSB_GROUND_POINTS',
     'GATE_ANALYSIS_FLIGHT_GATE_TIME',
     'GATE_ANALYSIS_GATE_UTIL_DAILY',
     'GATE_ANALYSIS_GATE_AIRLINE_DWELL_DAILY',
     'GATE_ANALYSIS_FLIGHT_DWELL_WITH_AIRLINE',
     'FLIGHT_TRAFFIC_FACT_ADSB_DAILY',
     'FLIGHT_TRAFFIC_FACT_ADSB_HOURLY',
     'FLIGHT_TRACKER_FLIGHT_LIST',
     'FLIGHT_TRAFFIC_FACT_AIRLINE_TRAFFIC_DAILY',
     'FLIGHT_TRAFFIC_FACT_AIRLINE_DELAY_DAILY',
     'RUNWAY_CROSSINGS_DETAILED'
   );

-- ============================================================
-- 5. Discover views (per airport database)
-- ============================================================
SELECT TABLE_NAME, TABLE_SCHEMA, TABLE_CATALOG, COMMENT
FROM {TARGET_DB}.INFORMATION_SCHEMA.VIEWS
WHERE TRY_PARSE_JSON(COMMENT):origin::STRING = 'sf_sit-is-aviation';

-- ============================================================
-- 6. Discover stored procedures (per airport database)
-- ============================================================
SELECT PROCEDURE_NAME, PROCEDURE_SCHEMA, PROCEDURE_CATALOG,
       ARGUMENT_SIGNATURE, COMMENT
FROM {TARGET_DB}.INFORMATION_SCHEMA.PROCEDURES
WHERE TRY_PARSE_JSON(COMMENT):origin::STRING = 'sf_sit-is-aviation';

-- ============================================================
-- 7. Discover functions/UDFs (per airport database)
-- ============================================================
SELECT FUNCTION_NAME, FUNCTION_SCHEMA, FUNCTION_CATALOG,
       ARGUMENT_SIGNATURE, COMMENT
FROM {TARGET_DB}.INFORMATION_SCHEMA.FUNCTIONS
WHERE TRY_PARSE_JSON(COMMENT):origin::STRING = 'sf_sit-is-aviation';

-- ============================================================
-- 8. Discover tables (per airport database)
-- ============================================================
SELECT TABLE_NAME, TABLE_SCHEMA, TABLE_CATALOG, TABLE_TYPE, ROW_COUNT, COMMENT
FROM {TARGET_DB}.INFORMATION_SCHEMA.TABLES
WHERE TRY_PARSE_JSON(COMMENT):origin::STRING = 'sf_sit-is-aviation'
  AND TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;

-- ============================================================
-- 9. Discover stages (per airport database)
-- ============================================================
SHOW STAGES IN DATABASE {TARGET_DB};

SELECT "name" AS STAGE_NAME, "database_name", "schema_name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE TRY_PARSE_JSON("comment"):origin::STRING = 'sf_sit-is-aviation';

-- ============================================================
-- 10. Discover file formats (per airport database)
-- ============================================================
SHOW FILE FORMATS IN DATABASE {TARGET_DB};

SELECT "name" AS FF_NAME, "database_name", "schema_name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ============================================================
-- 11. Discover external access integrations (account-level, by name pattern)
-- ============================================================
SHOW INTEGRATIONS;

SELECT "name" AS INTEGRATION_NAME, "type", "enabled", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE 'AIRPORT_%_EAI'
   OR "name" ILIKE 'AIRPORT_%_PYPI_ACCESS_INTEGRATION'
   OR TRY_PARSE_JSON("comment"):origin::STRING = 'sf_sit-is-aviation';

-- ============================================================
-- 12. Discover network rules (per airport database)
-- ============================================================
SHOW NETWORK RULES IN DATABASE {TARGET_DB};

SELECT "name" AS RULE_NAME, "database_name", "schema_name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ============================================================
-- 13. Discover secrets (per airport database)
-- ============================================================
SHOW SECRETS IN DATABASE {TARGET_DB};

SELECT "name" AS SECRET_NAME, "database_name", "schema_name", "comment"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE '%aviationstack%';
