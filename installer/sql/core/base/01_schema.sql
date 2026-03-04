-- =============================================================================
-- DWELL_CORE: Universal Dwell + Congestion Contract Schema
-- Domain-agnostic primitives for tracking asset presence, dwell time, and
-- zone utilization at any facility type (airport, port, warehouse, etc.).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ${DATABASE}.DWELL_CORE
  COMMENT = 'Universal dwell and congestion analytics contract (domain-agnostic)';

GRANT USAGE ON SCHEMA ${DATABASE}.DWELL_CORE TO ROLE PUBLIC;
