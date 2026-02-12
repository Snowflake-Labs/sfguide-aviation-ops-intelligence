# Airport Analytics Platform - Deployment Guide

A Snowflake-native solution for batch aviation analytics using ADS-B flight tracking, flight schedules, and airport infrastructure data. Deploy per-airport analytics solutions with automated pipelines and interactive dashboards.

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
   - X-Small warehouse (recommended) or larger

3. **Snowflake Marketplace Listings** (free):
   - [Overture Maps - Base](https://app.snowflake.com/marketplace/listing/GZT0Z4CM1E9KV/carto-overture-maps-base)

### API Keys

1. **Aviationstack API Key (Optional)** (required for flight schedules)
   - Sign up at [aviationstack.com](https://aviationstack.com)
   - Paid tier recommended for production

---

## 🚀 Deployment via GitHub Integration

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
CREATE OR REPLACE API INTEGRATION github_api_integration
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
GRANT USAGE ON STREAMLIT AVIA_INSTALLER.PUBLIC.AIRPORT_ANALYTICS_INSTALLER TO ROLE <your_role>;
```

#### Step 5: Create Dashboard Streamlit App

```sql
CREATE OR REPLACE STREAMLIT AVIA_INSTALLER.PUBLIC.AIRPORT_ANALYTICS_DASHBOARD
  ROOT_LOCATION = '@avia_ops_repo/branches/main/dashboard'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = MY_WH  -- Replace with your warehouse
  TITLE = 'Airport Analytics Dashboard'
  COMMENT = 'Dashboard for Airport Analytics Platform';

-- Grant usage if needed (for non-ACCOUNTADMIN users)
GRANT USAGE ON STREAMLIT AVIA_INSTALLER.PUBLIC.AIRPORT_ANALYTICS_DASHBOARD TO ROLE <your_role>;
```

---

## 📁 Repository Structure

```
sd_poc/
├── installer/                    # Installer Streamlit app
│   ├── streamlit_app.py         # Main installer (4966 lines)
│   └── airlines.csv             # Airline reference data
│
├── dashboard/                    # Dashboard Streamlit app
│   ├── streamlit_app.py         # Main entry point
│   ├── utils.py                 # Shared utilities (1243 lines)
│   └── pages/                   # 8 dashboard pages
│       ├── 1_Flight_Tracker.py
│       ├── 2_Ground_Activity.py
│       ├── 3_Runway_Crossings.py
│       ├── 4_Traffic_Analysis.py
│       ├── 5_Gate_Analysis.py
│       ├── 7_Monitoring.py
│       └── 8_Performance.py
│
└── README.md                    # This deployment guide
```

Official Streamlit in Snowflake docs

- **[Aviationstack API Docs](https://aviationstack.com/documentation)**: Flight schedule API reference

- **[ADSB.lol API](https://api.adsb.lol/)**: ADS-B data source

- **[Overture Maps](https://overturemaps.org/)**: Open-source geospatial data for airport infrastructure
