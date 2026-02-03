# Airport Analytics Platform - Deployment Guide

A Snowflake-native solution for batch aviation analytics using ADS-B flight tracking, flight schedules, and airport infrastructure data. Deploy complete per-airport analytics databases with automated pipelines and interactive dashboards.

## ✈️ Key Features

- **Batch Flight Tracking**: Daily ADS-B ingestion (previous day)
- **Historical Backfill**: Automated download of historical ADS-B data from GitHub releases
- **Flight Schedule Integration**: Daily ingestion from Aviationstack API with automated matching
- **Gate Analytics**: Aircraft-to-gate proximity analysis with dwell time calculations
- **Runway Crossing Detection**: Identifies taxiing aircraft crossing runways
- **Infrastructure Visualization**: Dynamic rendering of runways, taxiways, gates, and terminals
- **Multi-Airport Support**: Deploy separate databases for multiple airports

---

## 📋 Prerequisites

### Snowflake Account Requirements

1. **Role**: ACCOUNTADMIN or equivalent with permissions to:
   - CREATE DATABASE, SCHEMA
   - CREATE EXTERNAL ACCESS INTEGRATION
   - CREATE SECRET
   - CREATE PROCEDURE (with Python handler)
   - CREATE TASK, DYNAMIC TABLE
   - CREATE STREAMLIT

2. **Warehouse**: 
   - M-L warehouse for Installer app and production data pipelines
   - M warehouse for Streamlit dashboard

