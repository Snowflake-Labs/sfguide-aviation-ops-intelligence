# Enrichment Procedures

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

## Step 3: PROC_ENRICH_ADSB_WITH_SCHEDULE

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(p_days_back INT)
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
DECLARE
  v_days INT;
  v_src_rows NUMBER(38,0);
  v_merge_rows NUMBER(38,0);
  v_tzid STRING;
  v_utc_now TIMESTAMP_NTZ;
  v_local_today DATE;
BEGIN
  v_days := COALESCE(:p_days_back, 2);

  -- Airport-local service day (for matching) using PROPERTIES_AIRPORT.AIRPORT_TZID
  SELECT TO_TIMESTAMP_NTZ(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()))
    INTO :v_utc_now;
  SELECT COALESCE(NULLIF(airport_tzid, ''), 'UTC')
    INTO :v_tzid
  FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
  LIMIT 1;
  SELECT TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, :v_utc_now))
    INTO :v_local_today;

  -- Self-heal: duplicates in ADSB_DATA (by ICAO_HEX,TIMESTAMP) cause MERGE to fail with:
  --   "Duplicate row detected during DML action"
  -- This can happen from older installer versions / parallel loads.
  -- Keep newest INGESTED_AT per key within the enrichment window.
  DELETE FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
  WHERE (ICAO_HEX, TIMESTAMP, INGESTED_AT) IN (
    SELECT ICAO_HEX, TIMESTAMP, INGESTED_AT
    FROM (
      SELECT
        ICAO_HEX,
        TIMESTAMP,
        INGESTED_AT,
        ROW_NUMBER() OVER (
          PARTITION BY ICAO_HEX, TIMESTAMP
          ORDER BY INGESTED_AT DESC
        ) AS rn
      FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
      WHERE TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP)) >= DATEADD('day', -:v_days, :v_local_today)
        AND ICAO_HEX IS NOT NULL
        AND TIMESTAMP IS NOT NULL
    )
    WHERE rn > 1
  );

  -- Source sanity: use calendar days (UTC date) rather than "last N hours"
  SELECT COUNT(*) INTO v_src_rows
  FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
  WHERE TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP)) >= DATEADD('day', -:v_days, :v_local_today)
    AND ICAO_HEX IS NOT NULL
    AND TIMESTAMP IS NOT NULL;

  IF (v_src_rows = 0) THEN
    RETURN 'Enrichment skipped: no ADSB_DATA rows in last ' || :v_days || ' days';
  END IF;

  -- 1) Build airborne segments ("legs") per aircraft/day using a simple ground/air state machine.
  CREATE OR REPLACE TEMP TABLE tmp_airborne_leg AS
  WITH pts AS (
    SELECT
      ICAO_HEX,
      REGISTRATION,
      FLIGHT,
      TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP)) AS service_date,
      TIMESTAMP AS ts,
      LOCATION,
      VELOCITY,
      ALTITUDE_BARO,
      -- Treat low-speed points as ground even if ALTITUDE_BARO is missing (common in realtime feeds).
      IFF(
        COALESCE(VELOCITY, 0) <= 40
        AND (
          ALTITUDE_BARO IS NULL
          OR ALTITUDE_BARO <= 50
        ),
        1, 0
      ) AS is_ground,
      DATEDIFF(
        'minute',
        LAG(TIMESTAMP) OVER (
          PARTITION BY ICAO_HEX, TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP))
          ORDER BY TIMESTAMP
        ),
        TIMESTAMP
      ) AS gap_min,
      LAG(IFF(
            COALESCE(VELOCITY, 0) <= 40
            AND (ALTITUDE_BARO IS NULL OR ALTITUDE_BARO <= 50),
            1, 0
          ))
        OVER (
          PARTITION BY ICAO_HEX, TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP))
          ORDER BY TIMESTAMP
        ) AS prev_is_ground
    FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
    WHERE TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP)) >= DATEADD('day', -:v_days, :v_local_today)
      AND ICAO_HEX IS NOT NULL
      AND LOCATION IS NOT NULL
      AND TIMESTAMP IS NOT NULL
  ),
  seg AS (
    SELECT
      *,
      SUM(IFF(COALESCE(gap_min, 999999) > 20 OR COALESCE(prev_is_ground, is_ground) <> is_ground, 1, 0))
        OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts ROWS UNBOUNDED PRECEDING) AS seg_id
    FROM pts
  ),
  airborne AS (
    SELECT *
    FROM seg
    WHERE is_ground = 0
  )
  SELECT
    ICAO_HEX,
    service_date,
    seg_id,
    MIN(ts) AS leg_start_ts,
    MAX(ts) AS leg_end_ts,
    MAX(REGISTRATION) AS registration,
    MAX(NULLIF(UPPER(TRIM(FLIGHT)), '')) AS callsign,
    COUNT(*) AS points
  FROM airborne
  GROUP BY 1,2,3;

  -- 2) Classify leg direction relative to the airport polygon.
  CREATE OR REPLACE TEMP TABLE tmp_leg_dir AS
  WITH ap AS (SELECT geometry AS g FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT LIMIT 1),
  p0 AS (
    SELECT
      ICAO_HEX,
      TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP)) AS service_date,
      TIMESTAMP AS ts,
      LOCATION,
      IFF(
        COALESCE(VELOCITY, 0) <= 40
        AND (ALTITUDE_BARO IS NULL OR ALTITUDE_BARO <= 50),
        1, 0
      ) AS is_ground
    FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA
    WHERE TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, TIMESTAMP)) >= DATEADD('day', -:v_days, :v_local_today)
      AND ICAO_HEX IS NOT NULL
      AND LOCATION IS NOT NULL
      AND TIMESTAMP IS NOT NULL
  ),
  p1 AS (
    SELECT
      *,
      LAG(ts) OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts) AS prev_ts,
      LAG(is_ground) OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts) AS prev_is_ground
    FROM p0
  ),
  p2 AS (
    SELECT
      *,
      DATEDIFF('minute', prev_ts, ts) AS gap_min
    FROM p1
  ),
  p AS (
    SELECT
      *,
      -- NOTE: window functions cannot be nested in Snowflake; keep LAG() in prior CTEs and only SUM() here.
      SUM(IFF(COALESCE(gap_min, 999999) > 20 OR COALESCE(prev_is_ground, is_ground) <> is_ground, 1, 0))
        OVER (PARTITION BY ICAO_HEX, service_date ORDER BY ts ROWS UNBOUNDED PRECEDING) AS seg_id
    FROM p2
  ),
  start_rows AS (
    SELECT ICAO_HEX, service_date, seg_id, LOCATION AS start_loc
    FROM p
    WHERE is_ground = 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ICAO_HEX, service_date, seg_id ORDER BY ts ASC) = 1
  ),
  end_rows AS (
    SELECT ICAO_HEX, service_date, seg_id, LOCATION AS end_loc
    FROM p
    WHERE is_ground = 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ICAO_HEX, service_date, seg_id ORDER BY ts DESC) = 1
  ),
  endpoints AS (
    SELECT s.ICAO_HEX, s.service_date, s.seg_id, s.start_loc, e.end_loc
    FROM start_rows s
    JOIN end_rows e USING (ICAO_HEX, service_date, seg_id)
  )
  SELECT
    l.*,
    CASE
      WHEN ST_DWITHIN(e.start_loc, ap.g, 5000) AND NOT ST_DWITHIN(e.end_loc, ap.g, 5000) THEN 'departure'
      WHEN NOT ST_DWITHIN(e.start_loc, ap.g, 5000) AND ST_DWITHIN(e.end_loc, ap.g, 5000) THEN 'arrival'
      WHEN ST_DWITHIN(e.start_loc, ap.g, 5000) AND ST_DWITHIN(e.end_loc, ap.g, 5000) THEN 'local'
      ELSE 'unknown'
    END AS direction,
    e.start_loc,
    e.end_loc
  FROM tmp_airborne_leg l
  JOIN endpoints e USING (ICAO_HEX, service_date, seg_id)
  CROSS JOIN ap;

  -- Persist legs for debugging/analytics (keep last v_days + 1 due to ±1 day schedule joins)
  DELETE FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG
  WHERE service_date >= DATEADD('day', -(:v_days + 1), :v_local_today);

  INSERT INTO {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG (
    SERVICE_DATE, ICAO_HEX, SEG_ID, LEG_START_TS, LEG_END_TS,
    DIRECTION, START_LOC, END_LOC, CALLSIGN, REGISTRATION, POINTS, COMPUTED_AT
  )
  SELECT
    service_date,
    ICAO_HEX,
    seg_id,
    leg_start_ts,
    leg_end_ts,
    direction,
    start_loc,
    end_loc,
    callsign,
    registration,
    points,
    CURRENT_TIMESTAMP()
  FROM tmp_leg_dir;

  -- 3) Match legs to schedule using (a) registration + date + time proximity, and
  --    (b) callsign (flight/callsign) + date + time proximity as a fallback.
  CREATE OR REPLACE TEMP TABLE tmp_leg_candidates AS
  WITH airport AS (
    SELECT
      UPPER(airport_code) AS airport_code,
      UPPER(airport_icao) AS airport_icao
    FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
    LIMIT 1
  ),
  sched AS (
    SELECT
      FLIGHT_KEY AS schedule_flight_key,
      FLIGHT_NUMBER AS schedule_flight_number,
      FLIGHT_DATE AS service_date,
      UPPER(AIRCRAFT_REGISTRATION) AS registration,
      UPPER(TRIM(AIRLINE_ICAO)) AS airline_icao,
      UPPER(TRIM(AIRLINE_IATA)) AS airline_iata,
      UPPER(TRIM(FLIGHT_ICAO)) AS flight_icao,
      UPPER(TRIM(FLIGHT_IATA)) AS flight_iata,
      UPPER(TRIM(FLIGHT_NUMBER)) AS flight_number_norm,
      DEPARTURE_AIRPORT,
      ARRIVAL_AIRPORT,
      DEPARTURE_SCHEDULED,
      ARRIVAL_SCHEDULED
    FROM {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE
    -- Include an extra day because ADSB uses UTC dates while schedule is airport-local date in practice.
    WHERE FLIGHT_DATE >= DATEADD('day', -(:v_days + 1), :v_local_today)
  ),
  candidates_reg AS (
    SELECT
      l.ICAO_HEX, l.service_date, l.seg_id,
      s.schedule_flight_key, s.schedule_flight_number,
      s.airline_icao, s.airline_iata,
      s.DEPARTURE_AIRPORT, s.ARRIVAL_AIRPORT,
      l.direction,
      ABS(DATEDIFF('day', s.service_date, l.service_date)) AS date_diff_days,
      CASE
        WHEN l.direction = 'departure' THEN DATEDIFF('minute', s.DEPARTURE_SCHEDULED, l.leg_start_ts)
        WHEN l.direction = 'arrival' THEN DATEDIFF('minute', s.ARRIVAL_SCHEDULED, l.leg_end_ts)
        ELSE LEAST(
          ABS(DATEDIFF('minute', s.DEPARTURE_SCHEDULED, l.leg_start_ts)),
          ABS(DATEDIFF('minute', s.ARRIVAL_SCHEDULED, l.leg_end_ts))
        )
      END AS diff_min,
      CASE
        WHEN l.direction = 'departure' THEN l.leg_start_ts
        WHEN l.direction = 'arrival' THEN l.leg_end_ts
        ELSE DATEADD('minute', DATEDIFF('minute', l.leg_start_ts, l.leg_end_ts)/2, l.leg_start_ts)
      END AS anchor_ts
    FROM tmp_leg_dir l
    JOIN sched s
      -- Allow ±1 day due to UTC vs local date boundaries
      ON s.service_date BETWEEN DATEADD('day', -1, l.service_date) AND DATEADD('day', 1, l.service_date)
     AND s.registration = UPPER(l.registration)
    WHERE l.registration IS NOT NULL
  ),
  callsign_normalized AS (
    -- Normalize callsigns: strip trailing operational suffixes (W,J,X,Y,Z)
    -- and extract airline prefix + flight number for dual-prefix matching.
    SELECT
      ICAO_HEX, service_date, seg_id, callsign, leg_start_ts, leg_end_ts, direction,
      -- Strip single trailing letter suffix if present (SKW864W → SKW864)
      REGEXP_REPLACE(UPPER(TRIM(callsign)), '[WJXYZ]$', '') AS callsign_normalized,
      -- Extract airline prefix (2-3 letters)
      REGEXP_SUBSTR(UPPER(TRIM(callsign)), '^[A-Z]{2,3}') AS airline_prefix,
      -- Extract numeric part
      REGEXP_SUBSTR(UPPER(TRIM(callsign)), '[0-9]+') AS flight_number_part
    FROM tmp_leg_dir
    WHERE callsign IS NOT NULL AND callsign <> ''
  ),
  callsign_with_alternates AS (
    -- For each callsign, get alternate airline codes (IATA↔ICAO translation)
    SELECT
      c.*,
      m_icao.airline_iata AS alternate_iata,
      m_iata.airline_icao AS alternate_icao
    FROM callsign_normalized c
    -- If callsign has 3-letter prefix (ICAO), find corresponding IATA
    LEFT JOIN {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP m_icao
      ON LENGTH(c.airline_prefix) = 3
     AND m_icao.airline_icao = c.airline_prefix
    -- If callsign has 2-letter prefix (IATA), find corresponding ICAO
    LEFT JOIN {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_IATA_ICAO_MAP m_iata
      ON LENGTH(c.airline_prefix) = 2
     AND m_iata.airline_iata = c.airline_prefix
  ),
  candidates_callsign AS (
    SELECT
      l.ICAO_HEX, l.service_date, l.seg_id,
      s.schedule_flight_key, s.schedule_flight_number,
      s.airline_icao, s.airline_iata,
      s.DEPARTURE_AIRPORT, s.ARRIVAL_AIRPORT,
      l.direction,
      ABS(DATEDIFF('day', s.service_date, l.service_date)) AS date_diff_days,
      CASE
        WHEN l.direction = 'departure' THEN DATEDIFF('minute', s.DEPARTURE_SCHEDULED, l.leg_start_ts)
        WHEN l.direction = 'arrival' THEN DATEDIFF('minute', s.ARRIVAL_SCHEDULED, l.leg_end_ts)
        ELSE LEAST(
          ABS(DATEDIFF('minute', s.DEPARTURE_SCHEDULED, l.leg_start_ts)),
          ABS(DATEDIFF('minute', s.ARRIVAL_SCHEDULED, l.leg_end_ts))
        )
      END AS diff_min,
      CASE
        WHEN l.direction = 'departure' THEN l.leg_start_ts
        WHEN l.direction = 'arrival' THEN l.leg_end_ts
        ELSE DATEADD('minute', DATEDIFF('minute', l.leg_start_ts, l.leg_end_ts)/2, l.leg_start_ts)
      END AS anchor_ts
    FROM callsign_with_alternates l
    JOIN sched s
      -- Allow ±1 day due to UTC vs local date boundaries
      ON s.service_date BETWEEN DATEADD('day', -1, l.service_date) AND DATEADD('day', 1, l.service_date)
     AND (
          -- Exact callsign match (original or normalized)
          s.flight_icao = UPPER(TRIM(l.callsign))
       OR s.flight_iata = UPPER(TRIM(l.callsign))
       OR s.flight_icao = l.callsign_normalized
       OR s.flight_iata = l.callsign_normalized
       -- Numeric + airline prefix match (current logic, but with normalized callsign)
       OR (
            l.airline_prefix IS NOT NULL
        AND l.flight_number_part IS NOT NULL
        AND s.flight_number_norm = l.flight_number_part
        AND (
              (LENGTH(l.airline_prefix) = 3 AND s.airline_icao = l.airline_prefix)
           OR (LENGTH(l.airline_prefix) = 2 AND s.airline_iata = l.airline_prefix)
           -- NEW: Try alternate code (IATA↔ICAO translation)
           OR (LENGTH(l.airline_prefix) = 3 AND l.alternate_iata IS NOT NULL AND s.airline_iata = l.alternate_iata)
           OR (LENGTH(l.airline_prefix) = 2 AND l.alternate_icao IS NOT NULL AND s.airline_icao = l.alternate_icao)
        )
       )
     )
  ),
  candidates AS (
    SELECT *, 'registration_time' AS match_method, 0 AS match_priority FROM candidates_reg
    UNION ALL
    SELECT *, 'callsign_time' AS match_method, 1 AS match_priority FROM candidates_callsign
  ),
  filtered AS (
    SELECT *,
      ABS(diff_min) AS abs_diff
    FROM candidates
    WHERE
      (match_method = 'registration_time' AND abs(diff_min) <= 240)
      OR
      -- Callsign is a strong identifier; expand to ±36 hours to catch irregular ops/delays.
      (match_method = 'callsign_time' AND abs(diff_min) <= 2160)
  ),
  scored AS (
    SELECT
      c.*,
      -- Direction sanity: for arrivals, schedule ARRIVAL should be our airport; for departures, schedule DEPARTURE.
      IFF(
        c.direction IN ('arrival','departure'),
        IFF(
          c.direction = 'arrival',
          UPPER(TRIM(c.ARRIVAL_AIRPORT)) IN ((SELECT airport_code FROM airport), (SELECT airport_icao FROM airport)),
          UPPER(TRIM(c.DEPARTURE_AIRPORT)) IN ((SELECT airport_code FROM airport), (SELECT airport_icao FROM airport))
        ),
        TRUE
      ) AS direction_ok,
      -- Base score from time gap, then penalize date diff and direction mismatch.
      -- Improved confidence tiers for wider callsign window (±36 hrs):
      --   0-120 min: 80-90 confidence
      --   121-1440 min (24h): 60-79 confidence
      --   1441-2160 min (36h): 40-59 confidence
      (
        IFF(
          c.match_method = 'registration_time',
          GREATEST(0, 100 - (c.abs_diff * 100 / 240))::INT,
          -- Callsign scoring with tiered confidence
          CASE
            WHEN c.abs_diff <= 120 THEN GREATEST(0, 90 - (c.abs_diff * 10 / 120))::INT
            WHEN c.abs_diff <= 1440 THEN GREATEST(0, 79 - ((c.abs_diff - 120) * 19 / 1320))::INT
            ELSE GREATEST(0, 59 - ((c.abs_diff - 1440) * 19 / 720))::INT
          END
        )
        - (c.date_diff_days * 10)
        - IFF(
            c.direction IN ('arrival','departure')
            AND NOT IFF(
              c.direction = 'arrival',
              UPPER(TRIM(c.ARRIVAL_AIRPORT)) IN ((SELECT airport_code FROM airport), (SELECT airport_icao FROM airport)),
              UPPER(TRIM(c.DEPARTURE_AIRPORT)) IN ((SELECT airport_code FROM airport), (SELECT airport_icao FROM airport))
            ),
            30, 0
          )
      )::INT AS score
    FROM filtered c
  )
  SELECT
    ICAO_HEX, service_date, seg_id,
    schedule_flight_key, schedule_flight_number,
    match_method,
    match_priority,
    date_diff_days,
    diff_min,
    abs_diff,
    direction,
    direction_ok,
    airline_icao,
    airline_iata,
    DEPARTURE_AIRPORT,
    ARRIVAL_AIRPORT,
    score,
    anchor_ts
  FROM scored;

  -- Persist candidates (debugging)
  DELETE FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES
  WHERE service_date >= DATEADD('day', -(:v_days + 1), :v_local_today);

  INSERT INTO {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_CANDIDATES (
    SERVICE_DATE, ICAO_HEX, SEG_ID,
    MATCH_METHOD, MATCH_PRIORITY, DATE_DIFF_DAYS, DIFF_MIN, ABS_DIFF_MIN,
    DIRECTION, DIRECTION_OK,
    SCHEDULE_FLIGHT_KEY, SCHEDULE_FLIGHT_NUMBER,
    AIRLINE_ICAO, AIRLINE_IATA,
    DEPARTURE_AIRPORT, ARRIVAL_AIRPORT,
    SCORE, CREATED_AT
  )
  SELECT
    service_date, ICAO_HEX, seg_id,
    match_method, match_priority, date_diff_days, diff_min, abs_diff,
    direction, direction_ok,
    schedule_flight_key, schedule_flight_number,
    airline_icao, airline_iata,
    DEPARTURE_AIRPORT, ARRIVAL_AIRPORT,
    score, CURRENT_TIMESTAMP()
  FROM tmp_leg_candidates;

  -- Choose best candidate per leg using score + direction sanity
  CREATE OR REPLACE TEMP TABLE tmp_leg_match AS
  SELECT
    ICAO_HEX,
    service_date,
    seg_id,
    schedule_flight_key,
    schedule_flight_number,
    match_method,
    -- Keep existing confidence semantics for downstream consumers
    GREATEST(0, score)::INT AS match_confidence,
    anchor_ts
  FROM tmp_leg_candidates
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ICAO_HEX, service_date, seg_id
    ORDER BY match_priority ASC, direction_ok DESC, score DESC, abs_diff ASC, date_diff_days ASC
  ) = 1;

  -- Persist chosen results
  DELETE FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_RESULT
  WHERE service_date >= DATEADD('day', -(:v_days + 1), :v_local_today);

  INSERT INTO {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_RESULT (
    SERVICE_DATE, ICAO_HEX, SEG_ID,
    MATCH_METHOD, MATCH_PRIORITY, DATE_DIFF_DAYS, ABS_DIFF_MIN,
    DIRECTION, DIRECTION_OK,
    SCHEDULE_FLIGHT_KEY, SCHEDULE_FLIGHT_NUMBER,
    SCORE, CHOSEN_AT
  )
  SELECT
    service_date, ICAO_HEX, seg_id,
    match_method, match_priority, date_diff_days, abs_diff,
    direction, direction_ok,
    schedule_flight_key, schedule_flight_number,
    score, CURRENT_TIMESTAMP()
  FROM tmp_leg_candidates
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ICAO_HEX, service_date, seg_id
    ORDER BY match_priority ASC, direction_ok DESC, score DESC, abs_diff ASC, date_diff_days ASC
  ) = 1;

  -- -----------------------------------------------------------------------------
  -- Phase 4: Refresh recurring callsign prior (conservative fallback)
  -- -----------------------------------------------------------------------------
  CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR AS
  WITH base AS (
    SELECT
      l.service_date,
      l.callsign,
      REGEXP_SUBSTR(UPPER(TRIM(l.callsign)), '^[A-Z]{2,3}[0-9]+') AS callsign_key,
      r.schedule_flight_key,
      fs.AIRLINE_ICAO,
      fs.AIRLINE_IATA,
      fs.AIRLINE_NAME,
      fs.DEPARTURE_AIRPORT AS origin_airport,
      fs.ARRIVAL_AIRPORT AS destination_airport
    FROM {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_LEG l
    JOIN {TARGET_DB}.{SCHEMA}.HELPER_FLIGHT_MATCH_RESULT r
      ON r.ICAO_HEX = l.ICAO_HEX AND r.service_date = l.service_date AND r.seg_id = l.seg_id
    LEFT JOIN {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE fs
      ON fs.FLIGHT_KEY = r.schedule_flight_key
    WHERE l.service_date >= DATEADD('day', -30, :v_local_today)
      AND l.callsign IS NOT NULL AND TRIM(l.callsign) <> ''
      AND REGEXP_SUBSTR(UPPER(TRIM(l.callsign)), '[0-9]+') IS NOT NULL
      AND callsign_key IS NOT NULL AND callsign_key <> ''
      AND fs.FLIGHT_KEY IS NOT NULL
  ),
  airline_counts AS (
    SELECT
      callsign_key,
      TRIM(UPPER(AIRLINE_ICAO)) AS airline_icao,
      TRIM(UPPER(AIRLINE_IATA)) AS airline_iata,
      MAX(TRIM(AIRLINE_NAME)) AS airline_name,
      COUNT(*) AS legs
    FROM base
    GROUP BY 1,2,3
  ),
  best_airline AS (
    SELECT *
    FROM airline_counts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY callsign_key ORDER BY legs DESC, airline_icao ASC NULLS LAST, airline_iata ASC NULLS LAST) = 1
  ),
  od_counts AS (
    SELECT
      callsign_key,
      TRIM(UPPER(origin_airport)) AS origin_airport,
      TRIM(UPPER(destination_airport)) AS destination_airport,
      COUNT(*) AS legs
    FROM base
    WHERE origin_airport IS NOT NULL AND destination_airport IS NOT NULL
    GROUP BY 1,2,3
  ),
  best_od AS (
    SELECT *
    FROM od_counts
    QUALIFY ROW_NUMBER() OVER (PARTITION BY callsign_key ORDER BY legs DESC, origin_airport ASC, destination_airport ASC) = 1
  ),
  totals AS (
    SELECT callsign_key, COUNT(*) AS legs, MAX(service_date) AS last_seen_date
    FROM base
    GROUP BY 1
  )
  SELECT
    t.callsign_key,
    a.airline_icao,
    a.airline_iata,
    a.airline_name,
    o.origin_airport,
    o.destination_airport,
    t.legs,
    t.last_seen_date,
    CURRENT_TIMESTAMP() AS updated_at
  FROM totals t
  LEFT JOIN best_airline a USING (callsign_key)
  LEFT JOIN best_od o USING (callsign_key)
  WHERE t.legs >= 5;

  -- 4) Apply schedule association to points in ADSB_DATA (canonical table)
  MERGE INTO {TARGET_DB}.{SCHEMA}.ADSB_DATA t
  USING (
    WITH airport AS (
      SELECT
        UPPER(airport_code) AS airport_code,
        UPPER(airport_icao) AS airport_icao,
        geometry AS airport_geom
      FROM {TARGET_DB}.{SCHEMA}.PROPERTIES_AIRPORT
      LIMIT 1
    ),
    pts AS (
      SELECT
        s.*,
        TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, s.TIMESTAMP)) AS service_date,
        IFF(
          COALESCE(s.VELOCITY, 0) <= 40
          AND (s.ALTITUDE_BARO IS NULL OR s.ALTITUDE_BARO <= 50),
          1, 0
        ) AS is_ground,
        DATEDIFF(
          'minute',
          LAG(s.TIMESTAMP) OVER (
            PARTITION BY s.ICAO_HEX, TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, s.TIMESTAMP))
            ORDER BY s.TIMESTAMP
          ),
          s.TIMESTAMP
        ) AS gap_min,
        LAG(IFF(
              COALESCE(s.VELOCITY, 0) <= 40
              AND (s.ALTITUDE_BARO IS NULL OR s.ALTITUDE_BARO <= 50),
              1, 0
            ))
          OVER (
            PARTITION BY s.ICAO_HEX, TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, s.TIMESTAMP))
            ORDER BY s.TIMESTAMP
          ) AS prev_is_ground
      FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA s
      WHERE TO_DATE(CONVERT_TIMEZONE('UTC', :v_tzid, s.TIMESTAMP)) >= DATEADD('day', -:v_days, :v_local_today)
        AND s.ICAO_HEX IS NOT NULL
        AND s.TIMESTAMP IS NOT NULL
    ),
    seg AS (
      SELECT
        *,
        SUM(IFF(COALESCE(gap_min, 999999) > 20 OR COALESCE(prev_is_ground, is_ground) <> is_ground, 1, 0))
          OVER (PARTITION BY ICAO_HEX, service_date ORDER BY TIMESTAMP ROWS UNBOUNDED PRECEDING) AS seg_id
      FROM pts
    ),
    joined AS (
      SELECT
        p.*,
        m.schedule_flight_key AS match_schedule_flight_key,
        m.schedule_flight_number AS match_schedule_flight_number,
        m.match_method AS match_match_method,
        m.match_confidence AS match_match_confidence,
        m.anchor_ts AS match_anchor_ts
      FROM seg p
      LEFT JOIN tmp_leg_match m
        ON m.ICAO_HEX = p.ICAO_HEX
       AND m.service_date = p.service_date
       AND m.seg_id = p.seg_id
    ),
    filled AS (
      SELECT
        j.*,
        COALESCE(j.match_schedule_flight_key, j.SCHEDULE_FLIGHT_KEY) AS schedule_flight_key_merged,
        COALESCE(j.match_schedule_flight_number, j.SCHEDULE_FLIGHT_NUMBER) AS schedule_flight_number_merged,
        COALESCE(j.match_match_method, j.MATCH_METHOD) AS match_method_merged,
        COALESCE(j.match_match_confidence, j.MATCH_CONFIDENCE) AS match_confidence_merged,
        COALESCE(j.match_anchor_ts, j.MATCHED_AT) AS anchor_ts_merged,
        LAST_VALUE(COALESCE(j.match_schedule_flight_key, j.SCHEDULE_FLIGHT_KEY)) IGNORE NULLS
          OVER (PARTITION BY j.ICAO_HEX, j.service_date ORDER BY j.TIMESTAMP ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS prev_key,
        LAST_VALUE(COALESCE(j.match_anchor_ts, j.MATCHED_AT)) IGNORE NULLS
          OVER (PARTITION BY j.ICAO_HEX, j.service_date ORDER BY j.TIMESTAMP ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS prev_anchor,
        FIRST_VALUE(COALESCE(j.match_schedule_flight_key, j.SCHEDULE_FLIGHT_KEY)) IGNORE NULLS
          OVER (PARTITION BY j.ICAO_HEX, j.service_date ORDER BY j.TIMESTAMP ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS next_key,
        FIRST_VALUE(COALESCE(j.match_anchor_ts, j.MATCHED_AT)) IGNORE NULLS
          OVER (PARTITION BY j.ICAO_HEX, j.service_date ORDER BY j.TIMESTAMP ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS next_anchor
      FROM joined
      AS j
    )
    ,final AS (
      SELECT
      -- Choose nearest schedule key if point itself isn't on a matched leg.
      COALESCE(
        schedule_flight_key_merged,
        IFF(prev_key IS NULL, next_key,
            IFF(next_key IS NULL, prev_key,
                IFF(ABS(DATEDIFF('minute', prev_anchor, TIMESTAMP)) <= ABS(DATEDIFF('minute', next_anchor, TIMESTAMP)), prev_key, next_key)
            )
        )
      ) AS schedule_flight_key_final,
      COALESCE(
        schedule_flight_number_merged,
        -- fallback: use existing callsign when present
        NULLIF(TRIM(FLIGHT), '')
      ) AS schedule_flight_number_final,
      COALESCE(match_method_merged, 'propagated') AS match_method_final,
      COALESCE(match_confidence_merged, 50) AS match_confidence_final,
      NULLIF(UPPER(TRIM(FLIGHT)), '') AS callsign_raw,
      ICAO_HEX, TIMESTAMP
    FROM filled
    )
    ,fs_dedup AS (
      -- Defensive: ensure FLIGHT_SCHEDULE contributes at most 1 row per FLIGHT_KEY.
      -- If older installs (or API quirks) produced duplicates, join fanout would create
      -- duplicate (ICAO_HEX,TIMESTAMP) rows in the MERGE source and the MERGE would fail.
      SELECT *
      FROM {TARGET_DB}.{SCHEMA}.FLIGHT_SCHEDULE
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY FLIGHT_KEY
        ORDER BY UPDATED_AT DESC
      ) = 1
    )
    ,rp_dedup AS (
      -- Ensure 1 row per callsign_key to avoid join fanout.
      SELECT *
      FROM {TARGET_DB}.{SCHEMA}.HELPER_RECURRING_CALLSIGN_PRIOR
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY CALLSIGN_KEY
        ORDER BY LEGS DESC, UPDATED_AT DESC
      ) = 1
    )
    ,airline_dim_icao AS (
      -- HELPER_AIRLINE_DIM can contain multiple rows per code; collapse to 1 row/code to avoid fanout.
      SELECT
        TRIM(UPPER(AIRLINE_ICAO)) AS airline_icao,
        MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name
      FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
      WHERE AIRLINE_ICAO IS NOT NULL AND TRIM(AIRLINE_ICAO) <> ''
      GROUP BY 1
    )
    ,airline_dim_iata AS (
      SELECT
        TRIM(UPPER(AIRLINE_IATA)) AS airline_iata,
        MAX(NULLIF(TRIM(AIRLINE_NAME), '')) AS airline_name,
        MAX(NULLIF(TRIM(AIRLINE_IATA), '')) AS airline_iata_raw
      FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRLINE_DIM
      WHERE AIRLINE_IATA IS NOT NULL AND TRIM(AIRLINE_IATA) <> ''
      GROUP BY 1
    )
    SELECT
      f.schedule_flight_key_final,
      f.schedule_flight_number_final,
      f.match_method_final,
      f.match_confidence_final,
      -- Airline fallback priority:
      --  1) Schedule (best)
      --  2) Recurring callsign prior (when schedule missing)
      --  3) Airline dim by prefix (last resort)
      COALESCE(fs.AIRLINE_NAME, rp.AIRLINE_NAME, ad3.airline_name, ad2.airline_name) AS airline_name_final,
      COALESCE(fs.AIRLINE_IATA, rp.AIRLINE_IATA, ad2.airline_iata_raw) AS airline_iata_final,
      COALESCE(fs.AIRLINE_ICAO, rp.AIRLINE_ICAO, ad3.airline_icao) AS airline_icao_final,
      COALESCE(fs.DEPARTURE_AIRPORT, rp.ORIGIN_AIRPORT) AS origin_airport_final,
      COALESCE(fs.ARRIVAL_AIRPORT, rp.DESTINATION_AIRPORT) AS destination_airport_final,
      fs.DEPARTURE_SCHEDULED AS scheduled_departure_final,
      fs.ARRIVAL_SCHEDULED AS scheduled_arrival_final,
      IFF(
        airport.airport_code IS NOT NULL
        AND (
          UPPER(TRIM(fs.DEPARTURE_AIRPORT)) IN (airport.airport_code, airport.airport_icao)
          OR UPPER(TRIM(fs.ARRIVAL_AIRPORT)) IN (airport.airport_code, airport.airport_icao)
        ),
        TRUE, FALSE
      ) AS is_local_od_final,
      f.ICAO_HEX,
      f.TIMESTAMP
    FROM final f
    LEFT JOIN fs_dedup fs
      ON fs.FLIGHT_KEY = f.schedule_flight_key_final
    LEFT JOIN rp_dedup rp
      ON rp.CALLSIGN_KEY = REGEXP_SUBSTR(f.callsign_raw, '^[A-Z]{2,3}[0-9]+')
    LEFT JOIN airline_dim_icao ad3
      ON ad3.airline_icao = REGEXP_SUBSTR(f.callsign_raw, '^[A-Z]{3}')
    LEFT JOIN airline_dim_iata ad2
      ON ad2.airline_iata = REGEXP_SUBSTR(f.callsign_raw, '^[A-Z]{2}')
    CROSS JOIN airport
  ) s
  ON t.ICAO_HEX = s.ICAO_HEX AND t.TIMESTAMP = s.TIMESTAMP
  WHEN MATCHED THEN UPDATE SET
    t.SCHEDULE_FLIGHT_KEY = s.schedule_flight_key_final,
    t.SCHEDULE_FLIGHT_NUMBER = s.schedule_flight_number_final,
    t.AIRLINE_NAME = s.airline_name_final,
    t.AIRLINE_IATA = s.airline_iata_final,
    t.AIRLINE_ICAO = s.airline_icao_final,
    t.ORIGIN_AIRPORT = s.origin_airport_final,
    t.DESTINATION_AIRPORT = s.destination_airport_final,
    t.IS_LOCAL_OD = s.is_local_od_final,
    t.SCHEDULED_DEPARTURE = s.scheduled_departure_final,
    t.SCHEDULED_ARRIVAL = s.scheduled_arrival_final,
    t.MATCH_METHOD = s.match_method_final,
    t.MATCH_CONFIDENCE = s.match_confidence_final,
    t.MATCHED_AT = CURRENT_TIMESTAMP();

  v_merge_rows := SQLROWCOUNT;

  RETURN 'Enriched ADSB points for last ' || :v_days || ' days'
         || ' (source_rows=' || :v_src_rows || ', merge_rows=' || :v_merge_rows || ')';
END;
$$;

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ENRICH_ADSB_WITH_SCHEDULE(INT)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

