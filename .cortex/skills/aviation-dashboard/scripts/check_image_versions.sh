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

echo ""
if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors mismatch(es) found. Update files or image-versions.env."
  exit 1
fi

echo "OK: all references match image-versions.env."
