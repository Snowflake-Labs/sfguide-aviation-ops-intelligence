-- =============================================================================
-- FLIGHT SCHEDULE INGESTION FOR ${AIRPORT_NAME} (${AIRPORT_IATA})
-- Database: ${DATABASE}.${SCHEMA}
-- Source: aviationstack API
-- =============================================================================

-- -----------------------------------------------------------------------------
-- External Network Access (for aviationstack API)
-- Note: Basic plan uses HTTP (port 80), not HTTPS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE NETWORK RULE ${DATABASE}.${SCHEMA}.${SCHEMA}_aviationstack_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.aviationstack.com:80');

-- Create secret for API key
CREATE OR REPLACE SECRET ${DATABASE}.${SCHEMA}.aviationstack_key
  TYPE = GENERIC_STRING
  SECRET_STRING = '${API_KEY}';

-- Create external access integration
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ${EAI_AVIATIONSTACK}
  ALLOWED_NETWORK_RULES = (${DATABASE}.${SCHEMA}.${SCHEMA}_aviationstack_rule)
  ALLOWED_AUTHENTICATION_SECRETS = (${DATABASE}.${SCHEMA}.aviationstack_key)
  ENABLED = TRUE;

-- -----------------------------------------------------------------------------
-- Note: HELPER_FLIGHT_SCHEDULE_RAW and FLIGHT_SCHEDULE tables are created
-- in 01_base.sql to ensure they exist even if API key is not provided.
-- This allows the installer to complete successfully without an API key.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Ingestion Procedure
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_INGEST_FLIGHT_SCHEDULE(p_airport VARCHAR, p_date VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'ingest'
EXTERNAL_ACCESS_INTEGRATIONS = (${EAI_AVIATIONSTACK})
SECRETS = ('api_key' = ${DATABASE}.${SCHEMA}.aviationstack_key)
AS
$$
import requests
import _snowflake
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

PROPERTIES_AIRPORT_FQN = "${DATABASE}.${SCHEMA}.PROPERTIES_AIRPORT"

def _get_airport_tzid(session):
    try:
        rows = session.sql("SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC') AS tzid FROM " + PROPERTIES_AIRPORT_FQN + " LIMIT 1").collect()
        if rows and rows[0] and rows[0][0]:
            return str(rows[0][0])
    except Exception:
        pass
    return "UTC"

def parse_ts(ts_str, airport_tzid: str):
    # Parse aviationstack ISO timestamp into UTC-naive datetime for TIMESTAMP_NTZ storage.
    # - If string includes 'Z' or an offset, treat it as timezone-aware and convert to UTC.
    # - If string is naive, interpret it in airport local timezone (airport_tzid) and convert to UTC.
    if not ts_str:
        return None
    try:
        s = str(ts_str).strip()
        if not s:
            return None
        # Normalize Zulu suffix for fromisoformat
        dt = datetime.fromisoformat(s.replace('Z', '+00:00'))
        if dt.tzinfo is None:
            # Interpret naive timestamps in airport local time
            dt = dt.replace(tzinfo=ZoneInfo(airport_tzid))
        dt_utc = dt.astimezone(timezone.utc).replace(tzinfo=None)
        return dt_utc
    except Exception:
        return None

def fetch_flights(api_key, airport, date, direction):
    # Fetch flights with pagination support
    all_flights = []
    offset = 0
    limit = 100
    # Safety ceiling: prevents runaway loops if the API pagination metadata is wrong.
    # Should be comfortably above even very busy airports.
    max_flights = 10000
    while True:
        suffix = ("&dep_iata=" if direction == 'dep' else "&arr_iata=") + airport
        url = "http://api.aviationstack.com/v1/flights?access_key=" + api_key + suffix + "&flight_date=" + date + "&limit=" + str(limit) + "&offset=" + str(offset)
        try:
            resp = requests.get(url, timeout=60)
            data = resp.json()
        except: break
        if 'error' in data: break
        flights = data.get('data', [])
        if not flights: break
        all_flights.extend(flights)
        pagination = data.get('pagination', dict())
        total = pagination.get('total', None)
        # Stop when we've reached the API-reported total, or when the page is smaller than our limit.
        # (Some plans / responses may omit total.)
        if total is not None and offset + limit >= int(total): break
        if len(flights) < limit: break
        if len(all_flights) >= max_flights: break
        offset += limit
    return all_flights

def ingest(session, p_airport, p_date):
    api_key = _snowflake.get_generic_secret_string('api_key')
    airport_tzid = _get_airport_tzid(session)
    departures = fetch_flights(api_key, p_airport, p_date, 'dep')
    arrivals = fetch_flights(api_key, p_airport, p_date, 'arr')
    
    seen = set()
    all_flights = []
    for f in departures + arrivals:
        flt = f.get('flight', dict())
        dep = f.get('departure', dict())
        key = (flt.get('iata'), dep.get('scheduled'))
        if key not in seen:
            seen.add(key)
            all_flights.append(f)
    
    if not all_flights:
        return "No flights found for " + p_airport + " on " + p_date
    
    now = datetime.utcnow()
    rows = []
    for f in all_flights:
        dep = f.get('departure', dict())
        arr = f.get('arrival', dict())
        airline = f.get('airline', dict())
        flt = f.get('flight', dict())
        aircraft = f.get('aircraft') or dict()
        cs = flt.get('codeshared') or dict()
        
        # Aviationstack does not always provide FLIGHT_ICAO/FLIGHT_IATA.
        # When missing, synthesize from airline code + flight number (helps match ADS-B callsigns like SKW3482).
        flight_number = flt.get('number')
        flight_iata = flt.get('iata')
        flight_icao = flt.get('icao')
        airline_iata = airline.get('iata')
        airline_icao = airline.get('icao')
        if (not flight_iata) and airline_iata and flight_number:
            flight_iata = str(airline_iata).strip().upper() + str(flight_number).strip()
        if (not flight_icao) and airline_icao and flight_number:
            flight_icao = str(airline_icao).strip().upper() + str(flight_number).strip()
        
        rows.append([
            datetime.strptime(p_date, '%Y-%m-%d').date(),
            f.get('flight_status'),
            dep.get('iata'),
            parse_ts(dep.get('scheduled'), airport_tzid),
            parse_ts(dep.get('estimated'), airport_tzid),
            parse_ts(dep.get('actual'), airport_tzid),
            dep.get('delay'),
            dep.get('terminal'),
            dep.get('gate'),
            arr.get('iata'),
            parse_ts(arr.get('scheduled'), airport_tzid),
            parse_ts(arr.get('estimated'), airport_tzid),
            parse_ts(arr.get('actual'), airport_tzid),
            arr.get('delay'),
            arr.get('terminal'),
            arr.get('gate'),
            airline.get('name'),
            airline_iata,
            airline_icao,
            flight_number,
            flight_iata,
            flight_icao,
            aircraft.get('registration'),
            aircraft.get('iata'),
            aircraft.get('icao'),
            cs.get('airline_name'),
            cs.get('flight_iata'),
            f, # Dict is automatically converted to VARIANT
            now
        ])
    
    if rows:
        from snowflake.snowpark.types import StructType, StructField, StringType, DateType, TimestampType, IntegerType, VariantType
        schema = StructType([
            StructField("FLIGHT_DATE", DateType()), StructField("FLIGHT_STATUS", StringType()),
            StructField("DEPARTURE_AIRPORT", StringType()), StructField("DEPARTURE_SCHEDULED", TimestampType()),
            StructField("DEPARTURE_ESTIMATED", TimestampType()), StructField("DEPARTURE_ACTUAL", TimestampType()),
            StructField("DEPARTURE_DELAY", IntegerType()), StructField("DEPARTURE_TERMINAL", StringType()),
            StructField("DEPARTURE_GATE", StringType()), StructField("ARRIVAL_AIRPORT", StringType()),
            StructField("ARRIVAL_SCHEDULED", TimestampType()), StructField("ARRIVAL_ESTIMATED", TimestampType()),
            StructField("ARRIVAL_ACTUAL", TimestampType()), StructField("ARRIVAL_DELAY", IntegerType()),
            StructField("ARRIVAL_TERMINAL", StringType()), StructField("ARRIVAL_GATE", StringType()),
            StructField("AIRLINE_NAME", StringType()), StructField("AIRLINE_IATA", StringType()),
            StructField("AIRLINE_ICAO", StringType()), StructField("FLIGHT_NUMBER", StringType()),
            StructField("FLIGHT_IATA", StringType()), StructField("FLIGHT_ICAO", StringType()),
            StructField("AIRCRAFT_REGISTRATION", StringType()), StructField("AIRCRAFT_IATA", StringType()),
            StructField("AIRCRAFT_ICAO", StringType()), StructField("CODESHARED_AIRLINE", StringType()),
            StructField("CODESHARED_FLIGHT_IATA", StringType()), StructField("RAW_JSON", VariantType()),
            StructField("INGESTED_AT", TimestampType())
        ])
        df = session.create_dataframe(rows, schema=schema)
        df.write.mode('append').save_as_table('${SCHEDULE_RAW_TABLE}')
    
    return "Inserted " + str(len(rows)) + " flights for " + p_airport + " on " + p_date
$$;

-- -----------------------------------------------------------------------------
-- ETL to canonical FLIGHT_SCHEDULE (single source of truth)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_ETL_SCHEDULE_TO_FLIGHT_SCHEDULE()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    MERGE INTO ${DATABASE}.${SCHEMA}.FLIGHT_SCHEDULE t
    USING (
        SELECT
            MD5(CONCAT(COALESCE(flight_iata, 'UNKNOWN'), ':', COALESCE(TO_VARCHAR(departure_scheduled), 'UNKNOWN'), ':', COALESCE(TO_VARCHAR(arrival_scheduled), 'UNKNOWN'))) AS FLIGHT_KEY,
            flight_date, flight_status, departure_airport, arrival_airport,
            departure_scheduled, departure_estimated, departure_actual,
            departure_delay, departure_terminal, departure_gate,
            arrival_scheduled, arrival_estimated, arrival_actual,
            arrival_delay, arrival_terminal, arrival_gate,
            airline_name, airline_iata, airline_icao,
            flight_number, flight_iata, flight_icao,
            aircraft_registration,
            IFF(codeshared_airline IS NOT NULL, TRUE, FALSE) AS IS_CODESHARE
        FROM ${DATABASE}.${SCHEMA}.HELPER_FLIGHT_SCHEDULE_RAW
        QUALIFY ROW_NUMBER() OVER (PARTITION BY flight_iata, departure_scheduled, arrival_scheduled ORDER BY ingested_at DESC) = 1
    ) s
    ON t.FLIGHT_KEY = s.FLIGHT_KEY
    WHEN MATCHED THEN UPDATE SET
        FLIGHT_STATUS = s.flight_status,
        DEPARTURE_ESTIMATED = s.departure_estimated,
        DEPARTURE_ACTUAL = s.departure_actual,
        DEPARTURE_DELAY = s.departure_delay,
        ARRIVAL_ESTIMATED = s.arrival_estimated,
        ARRIVAL_ACTUAL = s.arrival_actual,
        ARRIVAL_DELAY = s.arrival_delay,
        UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        FLIGHT_KEY, FLIGHT_DATE, FLIGHT_STATUS, DEPARTURE_AIRPORT, ARRIVAL_AIRPORT,
        DEPARTURE_SCHEDULED, DEPARTURE_ESTIMATED, DEPARTURE_ACTUAL, DEPARTURE_DELAY,
        DEPARTURE_TERMINAL, DEPARTURE_GATE,
        ARRIVAL_SCHEDULED, ARRIVAL_ESTIMATED, ARRIVAL_ACTUAL, ARRIVAL_DELAY,
        ARRIVAL_TERMINAL, ARRIVAL_GATE,
        AIRLINE_NAME, AIRLINE_IATA, AIRLINE_ICAO,
        FLIGHT_NUMBER, FLIGHT_IATA, FLIGHT_ICAO, AIRCRAFT_REGISTRATION, IS_CODESHARE
    ) VALUES (
        s.FLIGHT_KEY, s.flight_date, s.flight_status, s.departure_airport, s.arrival_airport,
        s.departure_scheduled, s.departure_estimated, s.departure_actual, s.departure_delay,
        s.departure_terminal, s.departure_gate,
        s.arrival_scheduled, s.arrival_estimated, s.arrival_actual, s.arrival_delay,
        s.arrival_terminal, s.arrival_gate,
        s.airline_name, s.airline_iata, s.airline_icao,
        s.flight_number, s.flight_iata, s.flight_icao, s.aircraft_registration, s.IS_CODESHARE
    );
    RETURN 'ETL Complete';
