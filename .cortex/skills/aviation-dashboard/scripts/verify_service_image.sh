#!/usr/bin/env bash
# Post-deploy sanity check: confirm the SPCS service is running the pinned tag.
# Parses SYSTEM$GET_SERVICE_STATUS JSON and asserts spec.containers[].image
# ends with the expected :${AVIATION_DASHBOARD_TAG}.
#
# Required env vars:
#   SNOWFLAKE_CONNECTION, TARGET_DB
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REACT_DIR="$SKILL_DIR/dashboard-react"

: "${SNOWFLAKE_CONNECTION:?SNOWFLAKE_CONNECTION required}"
: "${TARGET_DB:?TARGET_DB required}"
# shellcheck disable=SC1091
source "$REACT_DIR/image-versions.env"
: "${AVIATION_DASHBOARD_TAG:?AVIATION_DASHBOARD_TAG missing}"

EXPECTED_SUFFIX=":${AVIATION_DASHBOARD_TAG}"
SERVICE="${TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_SERVICE"

echo "Verifying ${SERVICE} is running aviation_dashboard${EXPECTED_SUFFIX}"

# Give SPCS a few seconds to register the new spec after ALTER SERVICE.
for attempt in 1 2 3 4 5 6; do
  RAW=$(snow sql -q "SELECT SYSTEM\$GET_SERVICE_STATUS('${SERVICE}') AS status" \
          -c "$SNOWFLAKE_CONNECTION" --format json 2>/dev/null || true)
  # Extract the image reference via grep (robust to snow CLI format drift).
  ACTUAL=$(echo "$RAW" | grep -oE '"image"[^,}]+' | head -1 | cut -d'"' -f4 || true)
  if [ -z "$ACTUAL" ]; then
    ACTUAL=$(echo "$RAW" | grep -oE '/aviation_dashboard:[A-Za-z0-9._-]+' | head -1 || true)
  fi
  if [ -n "$ACTUAL" ]; then
    break
  fi
  echo "  (attempt $attempt) service status not ready yet, retrying in 5s..."
  sleep 5
done

if [ -z "${ACTUAL:-}" ]; then
  echo "ERROR: could not read current image from SYSTEM\$GET_SERVICE_STATUS" >&2
  echo "Raw response:" >&2
  echo "$RAW" >&2
  exit 1
fi

echo "  running image: $ACTUAL"
case "$ACTUAL" in
  *"${EXPECTED_SUFFIX}") echo "OK: service running pinned tag ${AVIATION_DASHBOARD_TAG}" ;;
  *)
    echo "FAIL: service running '$ACTUAL', expected suffix '${EXPECTED_SUFFIX}'." >&2
    echo "Likely causes:" >&2
    echo "  - ALTER SERVICE silently cached previous spec (tag was reused)." >&2
    echo "  - Spec placeholder substitution failed." >&2
    echo "  - ALTER SERVICE was applied to a different service name." >&2
    exit 1
    ;;
esac
