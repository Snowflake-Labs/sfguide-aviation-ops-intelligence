# Historical Backfill Infrastructure

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

## Step 7: Historical Backfill Infrastructure

### Network Rule (GitHub)

```sql
CREATE OR REPLACE NETWORK RULE {TARGET_DB}.{SCHEMA}.{SCHEMA}_github_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.github.com:443', 'github.com:443', 'objects.githubusercontent.com:443', 'release-assets.githubusercontent.com:443')
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### External Access Integration (GitHub)

```sql
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {EAI_GITHUB}
  ALLOWED_NETWORK_RULES = ({TARGET_DB}.{SCHEMA}.{SCHEMA}_github_rule)
  ENABLED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### ADSB_HISTORY_STAGE

```sql
-- Internal stage for downloaded TAR files and extracted NDJSON
CREATE STAGE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.ADSB_HISTORY_STAGE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

### HELPER_ADSB_BACKFILL_STATUS

```sql
-- Tracking table for backfill status
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS (
    data_date DATE PRIMARY KEY,
    download_status VARCHAR(20) DEFAULT 'pending',
    downloaded_at TIMESTAMP_NTZ,
    extracted_at TIMESTAMP_NTZ,
    loaded_at TIMESTAMP_NTZ,
    processed_at TIMESTAMP_NTZ,
    downloaded_parts INT,
    downloaded_bytes NUMBER(38,0),
    aircraft_extracted INT,
    rows_loaded INT,
    aircraft_found INT,
    points_inserted INT,
    error_message VARCHAR(500)
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

-- Backward/forward compatible schema upgrades
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS loaded_at TIMESTAMP_NTZ;
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS downloaded_parts INT;
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS downloaded_bytes NUMBER(38,0);
ALTER TABLE {TARGET_DB}.{SCHEMA}.HELPER_ADSB_BACKFILL_STATUS ADD COLUMN IF NOT EXISTS rows_loaded INT;
```

### HELPER_ADSB_HISTORY_INTERIM

```sql
-- Interim table for raw aircraft JSON (one row per aircraft)
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.HELPER_ADSB_HISTORY_INTERIM (
    data_date DATE,
    raw_json VARIANT,
    loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-adsb-ingestion","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