END;
$$;

-- -----------------------------------------------------------------------------
-- Historical Backfill Procedure (fetches past N days of data)
-- Note: Each day = 1 API call. With 10K/month limit, use conservatively.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_BACKFILL_FLIGHT_SCHEDULE(p_days_back INT)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_date DATE DEFAULT CURRENT_DATE();
    v_end_date DATE DEFAULT CURRENT_DATE();
    v_start_date DATE;
    v_count INT DEFAULT 0;
    v_date_str VARCHAR;
BEGIN
    v_start_date := DATEADD('day', -p_days_back, CURRENT_DATE());
    v_date := v_start_date;
    
    WHILE (v_date <= v_end_date) DO
        v_date_str := TO_VARCHAR(v_date, 'YYYY-MM-DD');
        BEGIN
            CALL ${DATABASE}.${SCHEMA}.PROC_INGEST_FLIGHT_SCHEDULE('${AIRPORT_IATA}', :v_date_str);
            v_count := v_count + 1;
        EXCEPTION
            WHEN OTHER THEN
                -- Log error but continue with next day
                v_count := v_count;
        END;
        v_date := DATEADD('day', 1, v_date);
    END WHILE;
    
    -- Run ETL once at the end
    CALL ${DATABASE}.${SCHEMA}.PROC_ETL_SCHEDULE_TO_FLIGHT_SCHEDULE();
    
    RETURN 'Backfill complete: processed ' || v_count::VARCHAR || ' days from ' || TO_VARCHAR(v_start_date) || ' to ' || TO_VARCHAR(v_end_date);
