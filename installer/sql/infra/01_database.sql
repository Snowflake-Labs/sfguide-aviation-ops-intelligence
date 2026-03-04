-- =============================================================================
-- BASE INFRASTRUCTURE
-- Database: ${DATABASE}.${SCHEMA}
-- =============================================================================

-- Create database and schema
CREATE DATABASE IF NOT EXISTS ${DATABASE};
CREATE SCHEMA IF NOT EXISTS ${DATABASE}.${SCHEMA};

-- Grant usage (adjust roles as needed)
GRANT USAGE ON DATABASE ${DATABASE} TO ROLE PUBLIC;
GRANT USAGE ON SCHEMA ${DATABASE}.${SCHEMA} TO ROLE PUBLIC;

-- -----------------------------------------------------------------------------
-- PyPI Network Access (for Python package installation in procedures)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE NETWORK RULE ${DATABASE}.${SCHEMA}.${SCHEMA}_pypi_network_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('pypi.org', 'pypi.python.org', 'pythonhosted.org', 'files.pythonhosted.org');
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ${DATABASE}_${SCHEMA}_pypi_access_integration
  ALLOWED_NETWORK_RULES = (${DATABASE}.${SCHEMA}.${SCHEMA}_pypi_network_rule)
  ENABLED = TRUE;

-- =============================================================================
-- SOLUTION TRACKING TAGS
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ${DATABASE}.TAGS
  COMMENT = 'Cost attribution tags for Aviation Ops Intelligence solution';

CREATE TAG IF NOT EXISTS ${DATABASE}.TAGS.SOLUTION
  ALLOWED_VALUES 'aviation-ops-intelligence'
  COMMENT = 'Identifies objects belonging to Aviation Ops Intelligence solution';

CREATE TAG IF NOT EXISTS ${DATABASE}.TAGS.COMPONENT
  ALLOWED_VALUES 'etl', 'analytics', 'realtime', 'backfill', 'properties'
  COMMENT = 'Functional component categorization';