3. **Snowflake Marketplace Listings** (free):
   - [Overture Maps - Base](https://app.snowflake.com/marketplace/listing/GZT0Z4CM1E9KV/carto-overture-maps-base)

### API Keys

1. **Aviationstack API Key (Optional)** (required for flight schedules)
   - Sign up at [aviationstack.com](https://aviationstack.com)
   - Free tier: 100 requests/month (sufficient for 1-2 airports)
   - Paid tier recommended for production

2. **GitHub Personal Access Token** (If you access installer and Dashboard via GitHub integration)
   - Generate at GitHub Settings → Developer Settings → Personal Access Tokens
   - Scopes needed: `public_repo` (read-only)

---

## 🚀 Deployment Options

Choose one of two deployment methods:

### Option 1: Manual File Upload

**Best for**: Quick setup, testing, or when you don't have a Git repository.

#### Step 1: Create Installer Streamlit App

1. Log in to your Snowflake account
2. Navigate to **Streamlit** in the left sidebar
3. Click **+ Streamlit App**
4. Configure:
   - **Name**: `AIRPORT_ANALYTICS_INSTALLER`
   - **Warehouse**: Select an XS or S warehouse
   - **App Location**: Choose database and schema (e.g., `AVIA_INSTALLER.PUBLIC`)
5. Click **Create**
6. In the file browser on the left:
   - Upload `installer/streamlit_app.py` (main file)
   - Upload `installer/airlines.csv` (reference data)
7. Set `streamlit_app.py` as the main file
8. Click **Run**

**Note on API Key File**: Create `aviationstack_api_key.txt` with your API key:
```
your_aviationstack_api_key_here
```

#### Step 2: Create Dashboard Streamlit App

1. Navigate to **Streamlit** → **+ Streamlit App**
2. Configure:
   - **Name**: `AIRPORT_ANALYTICS_DASHBOARD`
   - **Warehouse**: Select an M or L warehouse
   - **App Location**: Choose database and schema (e.g., `AVIA_INSTALLER.PUBLIC`)
3. Click **Create**
4. Upload the entire `dashboard/` folder structure:
   - `dashboard/streamlit_app.py` (main file)
   - `dashboard/utils.py`
   - `dashboard/pages/` folder with all 8 page files:
     - `1_Flight_Tracker.py`
     - `2_Airport_Activity.py`
     - `3_Runway_Crossings.py`
     - `4_Traffic_Analysis.py`
     - `5_Gate_Analysis.py`
     - `6_Operations.py`
     - `7_Monitoring.py`
     - `8_Performance.py`
   - `dashboard/images/` folder with assets
5. Set `streamlit_app.py` as the main file
6. Click **Run**

---

### Option 2: GitHub Integration

#### Step 1: Set Up Secrets in Snowflake

Execute these queries in a Snowflake worksheet (replace placeholders):

```sql
CREATE OR REPLACE DATABASE AVIA_INSTALLER;
USE ROLE ACCOUNTADMIN;
USE DATABASE AVIA_INSTALLER;
USE SCHEMA PUBLIC;

```

#### Step 2: Create API Integration for GitHub (if not exists)

```sql
CREATE API INTEGRATION IF NOT EXISTS github_api_integration
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/Snowflake-Labs/')
  ENABLED = TRUE;
```
#### Step 3: Create Git Repository Object (NO credentials needed for public repos)

```sql
CREATE OR REPLACE GIT REPOSITORY AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO
  API_INTEGRATION = github_api_integration
  ORIGIN = 'https://github.com/Snowflake-Labs/sfguide-aviation-ops-intelligence/';
-- Fetch latest files from repository
  ALTER GIT REPOSITORY avia_ops_repo FETCH;
```

#### Step 4: Create Installer Streamlit App from Git

```sql
CREATE OR REPLACE STREAMLIT AVIA_INSTALLER.PUBLIC.AIRPORT_ANALYTICS_INSTALLER
  ROOT_LOCATION = '@avia_ops_repo/branches/main/installer'
  MAIN_FILE = 'installer_daily.py'
  QUERY_WAREHOUSE = MY_WH  -- Replace with your warehouse
  TITLE = 'Airport Analytics Installer'
  COMMENT = 'Installer for Airport Analytics Platform - generates and deploys airport infrastructure';

-- Grant usage if needed (for non-ACCOUNTADMIN users)
GRANT USAGE ON STREAMLIT AVIA_INSTALLER.PUBLIC.airport_analytics_installer TO ROLE <your_role>;
```

---

## 📁 Repository Structure

```
sd_poc/
├── installer/                    # Installer Streamlit app
│   ├── streamlit_app.py         # Main installer (4966 lines)
│   ├── airlines.csv             # Airline reference data
│   └── aviationstack_api_key.txt # API key file (not in Git)
│
├── dashboard/                    # Dashboard Streamlit app
│   ├── streamlit_app.py         # Main entry point
│   ├── utils.py                 # Shared utilities (1243 lines)
│   ├── pages/                   # 8 dashboard pages
│   │   ├── 1_Flight_Tracker.py
│   │   ├── 2_Airport_Activity.py
│   │   ├── 3_Runway_Crossings.py
│   │   ├── 4_Traffic_Analysis.py
│   │   ├── 5_Gate_Analysis.py
│   │   ├── 7_Monitoring.py
│   │   └── 8_Performance.py
│   └── images/                  # Dashboard assets
│
├── COMPREHENSIVE_README.md      # Technical documentation (1900+ lines)
├── README.md                    # This deployment guide
├── snowflake.yml               # Snowflake CLI config (optional)
└── old/                        # Legacy docs (can be ignored)
```

**Key Files:**
- **installer/streamlit_app.py**: Generates and deploys SQL for airport infrastructure
- **dashboard/streamlit_app.py**: Main dashboard entry point (redirects to Flight Tracker)
- **dashboard/utils.py**: Shared utilities for airport selection, infrastructure rendering, time filters

---

## 🔧 Troubleshooting

### Common Issues

#### 1. "No airport databases found" in Dashboard

**Cause**: No `AIRPORT_XXX` databases with `PUBLIC.PROPERTIES_AIRPORT` table exist.

**Fix**: Run the Installer app first to deploy at least one airport.

#### 2. Installer execution fails with permission errors

**Cause**: Missing required privileges.

**Fix**: Ensure you have ACCOUNTADMIN role or equivalent with:
```sql
USE ROLE ACCOUNTADMIN;
-- Then re-run installer
```

#### 3. "External Access Integration already exists" error

**Cause**: EAI names must be unique per airport. Installer uses `AIRPORT_XXX_*_EAI` pattern.

**Fix**: This is expected if re-running installer. The installer uses `CREATE OR REPLACE` to handle this.

#### 4. Low schedule match rate (<30%) in Monitoring page

**Possible causes**:
- Aviationstack API key exhausted (check quota at aviationstack.com)
- Flight schedule ingestion task not running
- Enrichment task not running

**Fix**:
```sql
-- Check task status
USE DATABASE AIRPORT_<XXX>;
USE SCHEMA PUBLIC;
SHOW TASKS;

-- Resume suspended tasks
ALTER TASK TASK_FLIGHT_SCHEDULE RESUME;
ALTER TASK TASK_ENRICH_ADSB RESUME;

-- Manually trigger enrichment
CALL PROC_ENRICH_ADSB_WITH_SCHEDULE(24);  -- Enrich last 24 hours
```

#### 5. No data appearing in Dashboard

**Possible causes**:
- Daily ingestion task not running
- Dynamic tables not refreshing
- Warehouse suspended

**Debug**:
```sql
-- Check if ADSB_DATA has recent data
SELECT COUNT(*), MAX(TIMESTAMP) 
FROM AIRPORT_<XXX>.PUBLIC.ADSB_DATA;

-- Check task state
SHOW TASKS IN SCHEMA AIRPORT_<XXX>.PUBLIC;

-- Check dynamic table state
SHOW DYNAMIC TABLES IN SCHEMA AIRPORT_<XXX>.PUBLIC;

-- Manually trigger ingestion
CALL AIRPORT_<XXX>.PUBLIC.PROC_INGEST_ADSB();
```

#### 6. GitHub integration fails with "Repository not found"

**Cause**: API integration prefix doesn't match repository URL, or PAT lacks permissions.

**Fix**:
```sql
-- Verify API integration allowed prefixes
SHOW API INTEGRATIONS LIKE 'github_api_integration';

-- Verify Git repository
SHOW GIT REPOSITORIES;

-- Test repository access (fully qualified)
LS @AVIA_INSTALLER.PUBLIC.AVIA_OPS_REPO/branches/main;
```

If listing fails, regenerate your GitHub PAT with correct permissions and recreate the secret.

#### 7. Warehouse sizing issues

**Symptoms**: Slow queries, task failures, high credit consumption.

**Recommendations**:
- **Installer app**: XS-S warehouse (short-lived operations)
- **Dashboard app**: M-L warehouse (interactive queries)
- **Data pipeline tasks**: M-L warehouse (continuous ingestion)
- **Backfill task**: L-XL warehouse (large TAR file processing)

**Fix**:
```sql
-- Update Streamlit app warehouse (fully qualified)
ALTER STREAMLIT AVIA_INSTALLER.PUBLIC.airport_analytics_dashboard 
  SET QUERY_WAREHOUSE = <larger_warehouse>;

-- Update task warehouse (fully qualified)
ALTER TASK AIRPORT_<XXX>.PUBLIC.TASK_INGEST_ADSB 
  SET WAREHOUSE = <your_warehouse>;
ALTER TASK AIRPORT_<XXX>.PUBLIC.TASK_INGEST_ADSB RESUME;
```

---

## 📚 Additional Resources

- **[COMPREHENSIVE_README.md](COMPREHENSIVE_README.md)**: Complete technical documentation covering:
  - Architecture and data model
  - Detailed table/procedure reference
  - Data flow diagrams
  - Task orchestration
  - Advanced troubleshooting
  
- **[Snowflake Streamlit Documentation](https://docs.snowflake.com/en/developer-guide/streamlit/about-streamlit)**: Official Streamlit in Snowflake docs

- **[Aviationstack API Docs](https://aviationstack.com/documentation)**: Flight schedule API reference

- **[ADSB.lol API](https://api.adsb.lol/)**: ADS-B data source

- **[Overture Maps](https://overturemaps.org/)**: Open-source geospatial data for airport infrastructure
