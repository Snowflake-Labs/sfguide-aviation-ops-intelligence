-- =============================================================================
-- ADS-B INGESTION TABLES & NETWORK
-- Database: ${DATABASE}.${SCHEMA}
-- Source: adsb.lol API
-- =============================================================================

-- -----------------------------------------------------------------------------
-- MIGRATION NOTE (non-destructive):
-- If you are upgrading an existing install that previously used ADSB_DATA_GOLD / ADSB_DATA_SILVER
-- and legacy GATES/RUNWAYS, you can optionally migrate data once:
--
-- 1) Properties tables:
--    CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_GATES     AS SELECT * FROM ${DATABASE}.${SCHEMA}.GATES;
--    CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.PROPERTIES_RUNWAYS   AS SELECT * FROM ${DATABASE}.${SCHEMA}.RUNWAYS;
--
-- 2) ADSB_DATA:
--    INSERT INTO ${DATABASE}.${SCHEMA}.ADSB_DATA (
--      FLIGHT_KEY, ICAO_HEX, REGISTRATION, TYPE, AIRCRAFT_DESC, FLIGHT, TIMESTAMP, LOCATION,
--      TRACK, TRUE_HEADING, VELOCITY, ALTITUDE_BARO, ALTITUDE_GEOM, VERTICAL_RATE, SQUAWK, CATEGORY, SOURCE
--    )
--    SELECT
--      FLIGHT_KEY, ICAO_HEX, REGISTRATION, TYPE, AIRCRAFT_DESC, FLIGHT, TIMESTAMP, LOCATION,
--      TRACK, TRUE_HEADING, VELOCITY, ALTITUDE_BARO, ALTITUDE_GEOM, VERTICAL_RATE, SQUAWK, CATEGORY, SOURCE
--    FROM ${DATABASE}.${SCHEMA}.ADSB_DATA_GOLD;
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- External Network Access (for adsb.lol API)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE NETWORK RULE ${DATABASE}.${SCHEMA}.${SCHEMA}_adsb_lol_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.adsb.lol:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ${EAI_ADSB_LOL}
  ALLOWED_NETWORK_RULES = (${DATABASE}.${SCHEMA}.${SCHEMA}_adsb_lol_rule)
  ENABLED = TRUE;

-- -----------------------------------------------------------------------------
-- HELPER raw table (Bronze layer)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.HELPER_ADSB_LOL_RAW (
    hex VARCHAR(16),
    flight VARCHAR(32),
    registration VARCHAR(16),
    aircraft_type VARCHAR(8),
    aircraft_desc VARCHAR(128),
    lat FLOAT,
    lon FLOAT,
    alt_baro INT,
    alt_geom INT,
    ground_speed FLOAT,
    track FLOAT,
    true_heading FLOAT,
    vertical_rate INT,
    squawk VARCHAR(8),
    category VARCHAR(8),
    timestamp TIMESTAMP_NTZ,
    ingested_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_ADSB_LOL_RAW 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- HELPER aircraft metadata (dimension, populated via adsb.lol lookup by ICAO_HEX)
-- Purpose: improve AIRCRAFT_DESC coverage when realtime point feed omits `desc`.
-- Docs: https://api.adsb.lol/docs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.HELPER_AIRCRAFT_META (
    ICAO_HEX VARCHAR(16),
    REGISTRATION VARCHAR(16),
    TYPE VARCHAR(8),
    AIRCRAFT_DESC VARCHAR(256),
    UPDATED_AT TIMESTAMP_NTZ,
    SOURCE VARCHAR(32),
    RAW_JSON VARIANT
);

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_AIRCRAFT_META 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- Canonical ADS-B table (single source of truth for dashboards)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA (
    FLIGHT_KEY VARCHAR(128),
    ICAO_HEX VARCHAR(16),
    REGISTRATION VARCHAR(16),
    TYPE VARCHAR(8),
    AIRCRAFT_DESC VARCHAR(128),
    FLIGHT VARCHAR(32),
    TIMESTAMP TIMESTAMP_NTZ,
    LOCATION GEOGRAPHY,
    TRACK FLOAT,
    TRUE_HEADING FLOAT,
    VELOCITY FLOAT,
    ALTITUDE_BARO INT,
    ALTITUDE_GEOM INT,
    VERTICAL_RATE INT,
    SQUAWK VARCHAR(8),
    CATEGORY VARCHAR(8),
    SOURCE VARCHAR(16),
    INGESTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    -- Schedule/enrichment fields (nullable)
    SCHEDULE_FLIGHT_KEY VARCHAR(128),
    SCHEDULE_FLIGHT_NUMBER VARCHAR(16),
    AIRLINE_NAME VARCHAR(128),
    AIRLINE_IATA VARCHAR(8),
    AIRLINE_ICAO VARCHAR(8),
    ORIGIN_AIRPORT VARCHAR(8),
    DESTINATION_AIRPORT VARCHAR(8),
    IS_LOCAL_OD BOOLEAN,
    SCHEDULED_DEPARTURE TIMESTAMP_NTZ,
    SCHEDULED_ARRIVAL TIMESTAMP_NTZ,
    MATCH_METHOD VARCHAR(32),
    MATCH_CONFIDENCE INT,
    MATCHED_AT TIMESTAMP_NTZ
);

