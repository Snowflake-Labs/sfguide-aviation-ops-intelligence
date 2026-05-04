#!/usr/bin/env bash
# Bump AVIATION_DASHBOARD_TAG in image-versions.env by semver component.
#
# Usage: bump_tag.sh patch|minor|major
# Forces developers through a script so tags cannot be silently reused
# (reusing a tag causes SPCS to serve the cached old digest on ALTER SERVICE).
set -euo pipefail

COMPONENT="${1:-}"
case "$COMPONENT" in
  patch|minor|major) ;;
  *)
    echo "Usage: $0 patch|minor|major" >&2
    exit 1
    ;;
esac

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$SKILL_DIR/dashboard-react/image-versions.env"

if [ ! -f "$VERSION_FILE" ]; then
  echo "ERROR: $VERSION_FILE not found" >&2
  exit 1
fi

CURRENT=$(grep -E '^AVIATION_DASHBOARD_TAG=' "$VERSION_FILE" | cut -d'=' -f2)
if [[ ! "$CURRENT" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "ERROR: current tag '$CURRENT' does not match vMAJOR.MINOR.PATCH" >&2
  exit 1
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

case "$COMPONENT" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac
NEW_TAG="v${MAJOR}.${MINOR}.${PATCH}"

echo "Bumping AVIATION_DASHBOARD_TAG: $CURRENT -> $NEW_TAG"

# Portable in-place sed (works on macOS and GNU).
sed -i.bak "s|^AVIATION_DASHBOARD_TAG=.*$|AVIATION_DASHBOARD_TAG=${NEW_TAG}|" "$VERSION_FILE"
rm -f "${VERSION_FILE}.bak"

# Also bump the documented image size row in build-images.md if present.
BUILD_MD="$SKILL_DIR/references/build-images.md"
if [ -f "$BUILD_MD" ]; then
  sed -i.bak "s|aviation_dashboard:${CURRENT}|aviation_dashboard:${NEW_TAG}|g" "$BUILD_MD"
  rm -f "${BUILD_MD}.bak"
fi

# Re-run the validator so consumers stay in sync.
"$SKILL_DIR/scripts/check_image_versions.sh"

echo ""
echo "Tag bumped to ${NEW_TAG}. Next: run scripts/deploy.sh to build/push/alter-service."
