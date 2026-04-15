# Network Rules and External Access Integrations

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

## Migration Note (non-destructive)

If upgrading from an older install that used `ADSB_DATA_GOLD` / `ADSB_DATA_SILVER` and legacy `GATES`/`RUNWAYS`:

```sql
-- 1) Properties tables:
--    CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_GATES     AS SELECT * FROM {TARGET_DB}.{SCHEMA}.GATES;
--    CREATE OR REPLACE TABLE {TARGET_DB}.{SCHEMA}.PROPERTIES_RUNWAYS   AS SELECT * FROM {TARGET_DB}.{SCHEMA}.RUNWAYS;
--
-- 2) ADSB_DATA:
--    INSERT INTO {TARGET_DB}.{SCHEMA}.ADSB_DATA (
--      FLIGHT_KEY, ICAO_HEX, REGISTRATION, TYPE, AIRCRAFT_DESC, FLIGHT, TIMESTAMP, LOCATION,
--      TRACK, TRUE_HEADING, VELOCITY, ALTITUDE_BARO, ALTITUDE_GEOM, VERTICAL_RATE, SQUAWK, CATEGORY, SOURCE
--    )
--    SELECT
--      FLIGHT_KEY, ICAO_HEX, REGISTRATION, TYPE, AIRCRAFT_DESC, FLIGHT, TIMESTAMP, LOCATION,
--      TRACK, TRUE_HEADING, VELOCITY, ALTITUDE_BARO, ALTITUDE_GEOM, VERTICAL_RATE, SQUAWK, CATEGORY, SOURCE
--    FROM {TARGET_DB}.{SCHEMA}.ADSB_DATA_GOLD;
```

---

## Step 1: Network Rules and External Access Integrations

```sql
CREATE OR REPLACE NETWORK RULE {TARGET_DB}.{SCHEMA}.{SCHEMA}_adsb_lol_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.adsb.lol:443')
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {EAI_ADSB_LOL}
  ALLOWED_NETWORK_RULES = ({TARGET_DB}.{SCHEMA}.{SCHEMA}_adsb_lol_rule)
  ENABLED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

---

## Step 1b: GitHub API Access

```sql
CREATE OR REPLACE NETWORK RULE {TARGET_DB}.{SCHEMA}.{SCHEMA}_github_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.github.com:443', 'github.com:443', 'objects.githubusercontent.com:443', 'release-assets.githubusercontent.com:443')
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

```sql
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {EAI_GITHUB}
  ALLOWED_NETWORK_RULES = ({TARGET_DB}.{SCHEMA}.{SCHEMA}_github_rule)
  ENABLED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

---