ALTER TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- Non-destructive schema evolution for upgrades
ALTER TABLE ${DATABASE}.${SCHEMA}.ADSB_DATA ADD COLUMN IF NOT EXISTS IS_LOCAL_OD BOOLEAN;

-- -----------------------------------------------------------------------------
-- Matching observability tables (persistent, debuggable artifacts)
-- Implements Phase 0 of FLIGHT_MATCHING_RECOMMENDATIONS.md: leg inference + candidates + results
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_LEG (
  SERVICE_DATE DATE,
  ICAO_HEX STRING,
  SEG_ID INT,
  LEG_START_TS TIMESTAMP_NTZ,
  LEG_END_TS TIMESTAMP_NTZ,
  DIRECTION STRING,
  START_LOC GEOGRAPHY,
  END_LOC GEOGRAPHY,
  CALLSIGN STRING,
  REGISTRATION STRING,
  POINTS INT,
  COMPUTED_AT TIMESTAMP_NTZ
);

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_LEG 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES (
  SERVICE_DATE DATE,
  ICAO_HEX STRING,
  SEG_ID INT,
  MATCH_METHOD STRING,
  MATCH_PRIORITY INT,
  DATE_DIFF_DAYS INT,
  DIFF_MIN INT,
  ABS_DIFF_MIN INT,
  DIRECTION STRING,
  DIRECTION_OK BOOLEAN,
  SCHEDULE_FLIGHT_KEY STRING,
  SCHEDULE_FLIGHT_NUMBER STRING,
  AIRLINE_ICAO STRING,
  AIRLINE_IATA STRING,
  DEPARTURE_AIRPORT STRING,
  ARRIVAL_AIRPORT STRING,
  SCORE INT,
  CREATED_AT TIMESTAMP_NTZ
);

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_MATCH_RESULT (
  SERVICE_DATE DATE,
  ICAO_HEX STRING,
  SEG_ID INT,
  MATCH_METHOD STRING,
  MATCH_PRIORITY INT,
  DATE_DIFF_DAYS INT,
  ABS_DIFF_MIN INT,
  DIRECTION STRING,
  DIRECTION_OK BOOLEAN,
  SCHEDULE_FLIGHT_KEY STRING,
  SCHEDULE_FLIGHT_NUMBER STRING,
  SCORE INT,
  CHOSEN_AT TIMESTAMP_NTZ
);

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_MATCH_RESULT 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';

-- -----------------------------------------------------------------------------
-- Recurring callsign prior (Phase 4)
-- Built from historical leg->schedule matches to provide a conservative fallback
-- for airline + O/D when schedule matching is missing/ambiguous for a given callsign.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ${DATABASE}.${SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR (
  CALLSIGN_KEY STRING,
  AIRLINE_ICAO STRING,
  AIRLINE_IATA STRING,
  AIRLINE_NAME STRING,
  ORIGIN_AIRPORT STRING,
  DESTINATION_AIRPORT STRING,
  LEGS INT,
  LAST_SEEN_DATE DATE,
  UPDATED_AT TIMESTAMP_NTZ
);

ALTER TABLE ${DATABASE}.${SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR 
  SET TAG ${DATABASE}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          ${DATABASE}.TAGS.COMPONENT = 'etl';
