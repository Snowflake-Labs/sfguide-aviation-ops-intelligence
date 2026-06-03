#!/usr/bin/env bash
# End-to-end deploy orchestrator for aviation-dashboard SPCS service.
#
# Chains: validate -> compile React -> build container (no-cache) -> push ->
# ALTER SERVICE with substituted tag -> verify running digest matches.
#
# Any step failure aborts the pipeline so partial/stale deployments are
# impossible. Run from anywhere; paths are resolved relative to this script.
#
# Required env vars:
#   SNOWFLAKE_CONNECTION  name of the snow CLI connection
#   TARGET_DB             target airport database (e.g. AIRPORT_SFO)
#   WAREHOUSE             warehouse for the service (e.g. AVIA_SFO_WH)
#
# Optional env vars:
#   SKIP_BUILD=1          reuse existing dist/ and image (push + ALTER only)
#   CONTAINER_CMD         override autodetected docker/podman
#   ALLOW_DIRTY=1         allow deploying with uncommitted changes (default: refused)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REACT_DIR="$SKILL_DIR/dashboard-react"
SCRIPTS_DIR="$SKILL_DIR/scripts"

: "${SNOWFLAKE_CONNECTION:?SNOWFLAKE_CONNECTION env var required}"
: "${TARGET_DB:?TARGET_DB env var required (e.g. AIRPORT_SFO)}"
: "${WAREHOUSE:?WAREHOUSE env var required (e.g. AVIA_SFO_WH)}"

# Refuse to deploy from a dirty working tree so every pushed image maps to a
# committed source state (override with ALLOW_DIRTY=1). Only enforced inside a
# git work tree; harmless outside one.
if command -v git >/dev/null 2>&1 && git -C "$SKILL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git -C "$SKILL_DIR" status --porcelain -- "$REACT_DIR")" ] && [ "${ALLOW_DIRTY:-0}" != "1" ]; then
    echo "ERROR: dashboard sources have uncommitted changes." >&2
    echo "       Commit them so the image tag maps to a git commit, or set ALLOW_DIRTY=1 to override." >&2
    git -C "$SKILL_DIR" status --short -- "$REACT_DIR" >&2
    exit 1
  fi
fi


# shellcheck disable=SC1091
source "$REACT_DIR/image-versions.env"
: "${AVIATION_DASHBOARD_TAG:?AVIATION_DASHBOARD_TAG missing from image-versions.env}"

echo "=== aviation-dashboard deploy ==="
echo "  TARGET_DB:   $TARGET_DB"
echo "  WAREHOUSE:   $WAREHOUSE"
echo "  CONNECTION:  $SNOWFLAKE_CONNECTION"
echo "  IMAGE_TAG:   $AVIATION_DASHBOARD_TAG"
echo ""

# ---- 1. Validate consumer consistency + code-drift guard --------------------
echo ">>> [1/6] Validate image-version consistency"
"$SCRIPTS_DIR/check_image_versions.sh"

# ---- 2. Compile React (native, outside container) --------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo ">>> [2/6] Compile React sources"
  (cd "$REACT_DIR" && npm ci --legacy-peer-deps && npm run build && npm run build:server)
else
  echo ">>> [2/6] Compile React sources (SKIPPED via SKIP_BUILD=1)"
fi

# Staleness guard: dist/ must be newer than any tracked source file.
if [ ! -f "$REACT_DIR/dist/index.html" ] || [ ! -f "$REACT_DIR/dist-server/index.js" ]; then
  echo "ERROR: dist/index.html or dist-server/index.js missing. Run 'npm run build' first." >&2
  exit 1
fi
NEWEST_SRC=$(find "$REACT_DIR/src" "$REACT_DIR/server" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.css' \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)
if [ -n "$NEWEST_SRC" ] && [ "$NEWEST_SRC" -nt "$REACT_DIR/dist/index.html" ]; then
  echo "ERROR: $NEWEST_SRC is newer than dist/index.html. Rebuild before packaging." >&2
  exit 1
fi

# ---- 3. Detect container runtime and auth registry -------------------------
echo ">>> [3/6] Build container image (no-cache, pinned tag)"
if [ -z "${CONTAINER_CMD:-}" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_CMD=docker
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD=podman
    podman machine start 2>/dev/null || true
  else
    echo "ERROR: neither docker nor podman found on PATH" >&2
    exit 1
  fi
fi
echo "    container runtime: $CONTAINER_CMD"

REPO_URL=$(snow spcs image-repository url "${TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO" -c "$SNOWFLAKE_CONNECTION")
echo "    repo URL: $REPO_URL"

IMAGE_REF="$REPO_URL/aviation_dashboard:${AVIATION_DASHBOARD_TAG}"

# Build (always --no-cache to prevent stale layer reuse).
if [ "$CONTAINER_CMD" = "podman" ]; then
  (cd "$REACT_DIR" && podman build --no-cache --rm --platform linux/amd64 \
    --ignorefile .dockerignore.prebuilt \
    -f Dockerfile.runtime \
    -t "$IMAGE_REF" .)
else
  # Docker: swap .dockerignore for prebuilt context, restore after.
  (cd "$REACT_DIR" && \
    cp .dockerignore .dockerignore.bak && \
    cp .dockerignore.prebuilt .dockerignore && \
    trap 'cp .dockerignore.bak .dockerignore && rm -f .dockerignore.bak' EXIT && \
    docker build --no-cache --rm --platform linux/amd64 \
      -f Dockerfile.runtime \
      -t "$IMAGE_REF" .)
fi

# ---- 4. Push to SPCS registry ---------------------------------------------
echo ">>> [4/6] Push image to SPCS registry"
if [ "$CONTAINER_CMD" = "podman" ]; then
  REGISTRY_HOST=$(echo "$REPO_URL" | cut -d'/' -f1)
  snow spcs image-registry token --format=JSON -c "$SNOWFLAKE_CONNECTION" \
    | podman login "$REGISTRY_HOST" -u 0sessiontoken --password-stdin
else
  snow spcs image-registry login -c "$SNOWFLAKE_CONNECTION"
fi
$CONTAINER_CMD push "$IMAGE_REF"

# ---- 5. ALTER SERVICE with substituted tag --------------------------------
echo ">>> [5/6] ALTER SERVICE FROM SPECIFICATION (substituting pinned tag)"
"$SCRIPTS_DIR/apply_service_spec.sh"

# ---- 6. Verify running service is on the pinned tag ----------------------
echo ">>> [6/6] Verify running image matches pinned tag"
"$SCRIPTS_DIR/verify_service_image.sh"

echo ""
echo "=== Deploy complete: aviation_dashboard:${AVIATION_DASHBOARD_TAG} ==="
