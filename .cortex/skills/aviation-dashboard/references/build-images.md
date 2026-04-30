# Build and Push Aviation Dashboard Image

Build the Docker image for the React dashboard and push it to the Snowflake SPCS image repository. Supports both Docker and Podman, with a workaround for ARM Mac (Apple Silicon).

> **Working directory:** All commands below run from `.cortex/skills/aviation-dashboard/dashboard-react/`.

## Image Versioning — Single Source of Truth

All image tags are defined in [image-versions.env](../dashboard-react/image-versions.env). Bump the tag there **first**, then rebuild/push. The [check_image_versions.sh](../scripts/check_image_versions.sh) script validates that every service YAML and doc references the pinned tag — run it before pushing or deploying.

```bash
# Load pinned tag(s) for use in build commands
source dashboard-react/image-versions.env
echo "Will build aviation_dashboard:${AVIATION_DASHBOARD_TAG}"
```

> **Never use `:latest`.** SPCS caches `:latest` and will not re-pull on `ALTER SERVICE`, causing stale deployments. Always push a new semver tag (`v1.0.1`, `v1.0.2`, ...) and update `image-versions.env` on each release.

## 1. Detect Container Runtime

```bash
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  CONTAINER_CMD=docker
elif command -v podman &>/dev/null; then
  CONTAINER_CMD=podman
  # On macOS, podman info succeeds even when the machine is stopped — always start it
  podman machine start 2>/dev/null || true
else
  echo "ERROR: Neither docker nor podman found. Install one and retry."
  exit 1
fi
echo "Using: $CONTAINER_CMD"
```

## 2. Authenticate with SPCS Image Registry

**Docker:**
```bash
snow spcs image-registry login -c <connection>
```

**Podman:**
```bash
REGISTRY_URL=$(snow spcs image-repository url {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO -c <connection> | cut -d'/' -f1)
snow spcs image-registry token --format=JSON -c <connection> | podman login $REGISTRY_URL -u 0sessiontoken --password-stdin
```

If Podman login fails with "unable to retrieve auth token", use the manual `--creds` flag on every push instead:
```bash
TOKEN=$(snow spcs image-registry token --format=JSON -c <connection>)
podman push --creds "0sessiontoken:$TOKEN" $REPO_URL/aviation_dashboard:${AVIATION_DASHBOARD_TAG}
```

## 3. Get Repository URL

```bash
REPO_URL=$(snow spcs image-repository url {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO -c <connection>)
echo $REPO_URL
```

## 4. Build Image

### Standard Flow (Linux / Docker Desktop on amd64)

```bash
source dashboard-react/image-versions.env   # loads AVIATION_DASHBOARD_TAG
$CONTAINER_CMD build --rm --platform linux/amd64 \
  -f Dockerfile.runtime \
  -t $REPO_URL/aviation_dashboard:${AVIATION_DASHBOARD_TAG} .
```

### ARM Mac Flow (Apple Silicon)

On ARM Macs, `esbuild` crashes with a QEMU segfault when running `npm run build` inside `--platform linux/amd64`. The workaround: build locally with native ARM, then create a container that only copies the pre-built artifacts.

**Step 1 — Build locally (native ARM, no QEMU):**
```bash
npm ci --legacy-peer-deps
npm run build
npm run build:server
```

**Step 2a — Podman: use `--ignorefile`:**
```bash
source image-versions.env
$CONTAINER_CMD build --rm --platform linux/amd64 \
  --ignorefile .dockerignore.prebuilt \
  -f Dockerfile.runtime \
  -t $REPO_URL/aviation_dashboard:${AVIATION_DASHBOARD_TAG} .
```

**Step 2b — Docker: swap `.dockerignore` manually (Docker 29.x does NOT support `--ignorefile`):**
```bash
cp .dockerignore .dockerignore.bak
cp .dockerignore.prebuilt .dockerignore
source image-versions.env
docker build --rm --platform linux/amd64 \
  -f Dockerfile.runtime \
  -t $REPO_URL/aviation_dashboard:${AVIATION_DASHBOARD_TAG} .
cp .dockerignore.bak .dockerignore && rm .dockerignore.bak
```

The `.dockerignore.prebuilt` allows `dist/` and `dist-server/` into the build context. The `Dockerfile.runtime` conditional guard (`[ -d dist ] || npm run build`) skips the build when `dist/` already exists.