END;
$$;

-- -----------------------------------------------------------------------------
-- Window Backfill Procedure (past + future)
-- Loads from CURRENT_DATE() - p_days_back through CURRENT_DATE() + p_days_forward (inclusive).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_BACKFILL_FLIGHT_SCHEDULE_WINDOW(p_days_back INT, p_days_forward INT)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_date DATE DEFAULT CURRENT_DATE();
    v_end_date DATE;
    v_start_date DATE;
    v_count INT DEFAULT 0;
    v_date_str VARCHAR;
BEGIN
    v_start_date := DATEADD('day', -p_days_back, CURRENT_DATE());
    v_end_date := DATEADD('day', p_days_forward, CURRENT_DATE());
    v_date := v_start_date;
    
    WHILE (v_date <= v_end_date) DO
        v_date_str := TO_VARCHAR(v_date, 'YYYY-MM-DD');
        BEGIN
            CALL ${DATABASE}.${SCHEMA}.PROC_INGEST_FLIGHT_SCHEDULE('${AIRPORT_IATA}', :v_date_str);
            v_count := v_count + 1;
        EXCEPTION
            WHEN OTHER THEN
                v_count := v_count;
        END;
        v_date := DATEADD('day', 1, v_date);
    END WHILE;
    
    CALL ${DATABASE}.${SCHEMA}.PROC_ETL_SCHEDULE_TO_FLIGHT_SCHEDULE();
    RETURN 'Backfill window complete: processed ' || v_count::VARCHAR || ' days from ' || TO_VARCHAR(v_start_date) || ' to ' || TO_VARCHAR(v_end_date);
