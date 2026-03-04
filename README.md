# Airport Analytics Platform - Deployment Guide

A Snowflake-native solution for batch aviation analytics using ADS-B flight tracking, flight schedules, and airport infrastructure data. Deploy per-airport analytics solutions with automated pipelines and interactive dashboards.

## 📖 What Does This Application Do?

The Airport Analytics Platform is a comprehensive aviation operations intelligence solution built entirely on Snowflake. It provides:

### Core Capabilities
- **Airport Infrastructure Visualization**: Renders interactive maps showing runways, taxiways, gates, terminals, and real-time aircraft positions
- **Historical Data Analysis**: Downloads and processes historical flight tracking data for trend analysis and reporting
- **Gate Operations Analytics**: 
  - Calculates aircraft proximity to gates
  - Tracks gate occupancy and dwell times
  - Identifies gate assignment patterns
- **Runway Safety Monitoring**: Detects aircraft crossing active runways during taxi operations
- **Multi-Airport Deployments**: Supports deploying separate analytics instances for different airports

### How It Works
1. **Data Ingestion**: Automated daily tasks pull ADS-B data from external APIs and process flight schedules
2. **Data Processing**: Snowflake procedures and dynamic tables transform raw data into analytics-ready datasets
3. **Analytics Engine**: Calculates proximity, crossings, dwell times, and other operational metrics
4. **Visualization**: Interactive Streamlit dashboards provide real-time insights and historical reporting

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

#### Step 1: Create a Database for Installer

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
  MAIN_FILE = 'installer_airport.py'
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

## 🎯 What to Do After Deployment

Once you've completed the GitHub Integration steps above, follow these steps to configure and launch your airport analytics:

### Step 1: Access the Installer App

1. Navigate to **Streamlit** in your Snowflake UI (left sidebar)
2. Find and open **Airport Analytics Installer** 
3. In the app:
- Select the airport for which you want to install the solution
- Optionally specify the Aviationstack API Key
- Specify how many days in the past you want to backfill (for demo we recommend 5-7days)
- Click "Execute in Snowflake"

### Step 2: Monitor Deployment

The installer will show real-time progress:
- Infrastructure download and processing
- Database and schema creation
- External access integration setup
- Task and procedure creation
- Historical data backfill (if enabled)

Deployment typically takes **15-60 minutes** depending on:
- Airport size and complexity
- Whether historical backfill is enabled
- Network speed for data downloads

### Step 4: Launch the Dashboard

Once deployment is complete:

1. Navigate to **Streamlit** in Snowflake
2. Open **Airport Analytics Dashboard** in `AVIA_INSTALLER.PUBLIC`
3. **Select your airport from the airport selector** from the dropdown (e.g., `San Diego International Airport (SAN)`)
4. Explore the dashboard pages:

- **Flight Tracker**: Historical flight positions on interactive map
- **Ground Activity**: Aircraft movements, taxi patterns, and ground operations
- **Runway Crossings**: Safety analysis of aircraft crossing active runways
- **Traffic Analysis**: Flight volume trends, peak times, and traffic patterns
- **Gate Analysis**: Gate utilization, occupancy rates, and dwell time analytics
- **Monitoring**: System health, data freshness, and pipeline status
- **Performance**: Query performance and optimization metrics

## Initial Data

After deployment, data will begin populating:

- **Infrastructure Data**: Available immediately after deployment
- **Historical Data**: Available within 1 hours if backfill was enabled

**Note**: The dashboard will show limited data until the first task executions complete. Check the **Monitoring** page to track data pipeline status.

---

## 📚 Additional Resources

- **[Streamlit in Snowflake Documentation](https://docs.snowflake.com/en/developer-guide/streamlit/about-streamlit)**: Official Streamlit in Snowflake docs
- **[Aviationstack API Docs](https://aviationstack.com/documentation)**: Flight schedule API reference
- **[ADSB.lol API](https://api.adsb.lol/)**: ADS-B data source
- **[Overture Maps](https://overturemaps.org/)**: Open-source geospatial data

---
