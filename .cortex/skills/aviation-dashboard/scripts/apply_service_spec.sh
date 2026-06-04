#!/usr/bin/env bash
# Substitute placeholders in aviation_dashboard_service.yaml and run
# ALTER SERVICE ... FROM SPECIFICATION $$...$$ so SPCS pulls the new digest.
#
# Required env vars:
#   SNOWFLAKE_CONNECTION, TARGET_DB, WAREHOUSE
# Tag comes from dashboard-react/image-versions.env.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REACT_DIR="$SKILL_DIR/dashboard-react"
SPEC_TEMPLATE="$REACT_DIR/aviation_dashboard_service.yaml"

: "${SNOWFLAKE_CONNECTION:?SNOWFLAKE_CONNECTION required}"
: "${TARGET_DB:?TARGET_DB required}"
: "${WAREHOUSE:?WAREHOUSE required}"
# shellcheck disable=SC1091
source "$REACT_DIR/image-versions.env"
: "${AVIATION_DASHBOARD_TAG:?AVIATION_DASHBOARD_TAG missing}"
# Bare semver (strip leading 'v') drives the runtime APP_VERSION env so the
# in-app footer always tracks the deployed image tag.
AVIATION_DASHBOARD_VERSION="${AVIATION_DASHBOARD_TAG#v}"

if [ ! -f "$SPEC_TEMPLATE" ]; then
  echo "ERROR: spec template not found at $SPEC_TEMPLATE" >&2
  exit 1
fi

SPEC_RESOLVED=$(sed \
  -e "s|{TARGET_DB}|${TARGET_DB}|g" \
  -e "s|{WAREHOUSE}|${WAREHOUSE}|g" \
  -e "s|{AVIATION_DASHBOARD_TAG}|${AVIATION_DASHBOARD_TAG}|g" \
  -e "s|{AVIATION_DASHBOARD_VERSION}|${AVIATION_DASHBOARD_VERSION}|g" \
  "$SPEC_TEMPLATE")

if echo "$SPEC_RESOLVED" | grep -q '{[A-Z_]*}'; then
  echo "ERROR: unresolved placeholders remain in spec:" >&2
  echo "$SPEC_RESOLVED" | grep '{[A-Z_]*}' >&2
  exit 1
fi

TMP_SQL=$(mktemp)
trap 'rm -f "$TMP_SQL"' EXIT
cat > "$TMP_SQL" <<SQL
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is-aviation","name":"oss-aviation-dashboard","version":{"major":1,"minor":0},"attributes":{"is_quickstart":1,"source":"sql"}}';

ALTER SERVICE ${TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE
  FROM SPECIFICATION \$\$
${SPEC_RESOLVED}
\$\$;
SQL

snow sql -f "$TMP_SQL" -c "$SNOWFLAKE_CONNECTION"
