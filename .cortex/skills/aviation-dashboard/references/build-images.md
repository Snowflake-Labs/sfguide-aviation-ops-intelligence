# Build and Push Aviation Dashboard Image

Build the Docker image for the React dashboard and push it to the Snowflake SPCS image repository. Supports both Docker and Podman, with a workaround for ARM Mac (Apple Silicon).

> **Working directory:** All commands below run from `.cortex/skills/aviation-dashboard/dashboard-react/`.

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
podman push --creds "0sessiontoken:$TOKEN" $REPO_URL/aviation_dashboard:latest
```

## 3. Get Repository URL

```bash
REPO_URL=$(snow spcs image-repository url {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO -c <connection>)
echo $REPO_URL
```

## 4. Build Image

### Standard Flow (Linux / Docker Desktop on amd64)

```bash
$CONTAINER_CMD build --rm --platform linux/amd64 \
  -f Dockerfile.runtime \
  -t $REPO_URL/aviation_dashboard:latest .
```

### ARM Mac Flow (Apple Silicon)

On ARM Macs, `esbuild` crashes with a QEMU segfault when running `npm run build` inside `--platform linux/amd64`. The workaround: build locally with native ARM, then create a container that only copies the pre-built artifacts.

**Step 1 — Build locally (native ARM, no QEMU):**
```bash
npm ci --legacy-peer-deps
npm run build
npm run build:server
```

**Step 2 — Swap `.dockerignore` to allow prebuilt `dist/` into context:**

> **NOTE:** Docker 29.x does NOT support `--ignorefile`. Swap the file manually instead.

```bash
cp .dockerignore .dockerignore.bak
cp .dockerignore.prebuilt .dockerignore
```

**Step 3 — Container build with prebuilt artifacts:**
```bash
$CONTAINER_CMD build --rm --platform linux/amd64 \
  -f Dockerfile.runtime \
  -t $REPO_URL/aviation_dashboard:latest .
```

**Step 4 — Restore `.dockerignore`:**
```bash
cp .dockerignore.bak .dockerignore && rm .dockerignore.bak
```

The swapped `.dockerignore.prebuilt` allows `dist/` and `dist-server/` into the build context. The `Dockerfile.runtime` conditional guard (`[ -d dist ] || npm run build`) skips the build when `dist/` already exists.

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
$CONTAINER_CMD push $REPO_URL/aviation_dashboard:latest
```

Push progress uses carriage returns (`\r`) for in-place updates. When piped or captured, output appears **invisible**. Do not assume a push is stuck — the aviation dashboard image (~150 MB) typically takes 2-4 minutes on first push and ~30 seconds on subsequent pushes with cached layers.

For visible progress, redirect stderr:
```bash
$CONTAINER_CMD push $REPO_URL/aviation_dashboard:latest 2>push.log && tail -5 push.log
```

## 6. Verify Image Pushed

**Always run this after every push** — progress output can be misleading:

```bash
snow spcs image-repository list-images {TARGET_DB}.PUBLIC.AVIATION_DASHBOARD_REPO -c <connection>
```

Expected: one image `aviation_dashboard` with tag `latest`.

## Pre-Build Checklist

Before rebuilding, verify these version pins in `package.json` haven't drifted:
- `@luma.gl/*` must be `~9.2.6` (not `^9.2.x` — resolving to 9.3.x breaks the build)
- `@deck.gl/*` must be `~9.2.11` (not `^9.2.11` — resolving to 9.3.x pulls incompatible luma.gl)

## Image Inventory

| Image | Tag | Approx Size | Build | First Push |
|-------|-----|-------------|-------|------------|
| aviation_dashboard | latest | ~150 MB | 2-3 min | 2-4 min |

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
