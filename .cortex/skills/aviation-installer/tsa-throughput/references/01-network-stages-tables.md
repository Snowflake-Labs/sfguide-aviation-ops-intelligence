# Network Rule, EAI, Stages, and Table

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`, `{EAI_TSA_GOV}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```
>
> **EAI name**: Derived as `re.sub(r"[^A-Za-z0-9_]", "_", f"{TARGET_DB}_{SCHEMA}_TSA_GOV_EAI").upper()` — e.g. `AIRPORT_SAN_PUBLIC_TSA_GOV_EAI`

---

## Network Rule

```sql
CREATE OR REPLACE NETWORK RULE {TARGET_DB}.{SCHEMA}.{SCHEMA}_tsa_gov_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('www.tsa.gov:443')
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## External Access Integration

```sql
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {EAI_TSA_GOV}
  ALLOWED_NETWORK_RULES = ({TARGET_DB}.{SCHEMA}.{SCHEMA}_tsa_gov_rule)
  ENABLED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

> **Note:** No secret needed — the TSA FOIA reading room is publicly accessible.

---

## Stages

Both stages require `SNOWFLAKE_SSE` encryption — this is mandatory for `AI_EXTRACT`.

```sql
CREATE STAGE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.TSA_PDF_STAGE
  DIRECTORY  = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

```sql
CREATE STAGE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.TSA_PDF_PAGES_STAGE
  DIRECTORY  = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

---

## Table

```sql
CREATE TABLE IF NOT EXISTS {TARGET_DB}.{SCHEMA}.TSA_THROUGHPUT (
    source_file        VARCHAR,
    page_file          VARCHAR,
    date               VARCHAR,
    hour_of_day        VARCHAR,
    airport_code       VARCHAR,
    airport_name       VARCHAR,
    city               VARCHAR,
    state              VARCHAR,
    checkpoint         VARCHAR,
    total_pax_kcm_pax  VARCHAR,
    extracted_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-tsa-throughput","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```
