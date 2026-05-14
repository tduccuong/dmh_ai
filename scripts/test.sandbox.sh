#!/usr/bin/env bash
# Sandbox-runtime test driver. Boots an ephemeral elixir runner +
# sister `dmh-ai-sandbox` container against a throwaway data dir,
# runs `mix test --only sandbox test/sandbox/`, tears everything
# down. Pass test ids to filter (e.g. `./scripts/test.sandbox.sh
# R02_*`); no args runs all R<NN> tests.
#
# See arch_wiki/dmh_ai/architecture.md §Testing → Runtime tier.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/code/backend"
RUNNER_IMAGE="${DMH_RUNNER_IMAGE:-dmh-ai-test-runner:latest}"

TMP="$(mktemp -d -t dmh_test.XXXXXX)"
SUFFIX="$(basename "$TMP" | tr -dc 'a-z0-9_' | head -c 16)"
SANDBOX="dmh_test_${SUFFIX}_sandbox"

mkdir -p "$TMP"/{db,user_assets,user_workspaces,system_logs,run/dmh-browser}
chmod 0755 "$TMP"

cleanup() {
  echo "[test.sandbox] cleanup"
  docker rm -f "$SANDBOX" >/dev/null 2>&1 || true
  # The test runner's chown sweep leaves files owned by uid 10000
  # under $TMP — host `rm` (running as `ct`) gets EACCES on those.
  # Delete via a throwaway alpine container running as root.
  docker run --rm -v "$TMP:/cleanup" alpine:3 sh -c "rm -rf /cleanup/*" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Build runner image on first run (cached afterwards).
if ! docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1; then
  echo "[test.sandbox] building runner image $RUNNER_IMAGE (one-time, ~3 min)"
  docker build -t "$RUNNER_IMAGE" -f "$BACKEND/test/sandbox/Dockerfile.runner" "$BACKEND"
fi

# Sandbox image must already exist (built by ./scripts/build.sh).
if ! docker image inspect dmh-ai-sandbox:latest >/dev/null 2>&1; then
  echo "ERROR: dmh-ai-sandbox:latest not found." >&2
  echo "  Run: ./scripts/build.sh --stage" >&2
  exit 1
fi

echo "[test.sandbox] starting $SANDBOX (data=$TMP)"
# `--cap-add NET_ADMIN` lets `/sandbox-start.sh` install the iptables
# LAN fence on container boot. Without this cap, the rules silently
# fail to load and R11_lan_fence_uid_split passes for the wrong
# reason (no fence at all). We do NOT override the Dockerfile CMD —
# the entrypoint sets up iptables, then execs `tail -f /dev/null`.
docker run -d --name "$SANDBOX" \
  --cap-add NET_ADMIN \
  -v "$TMP/user_workspaces:/data/user_workspaces" \
  -v "$TMP/user_assets:/data/user_assets" \
  -v "$TMP/run/dmh-browser:/var/run/dmh-browser" \
  dmh-ai-sandbox:latest >/dev/null

# Wait for the sandbox to be healthy AND the fence to be installed —
# start.sh runs synchronously before exec'ing into tail, so once
# `docker exec true` works, the iptables rules should already be
# loaded. Probe both conditions to surface fence-install failures
# loudly rather than letting tests run against a half-set-up sandbox.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$SANDBOX" sh -c "iptables -L OUTPUT -n 2>/dev/null | grep -q REJECT"; then
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "ERROR: sandbox iptables fence never loaded — NET_ADMIN cap or start.sh issue?" >&2
    docker logs "$SANDBOX" >&2 || true
    exit 1
  fi
  sleep 0.4
done

# Per-uid 0700 fence on user_assets is established by SandboxUser
# during the test; for the test container itself we mount RW (not
# `:ro` like production) so SandboxUser.write_keystore_file can
# actually exercise the keystore-write path. Production assets
# remain RO from the sandbox per dist/docker-compose.yml.

echo "[test.sandbox] running tests"
docker run --rm \
  -v "$BACKEND:/work" \
  -w /work \
  -v "$TMP:/data" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v dmh_test_build:/work/_build \
  -e DMHAI_TEST_SANDBOX_CONTAINER="$SANDBOX" \
  -e DMHAI_TEST_TMP_DIR=/data \
  -e MIX_ENV=test \
  -e MIX_DEPS_PATH=/deps_cache \
  "$RUNNER_IMAGE" \
  sh -c "mix test --only sandbox test/sandbox/ $*"