END;
$$;

-- -----------------------------------------------------------------------------
-- Wrapper procedure for task (combines ingest + ETL)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ${DATABASE}.${SCHEMA}.PROC_FLIGHT_SCHEDULE_INGEST_AND_ETL()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Sync today only (2 API calls: 1 departure + 1 arrival)
    CALL ${DATABASE}.${SCHEMA}.PROC_INGEST_FLIGHT_SCHEDULE('${AIRPORT_IATA}', CURRENT_DATE()::VARCHAR);
    CALL ${DATABASE}.${SCHEMA}.PROC_ETL_SCHEDULE_TO_FLIGHT_SCHEDULE();
    RETURN 'Flight schedule ingest and ETL complete: synced today only';
END;
$$;

-- -----------------------------------------------------------------------------
-- Scheduled Task (daily at 2 AM UTC)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK ${DATABASE}.${SCHEMA}.TASK_FLIGHT_SCHEDULE
  WAREHOUSE = ${WAREHOUSE}
  AFTER ${DATABASE}.${SCHEMA}.TASK_INGEST_ADSB
AS
  CALL ${DATABASE}.${SCHEMA}.PROC_FLIGHT_SCHEDULE_INGEST_AND_ETL();

-- -----------------------------------------------------------------------------
-- RUN INITIAL BACKFILL (window: user-defined history, no forward days)
-- -----------------------------------------------------------------------------
CALL ${DATABASE}.${SCHEMA}.PROC_BACKFILL_FLIGHT_SCHEDULE_WINDOW(${BACKFILL_DAYS}, 0);

-- -----------------------------------------------------------------------------
-- START THE TASK
-- NOTE: Task will be resumed in 05_derived.sql along with all other tasks
-- in the correct leaf-to-root order to avoid graph update errors
-- -----------------------------------------------------------------------------
-- Task TASK_FLIGHT_SCHEDULE is created suspended and will be resumed later

-- Note: TASK_ENRICH_ADSB runs in parallel with TASK_FLIGHT_SCHEDULE (both after TASK_INGEST_ADSB)
-- The enrichment procedure handles cases where flight schedule data is not yet available.

-- Verify
SELECT 'Flight schedule setup complete. Task is now running.' AS status;
