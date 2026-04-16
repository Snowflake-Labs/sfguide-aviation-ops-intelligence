# Aircraft Meta Enrichment Procedures

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

## Aircraft Meta Enrichment

### PROC_ENRICH_AIRCRAFT_META

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ENRICH_AIRCRAFT_META(
    p_max_hexes INT,
    p_days_back INT,
    p_min_age_hours INT
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'enrich'
EXTERNAL_ACCESS_INTEGRATIONS = ({EAI_ADSB_LOL})
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
import json
import requests
from datetime import datetime

def _pick_aircraft_obj(payload):
    # Be resilient to schema changes / different endpoints:
    # - sometimes the aircraft is under payload['ac'][0]
    # - sometimes it's directly the payload dict
    if isinstance(payload, dict):
        ac = payload.get("ac")
        if isinstance(ac, list) and len(ac) > 0 and isinstance(ac[0], dict):
            return ac[0]
        return payload
    return {}

def enrich(session, p_max_hexes: int = 200, p_days_back: int = 2, p_min_age_hours: int = 24):
    p_max_hexes = int(p_max_hexes or 200)
    p_days_back = int(p_days_back or 2)
    p_min_age_hours = int(p_min_age_hours or 24)

    db_schema = "{TARGET_DB}.{SCHEMA}"

    # Find candidate ICAO_HEX values: recently seen, missing desc/type, and not updated recently in meta.
    q = '''
    WITH candidates AS (
      SELECT DISTINCT ICAO_HEX
      FROM %s.ADSB_DATA
      -- ADSB timestamps are stored as TIMESTAMP_NTZ in UTC; use SYSDATE() for consistent UTC comparisons.
      WHERE TIMESTAMP >= DATEADD('day', -%d, SYSDATE())
        AND ICAO_HEX IS NOT NULL
        AND (
          AIRCRAFT_DESC IS NULL OR TRIM(AIRCRAFT_DESC) = ''
          OR TYPE IS NULL OR TRIM(TYPE) = ''
        )
    ),
    filtered AS (
      SELECT c.ICAO_HEX
      FROM candidates c
      LEFT JOIN %s.HELPER_AIRCRAFT_META m
        ON m.ICAO_HEX = c.ICAO_HEX
       AND m.UPDATED_AT >= DATEADD('hour', -%d, SYSDATE())
      WHERE m.ICAO_HEX IS NULL
    )
    SELECT ICAO_HEX
    FROM filtered
    ORDER BY ICAO_HEX
    LIMIT %d
    ''' % (db_schema, p_days_back, db_schema, p_min_age_hours, p_max_hexes)
    hexes = [r["ICAO_HEX"] for r in session.sql(q).collect()]
    if not hexes:
        return "No missing aircraft meta to enrich"

    updated = 0
    errors = 0
    now = datetime.utcnow().isoformat()

    for hx in hexes:
        hx = (hx or "").strip().upper()
        if not hx:
            continue
        # Endpoint naming varies; this one is commonly used by ADSB.lol deployments.
        url = "https://api.adsb.lol/v2/hex/%s" % hx
        try:
            resp = requests.get(url, timeout=20)
            resp.raise_for_status()
            payload = resp.json()
            ac = _pick_aircraft_obj(payload)

            reg = (ac.get("r") or ac.get("registration") or "").strip().upper() or None
            typ = (ac.get("t") or ac.get("type") or ac.get("aircraft_type") or "").strip().upper() or None
            desc = (ac.get("desc") or ac.get("aircraft_desc") or "").strip() or None

            raw = json.dumps(payload, ensure_ascii=False)

            # Upsert into HELPER_AIRCRAFT_META
            merge_sql = '''
                MERGE INTO %s.HELPER_AIRCRAFT_META t
                USING (
                  SELECT
                    ? AS ICAO_HEX,
                    ? AS REGISTRATION,
                    ? AS TYPE,
                    ? AS AIRCRAFT_DESC,
                    TO_TIMESTAMP_NTZ(?) AS UPDATED_AT,
                    'ADSB_LOL_LOOKUP' AS SOURCE,
                    PARSE_JSON(?) AS RAW_JSON
                ) s
                ON t.ICAO_HEX = s.ICAO_HEX
                WHEN MATCHED THEN UPDATE SET
                  t.REGISTRATION = COALESCE(s.REGISTRATION, t.REGISTRATION),
                  t.TYPE = COALESCE(s.TYPE, t.TYPE),
                  t.AIRCRAFT_DESC = COALESCE(s.AIRCRAFT_DESC, t.AIRCRAFT_DESC),
                  t.UPDATED_AT = s.UPDATED_AT,
                  t.SOURCE = s.SOURCE,
                  t.RAW_JSON = s.RAW_JSON
                WHEN NOT MATCHED THEN INSERT (ICAO_HEX, REGISTRATION, TYPE, AIRCRAFT_DESC, UPDATED_AT, SOURCE, RAW_JSON)
                VALUES (s.ICAO_HEX, s.REGISTRATION, s.TYPE, s.AIRCRAFT_DESC, s.UPDATED_AT, s.SOURCE, s.RAW_JSON)
            ''' % (db_schema)
            session.sql(merge_sql, params=[hx, reg, typ, desc, now, raw]).collect()
            updated += 1
        except Exception:
            errors += 1

    return "Enriched aircraft meta for %d hexes (errors=%d)" % (updated, errors)
$$;

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ENRICH_AIRCRAFT_META(INT, INT, INT)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### PROC_BACKFILL_ADSB_AIRCRAFT_DESC

```sql
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_ADSB_AIRCRAFT_DESC(p_days_back INT)
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
DECLARE
  v_days INT;
  v_rows NUMBER(38,0);
BEGIN
  v_days := COALESCE(:p_days_back, 2);

  UPDATE {TARGET_DB}.{SCHEMA}.ADSB_DATA a
  SET
    AIRCRAFT_DESC = COALESCE(NULLIF(TRIM(a.AIRCRAFT_DESC), ''), m.AIRCRAFT_DESC),
    TYPE = COALESCE(NULLIF(TRIM(a.TYPE), ''), m.TYPE),
    REGISTRATION = COALESCE(NULLIF(TRIM(a.REGISTRATION), ''), m.REGISTRATION)
  FROM {TARGET_DB}.{SCHEMA}.HELPER_AIRCRAFT_META m
  WHERE a.ICAO_HEX = m.ICAO_HEX
    AND a.TIMESTAMP >= DATEADD('day', -:v_days, CURRENT_TIMESTAMP())
    AND (
      a.AIRCRAFT_DESC IS NULL OR TRIM(a.AIRCRAFT_DESC) = ''
      OR a.TYPE IS NULL OR TRIM(a.TYPE) = ''
      OR a.REGISTRATION IS NULL OR TRIM(a.REGISTRATION) = ''
    );

  v_rows := SQLROWCOUNT;
  RETURN 'Backfilled ADSB_DATA aircraft fields for last ' || v_days || ' days (rows=' || v_rows || ')';
END;
$$;

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_ADSB_AIRCRAFT_DESC(INT)
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';
```

### PROC_ENRICH_AIRCRAFT_META_AND_BACKFILL

```sql
-- Wrapper so the TASK body is a single CALL (installer statement-splitting safe)
CREATE OR REPLACE PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ENRICH_AIRCRAFT_META_AND_BACKFILL()
RETURNS STRING
LANGUAGE SQL
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
$$
BEGIN
  CALL {TARGET_DB}.{SCHEMA}.PROC_ENRICH_AIRCRAFT_META(200, 2, 24);
  CALL {TARGET_DB}.{SCHEMA}.PROC_BACKFILL_ADSB_AIRCRAFT_DESC(2);
  RETURN 'Aircraft meta enriched + ADSB_DATA backfilled';
END;
$$;

ALTER PROCEDURE {TARGET_DB}.{SCHEMA}.PROC_ENRICH_AIRCRAFT_META_AND_BACKFILL()
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'etl';

CREATE OR REPLACE TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_AIRCRAFT_META
  WAREHOUSE = {WAREHOUSE}
  SCHEDULE = 'USING CRON 15 3 * * * UTC'
  ALLOW_OVERLAPPING_EXECUTION = FALSE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
AS
  CALL {TARGET_DB}.{SCHEMA}.PROC_ENRICH_AIRCRAFT_META_AND_BACKFILL();

ALTER TASK {TARGET_DB}.{SCHEMA}.TASK_ENRICH_AIRCRAFT_META
  SET TAG {TARGET_DB}.TAGS.SOLUTION = 'aviation-ops-intelligence',
          {TARGET_DB}.TAGS.COMPONENT = 'realtime';
```

---
