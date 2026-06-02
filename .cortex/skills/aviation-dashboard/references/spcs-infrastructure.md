# SPCS Infrastructure for Aviation Dashboard

All SQL statements below use these substitution parameters:

| Parameter | Example | Description |
|-----------|---------|-------------|
| `{TARGET_DB}` | `AIRPORT_SAN` | Airport database created by base-setup |
| `{WAREHOUSE}` | `AVIA_SAN_WH` | Warehouse created by base-setup |
| `{ACCOUNT}` | `wgb26798` | Snowflake account identifier |

## 1. Session Query Tag

```sql
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## 2. Image Repository

```sql
CREATE IMAGE REPOSITORY IF NOT EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

Get the repository URL (needed for docker push):

```sql
SHOW IMAGE REPOSITORIES LIKE 'AVIATION_DASHBOARD_REPO' IN SCHEMA {TARGET_DB}.PUBLIC;
```

The `repository_url` column contains the push target (e.g., `<org>-<account>.registry.snowflakecomputing.com/{TARGET_DB}/public/aviation_dashboard_repo`).

## 3. Network Rule — CARTO Basemap CDN

The Express server proxies CARTO basemap tiles to avoid CORS issues in the browser. This requires egress to the CARTO CDN.

```sql
CREATE OR REPLACE NETWORK RULE {TARGET_DB}.PUBLIC.AVIATION_CARTO_NETWORK_RULE
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = (
    'a.basemaps.cartocdn.com:443',
    'b.basemaps.cartocdn.com:443',
    'c.basemaps.cartocdn.com:443',
    'd.basemaps.cartocdn.com:443'
  )
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## 4. External Access Integration

```sql
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {TARGET_DB}_AVIATION_CARTO_EAI
  ALLOWED_NETWORK_RULES = ({TARGET_DB}.PUBLIC.AVIATION_CARTO_NETWORK_RULE)
  ENABLED = TRUE
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## 5. Compute Pool

A single `CPU_X64_XS` node is sufficient — the dashboard is a lightweight Node.js Express server serving static React assets.

```sql
CREATE COMPUTE POOL IF NOT EXISTS AVIATION_DASHBOARD_COMPUTE_POOL
  INSTANCE_FAMILY = CPU_X64_XS
  MIN_NODES = 1
  MAX_NODES = 1
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 300
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## 6. Wait for Compute Pool ACTIVE

The compute pool must be `ACTIVE` (or `IDLE`) before creating services. If state is `STARTING`, wait ~2 minutes and re-check.

```sql
SHOW COMPUTE POOLS LIKE 'AVIATION_DASHBOARD_COMPUTE_POOL';
SELECT
    "name",
    "state",
    CASE "state"
        WHEN 'ACTIVE' THEN 'Ready — proceeding to create service'
        WHEN 'IDLE'   THEN 'Ready — proceeding to create service'
        ELSE 'WARNING: Pool state is ' || "state" || '. Wait for ACTIVE/IDLE then continue.'
    END AS STATUS_CHECK
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'AVIATION_DASHBOARD_COMPUTE_POOL';
```

If not ACTIVE, wait and re-run the SHOW/SELECT above. Typical startup time: 1-3 minutes.

## 7. Create Service

Uses inline specification to avoid wrong-image-path bugs from template files. No `AUTO_SUSPEND_SECS` — public endpoints are incompatible with auto-suspend. `CREATE OR REPLACE SERVICE` is not supported — use `DROP SERVICE IF EXISTS` + `CREATE SERVICE` to redeploy.

```sql
DROP SERVICE IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;

CREATE SERVICE {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE
  IN COMPUTE POOL AVIATION_DASHBOARD_COMPUTE_POOL
  FROM SPECIFICATION $$
spec:
  containers:
    - name: aviation-dashboard
      image: /{TARGET_DB}/public/aviation_dashboard_repo/aviation_dashboard:{AVIATION_DASHBOARD_TAG}
      env:
        SNOWFLAKE_DATABASE: "{TARGET_DB}"
        SNOWFLAKE_WAREHOUSE: "{WAREHOUSE}"
      resources:
        requests:
          cpu: "0.5"
          memory: "512Mi"
        limits:
          cpu: "1"
          memory: "1Gi"
  endpoints:
    - name: aviation-dashboard
      port: 3001
      public: true
$$
  MIN_INSTANCES = 1
  MAX_INSTANCES = 1
  QUERY_WAREHOUSE = {WAREHOUSE}
  EXTERNAL_ACCESS_INTEGRATIONS = ({TARGET_DB}_AVIATION_CARTO_EAI)
  COMMENT = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';
```

## 8. Verify Service

```sql
SELECT SYSTEM$GET_SERVICE_STATUS('{TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE');
```

Expected: `"status":"READY"` or `"status":"RUNNING"`. If `PENDING`, check compute pool state and image availability.

## 9. Get Public Endpoint URL

```sql
SHOW ENDPOINTS IN SERVICE {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;
```

The `ingress_url` column contains the public URL for the dashboard.

## 10. Grant Access to Other Roles

```sql
GRANT USAGE ON SERVICE {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE TO ROLE {CONSUMER_ROLE};
```

## Cleanup

Drop in reverse order (service first, infrastructure last):

```sql
DROP SERVICE IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE;
DROP COMPUTE POOL IF EXISTS AVIATION_DASHBOARD_COMPUTE_POOL;
DROP IMAGE REPOSITORY IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO;
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS {TARGET_DB}_AVIATION_CARTO_EAI;
DROP NETWORK RULE IF EXISTS {TARGET_DB}.PUBLIC.AVIATION_CARTO_NETWORK_RULE;
```
