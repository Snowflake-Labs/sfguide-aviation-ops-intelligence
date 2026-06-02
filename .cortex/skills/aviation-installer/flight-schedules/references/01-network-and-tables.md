# Network Rule, EAI, Secret, and Tables

> **Placeholders**: `{TARGET_DB}`, `{SCHEMA}`, `{WAREHOUSE}`, `{API_KEY}`, `{EAI_AVIATIONSTACK}`, `{IATA}`
>
> **COMMENT tag** for every `CREATE`:
> ```
> COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}'
> ```
>
> **Important**: Aviationstack basic plan uses HTTP port 80, NOT HTTPS port 443.
>
> **EAI name**: Derived as `re.sub(r"[^A-Za-z0-9_]", "_", f"{TARGET_DB}_{SCHEMA}_AVIATIONSTACK_EAI").upper()` — e.g. `AIRPORT_SAN_PUBLIC_AVIATIONSTACK_EAI`

---

## Network Rule

```sql
CREATE OR REPLACE NETWORK RULE {TARGET_DB}.{SCHEMA}.{SCHEMA}_aviationstack_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.aviationstack.com:80')
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## Secret

```sql
CREATE OR REPLACE SECRET {TARGET_DB}.{SCHEMA}.aviationstack_key
  TYPE = GENERIC_STRING
  SECRET_STRING = '{API_KEY}'
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## External Access Integration

```sql
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {EAI_AVIATIONSTACK}
  ALLOWED_NETWORK_RULES = ({TARGET_DB}.{SCHEMA}.{SCHEMA}_aviationstack_rule)
  ALLOWED_AUTHENTICATION_SECRETS = ({TARGET_DB}.{SCHEMA}.aviationstack_key)
  ENABLED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-flight-schedules","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## Tables

> Note: HELPER_FLIGHT_SCHEDULE_RAW and FLIGHT_SCHEDULE tables are created in base-setup to ensure they exist even if API key is not provided. This allows the installer to complete successfully without an API key. Verify they exist before proceeding.
