# ADS-B Tables

> **Placeholders** (replaced by the skill at generation time):
> - `{TARGET_DB}` — Snowflake database, e.g. `AIRPORT_SAN`
> - `{SCHEMA}` — Schema, e.g. `PUBLIC`
> - `{WAREHOUSE}` — Warehouse name
> - `{EAI_ADSB_LOL}` — External Access Integration name for adsb.lol (e.g. `AIRPORT_SAN_PUBLIC_ADSB_LOL_EAI`)
> - `{EAI_GITHUB}` — External Access Integration name for GitHub (e.g. `AIRPORT_SAN_PUBLIC_GITHUB_EAI`)
> - `{API_URL}` — adsb.lol API endpoint with lat/lon/radius (e.g. `https://api.adsb.lol/v2/point/32.7336/-117.1897/27`)
> - `{BACKFILL_DAYS}` — Number of historical days to backfill (e.g. `7`)
> - `{IATA}` — Airport IATA code (e.g. `SAN`)

The **COMMENT tag** used on every `CREATE` statement:
```
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
```


---

## Step 2: ADS-B Tables

### HELPER_ADSB_LOL_RAW

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW (
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
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_LOL_RAW 
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### HELPER_AIRCRAFT_META

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.HELPER_AIRCRAFT_META (
    ICAO_HEX VARCHAR(16),
    REGISTRATION VARCHAR(16),
    TYPE VARCHAR(8),
    AIRCRAFT_DESC VARCHAR(256),
    UPDATED_AT TIMESTAMP_NTZ,
    SOURCE VARCHAR(32),
    RAW_JSON VARIANT
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_AIRCRAFT_META 
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### ADSB_DATA

```sql
CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA (
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
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA 
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';

-- Non-destructive schema evolution for upgrades
ALTER TABLE {TARGET_DB}.{SCHEMA}.ADSB_DATA ADD COLUMN IF NOT EXISTS IS_LOCAL_OD BOOLEAN;
```

### HELPER_FLIGHT_LEG

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG (
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
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG 
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### HELPER_FLIGHT_MATCH_CANDIDATES

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES (
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
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES 
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### HELPER_FLIGHT_MATCH_RESULT

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_RESULT (
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
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_RESULT 
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### HELPER_RECURRING_CALLSIGN_PRIOR

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR (
  CALLSIGN_KEY STRING,
  AIRLINE_ICAO STRING,
  AIRLINE_IATA STRING,
  AIRLINE_NAME STRING,
  ORIGIN_AIRPORT STRING,
  DESTINATION_AIRPORT STRING,
  LEGS INT,
  LAST_SEEN_DATE DATE,
  UPDATED_AT TIMESTAMP_NTZ
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR 
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

---

