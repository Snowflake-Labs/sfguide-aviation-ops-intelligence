#!/usr/bin/env bash
# Validates that the image tag(s) in image-versions.env match every reference
# across the aviation-dashboard skill (service YAML, build-images.md, SKILL.md).
#
# Usage:   .cortex/skills/aviation-dashboard/scripts/check_image_versions.sh
# Exit 0:  all references consistent
# Exit 1:  one or more files out of sync with image-versions.env
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REACT_DIR="$SKILL_DIR/dashboard-react"

VERSION_FILE="$REACT_DIR/image-versions.env"
SERVICE_YAML="$REACT_DIR/aviation_dashboard_service.yaml"
BUILD_MD="$SKILL_DIR/references/build-images.md"
SKILL_MD="$SKILL_DIR/SKILL.md"

if [ ! -f "$VERSION_FILE" ]; then
  echo "ERROR: image-versions.env not found at $VERSION_FILE"
  exit 1
fi
if [ ! -f "$SERVICE_YAML" ]; then
  echo "ERROR: service YAML not found at $SERVICE_YAML"
  exit 1
fi

# shellcheck disable=SC1090
source "$VERSION_FILE"

IMAGE_NAMES="aviation_dashboard"
IMAGE_TAGS="$AVIATION_DASHBOARD_TAG"

errors=0
error() {
  echo "MISMATCH: $1"
  errors=$((errors + 1))
}

echo "=== Aviation Dashboard Image Version Consistency Check ==="
echo ""
echo "Source of truth (image-versions.env):"
i=1
for image in $IMAGE_NAMES; do
  tag=$(echo "$IMAGE_TAGS" | cut -d' ' -f$i)
  echo "  ${image}:${tag}"
  i=$((i + 1))
done
echo ""

# Service YAML uses templated placeholder {AVIATION_DASHBOARD_TAG} so the
# dashboard skill can substitute the actual value at deploy time. We validate
# the placeholder exists AND that build-images.md references the pinned tag.
if ! grep -qF "aviation_dashboard:{AVIATION_DASHBOARD_TAG}" "$SERVICE_YAML"; then
  error "$SERVICE_YAML missing placeholder aviation_dashboard:{AVIATION_DASHBOARD_TAG}"
fi

i=1
for image in $IMAGE_NAMES; do
  tag=$(echo "$IMAGE_TAGS" | cut -d' ' -f$i)
  pair="${image}:${tag}"

  if [ -f "$BUILD_MD" ]; then
    if ! grep -qF "$pair" "$BUILD_MD"; then
      error "build-images.md missing $pair"
    fi
  else
    error "build-images.md not found at $BUILD_MD"
  fi

  if [ -f "$SKILL_MD" ]; then
    # SKILL.md reference is optional — only flag if tag appears with wrong value.
    if grep -qE "aviation_dashboard:v[0-9]" "$SKILL_MD" && ! grep -qF "$pair" "$SKILL_MD"; then
      error "SKILL.md references a different aviation_dashboard tag (expected $pair)"
    fi
  fi

  # Guard against accidental :latest re-introduction anywhere in the skill tree.
  # Exclude this validator script itself — it documents the anti-pattern in strings.
  STRAY_LATEST=$(grep -rln "aviation_dashboard:latest" "$SKILL_DIR" 2>/dev/null \
    | grep -v "scripts/check_image_versions.sh" || true)
  if [ -n "$STRAY_LATEST" ]; then
    error "aviation_dashboard:latest found in: $STRAY_LATEST (use pinned tag)"
  fi

  i=$((i + 1))
done

# Code-drift guard: if React/server sources or the Dockerfile have changed
# since image-versions.env was last modified, the tag MUST be bumped before
# deploy — otherwise `podman push` overwrites the tag and SPCS serves the
# cached old digest. Only runs when inside a git working tree.
if command -v git >/dev/null 2>&1 && git -C "$SKILL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TAG_COMMIT=$(git -C "$SKILL_DIR" log -1 --format=%H -- "$VERSION_FILE" 2>/dev/null || true)
  if [ -n "$TAG_COMMIT" ]; then
    DRIFT=$(git -C "$SKILL_DIR" diff --name-only "$TAG_COMMIT" HEAD -- \
      "dashboard-react/src" \
      "dashboard-react/server" \
      "dashboard-react/Dockerfile.runtime" \
      "dashboard-react/package.json" \
      "dashboard-react/package-lock.json" \
      "dashboard-react/vite.config.ts" 2>/dev/null | head -10 || true)
    UNCOMMITTED=$(git -C "$SKILL_DIR" status --porcelain -- \
      "dashboard-react/src" \
      "dashboard-react/server" \
      "dashboard-react/Dockerfile.runtime" \
      "dashboard-react/package.json" \
      "dashboard-react/package-lock.json" \
      "dashboard-react/vite.config.ts" 2>/dev/null | head -10 || true)
    if [ -n "$DRIFT" ] || [ -n "$UNCOMMITTED" ]; then
      echo ""
      echo "CODE DRIFT: sources changed since AVIATION_DASHBOARD_TAG=${AVIATION_DASHBOARD_TAG} was cut."
      [ -n "$DRIFT" ] && { echo "Committed changes after tag bump:"; echo "$DRIFT" | sed 's/^/  /'; }
      [ -n "$UNCOMMITTED" ] && { echo "Uncommitted changes:"; echo "$UNCOMMITTED" | sed 's/^/  /'; }
      echo "Run scripts/bump_tag.sh patch|minor|major before deploy."
      error "code drift vs. pinned tag"
    fi
  fi
fi

echo ""
if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors mismatch(es) found. Update files or image-versions.env."
  exit 1
fi

echo "OK: all references match image-versions.env."