> **WARNING — Shell operator precedence:** NEVER chain npm and docker/podman commands like:
> ```bash
> npm run build && $CONTAINER_CMD build ... || true   # WRONG!
> ```
> Due to shell left-associativity, `(a && b && c) || true` swallows build failures, producing a **white-page app** with an empty `dist/`. Always run npm and container commands as **separate invocations**.

### Verify build before push

```bash
ls -la dist/index.html dist-server/index.js 2>/dev/null && echo "Build OK" || echo "ERROR: dist/ or dist-server/ missing — do not push"
```

## 5. Push Image

```bash
source dashboard-react/image-versions.env
$CONTAINER_CMD push $REPO_URL/aviation_dashboard:${AVIATION_DASHBOARD_TAG}
```

Push progress uses carriage returns (`\r`) for in-place updates. When piped or captured, output appears **invisible**. Do not assume a push is stuck — the aviation dashboard image (~150 MB) typically takes 2-4 minutes on first push and ~30 seconds on subsequent pushes with cached layers.

For visible progress, redirect stderr:
```bash
$CONTAINER_CMD push $REPO_URL/aviation_dashboard:${AVIATION_DASHBOARD_TAG} 2>push.log && tail -5 push.log
```

## 6. Verify Image Pushed

**Always run this after every push** — progress output can be misleading:

```bash
snow spcs image-repository list-images {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO -c <connection>
```

Expected: one image `aviation_dashboard` with tag matching `AVIATION_DASHBOARD_TAG` from `image-versions.env`.

## 7. Validate Consistency (Required Before Deploy)

Run the validator to ensure every YAML and doc references the tag pinned in `image-versions.env`:

```bash
.cortex/skills/aviation-dashboard/scripts/check_image_versions.sh
```

Exit 0 = safe to deploy. Exit 1 = a file is out of sync; fix before `ALTER SERVICE`.

## Release / Redeploy Procedure

1. Edit [image-versions.env](../dashboard-react/image-versions.env) — bump `AVIATION_DASHBOARD_TAG` (e.g. `v1.0.0` → `v1.0.1`).
2. Run `scripts/check_image_versions.sh` — must pass.
3. Rebuild and push the image with the new tag.
4. `ALTER SERVICE ... FROM SPECIFICATION` with the new tag (see SKILL.md "Update / Redeploy" section). SPCS pulls the new image because the digest changed.
5. Commit `image-versions.env` change so the tag history matches git history.

**Rollback:** set `AVIATION_DASHBOARD_TAG` back to the previous value (old image is still in the SPCS registry) and re-run `ALTER SERVICE` — instant rollback, no rebuild needed.

## Pre-Build Checklist

Before rebuilding, verify these version pins in `package.json` haven't drifted:
- `@luma.gl/*` must be `~9.2.6` (not `^9.2.x` — resolving to 9.3.x breaks the build)
- `@deck.gl/*` must be `~9.2.11` (not `^9.2.11` — resolving to 9.3.x pulls incompatible luma.gl)

## Image Inventory

| Image:Tag | Approx Size | Build | First Push |
|-----------|-------------|-------|------------|
| aviation_dashboard:v1.0.0 | ~150 MB | 2-3 min | 2-4 min |

Tag above must match `AVIATION_DASHBOARD_TAG` in [image-versions.env](../dashboard-react/image-versions.env). The validator enforces this.

## Common Errors

| Symptom | Cause | Fix |
|---------|-------|-----|
| esbuild crash / QEMU segfault | ARM Mac + `--platform linux/amd64` | Use ARM Mac flow (step 4 above) |
| Push appears stuck (no output) | Carriage return progress | Wait 2-4 min; verify with `list-images` |
| "unauthorized" on push | Registry auth expired/missing | Re-run `snow spcs image-registry login` |
| Podman "unable to retrieve auth token" | Wrong hostname in auth store | Use `--creds "0sessiontoken:$TOKEN"` |
| White page after deploy | `dist/` empty from swallowed build error | Verify `dist/index.html` exists before pushing |
| `npm ci` fails | Missing `package-lock.json` | Run `npm install --legacy-peer-deps` locally first to generate it |
| Vite build fails on luma.gl | Version pin drift | Verify `~9.2.6` pins in `package.json` |
| Service shows old UI after push | Using `:latest` (cached by SPCS) | Bump tag in `image-versions.env`, rebuild, `ALTER SERVICE` |
| `check_image_versions.sh` FAIL | File references stale tag | Update that file to match `image-versions.env` |
