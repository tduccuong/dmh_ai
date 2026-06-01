#!/bin/bash
# build.sh  Build DMH-AI production distribution into dist/
#
# Usage:
#   ./scripts/build.sh              # build using Docker cache, export images
#   ./scripts/build.sh --no-cache   # force rebuild all layers
#   ./scripts/build.sh --stage      # build without exporting images (local staging)
#   ./scripts/build.sh --no-export  # build without exporting tarballs;
#                                   # production install loads images from
#                                   # the local Docker registry instead.

set -e

NO_CACHE=false
STAGE=false
NO_EXPORT=false
for arg in "$@"; do
  case "$arg" in
    --no-cache)  NO_CACHE=true ;;
    --stage)     STAGE=true ;;
    --no-export) NO_EXPORT=true ;;
  esac
done

# --stage implies --no-export; the stage installer always reads from the
# local registry.
if $STAGE; then NO_EXPORT=true; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$ROOT_DIR/dist"

echo "=== Building DMH-AI ==="
if $NO_CACHE;  then echo "(--no-cache   Docker cache bypassed)"; fi
if $STAGE;     then echo "(--stage      local install, no image export)"; fi
if $NO_EXPORT && ! $STAGE; then echo "(--no-export  skip image export; install reads from local registry)"; fi
echo ""

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
if ! $NO_EXPORT; then mkdir -p "$DIST_DIR/images"; fi

#  Build server Docker image 
echo "Building server Docker image..."
BUILD_ARGS=""
if $NO_CACHE; then
  BUILD_ARGS="--no-cache"
fi

docker build $BUILD_ARGS \
  -t dmh-ai:latest \
  -f "$ROOT_DIR/code/Dockerfile" \
  "$ROOT_DIR/code"

echo "Building sandbox Docker image..."
docker build $BUILD_ARGS \
  -t dmh-ai-sandbox:latest \
  -f "$ROOT_DIR/code/sandbox/Dockerfile" \
  "$ROOT_DIR/code/sandbox"

echo "Pulling SearXNG image..."
docker pull searxng/searxng:latest

echo ""
echo "Docker images:"
docker images --format "  {{.Repository}}:{{.Tag}}  {{.Size}}" | grep -E "dmh-ai|dmh-ai-sandbox|searxng/searxng"

#  NIF smoke test
# Cross-build catastrophe-stop. The master image carries two
# architecture-sensitive NIFs that load at runtime — `vec0.so`
# (sqlite_vec, fetched precompiled from upstream releases via
# octo_fetch) and `sqlite3_nif.so` (exqlite, compiled in the
# elixir:alpine builder). Either being the wrong libc / arch for
# the runtime image surfaces only when the BEAM tries to load it,
# typically as a chain crash on first DB query — a confusing
# failure to debug post-deploy.
#
# Fast pre-flight: spawn an ephemeral container against the just-
# built image and verify each NIF's ldd output names the same
# loader (ld-musl-*-x86_64 / ld-linux-aarch64-... / etc.) the
# container's own libc uses. ~100ms, catches musl⇄glibc swaps and
# x86⇄ARM cross-build mistakes well before runtime.
echo ""
echo "Smoke test: NIFs link against the master image's libc..."
SMOKE_OUTPUT=$(docker run --rm --entrypoint sh dmh-ai:latest -c '
    set -e
    CONTAINER_LDSO=$(ls /lib/ld-musl-* /lib/ld-linux-* /lib64/ld-linux-* 2>/dev/null | head -1)
    if [ -z "$CONTAINER_LDSO" ]; then
        echo "FAIL: no ld.so found in container"
        exit 1
    fi
    CONTAINER_LDSO_BASE=$(basename "$CONTAINER_LDSO")
    echo "  container loader: $CONTAINER_LDSO_BASE"

    for nif in /app/lib/sqlite_vec-*/priv/*/vec0.so /app/lib/exqlite-*/priv/sqlite3_nif.so; do
        if [ ! -f "$nif" ]; then
            echo "FAIL: missing $nif"
            exit 1
        fi
        if ! ldd "$nif" 2>&1 | grep -q "$CONTAINER_LDSO_BASE"; then
            echo "FAIL: $nif does not link against $CONTAINER_LDSO_BASE"
            ldd "$nif" 2>&1 | head -5
            exit 1
        fi
        echo "  $(basename "$nif"): linked ${CONTAINER_LDSO_BASE}"
    done
    echo "ALL_OK"
' 2>&1) || true

if ! echo "$SMOKE_OUTPUT" | grep -q "ALL_OK"; then
    echo ""
    echo "ERROR: NIF smoke test failed:"
    echo "$SMOKE_OUTPUT" | sed "s/^/  /"
    echo ""
    echo "Likely causes:"
    echo "  - Cross-build mismatch (built on x86, deploying to ARM, or vice versa)."
    echo "    Fix: docker buildx build --platform linux/\${target_arch}"
    echo "  - sqlite_vec upstream missing a precompiled binary for this arch+libc."
    echo "    Fix: pin a specific sqlite_vec version, OR vendor vec0.so locally."
    exit 1
fi
echo "$SMOKE_OUTPUT" | grep -E "container loader|linked" | sed "s/^/  /"
echo "  NIFs OK."

#  Save images as tarballs
if $NO_EXPORT; then
    echo "Skipping image export ($($STAGE && echo --stage || echo --no-export))"
else
    echo ""
    echo "Saving images to dist/images/ (may take a minute)..."
    docker save dmh-ai:latest          | gzip > "$DIST_DIR/images/dmh-ai.tar.gz"
    echo "  dmh-ai.tar.gz           $(du -sh "$DIST_DIR/images/dmh-ai.tar.gz" | cut -f1)"
    docker save dmh-ai-sandbox:latest  | gzip > "$DIST_DIR/images/dmh-ai-sandbox.tar.gz"
    echo "  dmh-ai-sandbox.tar.gz  $(du -sh "$DIST_DIR/images/dmh-ai-sandbox.tar.gz" | cut -f1)"
    docker save searxng/searxng:latest | gzip > "$DIST_DIR/images/dmh-ai-searxng.tar.gz"
    echo "  dmh-ai-searxng.tar.gz  $(du -sh "$DIST_DIR/images/dmh-ai-searxng.tar.gz" | cut -f1)"
fi

#  Create docker-compose.yml 
echo "Creating docker-compose.yml..."
cat > "$DIST_DIR/docker-compose.yml" << 'COMPOSE'
services:
  master:
    image: dmh-ai:latest
    container_name: __CONTAINER_NAME__
    network_mode: host
    restart: unless-stopped
    volumes:
      - ${DMHAI_HOME:-.}/db:/data/db
      - ${DMHAI_HOME:-.}/user_assets:/data/user_assets
      - ${DMHAI_HOME:-.}/user_workspaces:/data/user_workspaces
      - ${DMHAI_HOME:-.}/system_logs:/data/system_logs
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      searxng:
        condition: service_healthy
      sandbox:
        condition: service_started
    environment:
      - DEPLOY_ENV=__DEPLOY_ENV__
      # HTTP/HTTPS bind interface. Default 127.0.0.1 keeps the BE
      # private — fine for nginx-fronted production AND for personal
      # localhost-only installs. Operators who want LAN access (the
      # README's "phone on same Wi-Fi" feature) export
      # `DMHAI_BIND_HOST=0.0.0.0` before `dmh_ai start`.
      - DMHAI_BIND_HOST=${DMHAI_BIND_HOST:-127.0.0.1}
      # Primitive 0.3 stage demos / UAT — process toggles + ports.
      # The in-process MCP REST translator boots unconditionally on
      # DMH_AI_REAL_MCP_PORT (default 8087) and hosts every
      # connector that ships an `mcp_handler_module/0` (Google
      # Workspace today). Vendor-hosted Case-B connectors don't
      # use it. The mock vendor MCP is the only opt-in subprocess:
      #   DMH_AI_ENABLE_VENDOR_MOCKS=true → boot the per-connector
      #     mock server(s) at 127.0.0.1:DMH_AI_GW_MOCK_PORT (etc.)
      #     for deterministic demos. Off in production.
      # Connector details (client_id / secret / mcp_url) are never
      # set here — admin pastes them into External Connectors.
      # See arch_wiki/dmh_ai/sme/layer-0.md §0.3.2.
      - DMH_AI_ENABLE_VENDOR_MOCKS=${DMH_AI_ENABLE_VENDOR_MOCKS:-false}
      - DMH_AI_GW_MOCK_PORT=${DMH_AI_GW_MOCK_PORT:-8086}
      - DMH_AI_REAL_MCP_PORT=${DMH_AI_REAL_MCP_PORT:-8087}

  sandbox:
    image: dmh-ai-sandbox:latest
    container_name: __SANDBOX_NAME__
    # Sandbox is OFF host networking — the iptables fence in
    # /sandbox-start.sh REJECTs RFC1918 outbound for non-admin UIDs.
    # Default bridge networking gives the container its own netns.
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    volumes:
      # Two-tree split per arch_wiki/dmh_ai/isolation.md.
      # user_assets is mounted read-only (uploads + _keystore live
      # here); user_workspaces is the only writable surface for
      # sandbox processes. Both mounts use the SAME container path as
      # the master side (/data/user_assets, /data/user_workspaces) so
      # a path string built on master is consumable inside the sandbox
      # without translation.
      - ${DMHAI_HOME:-.}/user_assets:/data/user_assets:ro
      - ${DMHAI_HOME:-.}/user_workspaces:/data/user_workspaces
    # /sandbox-start.sh sets sysctl + iptables, then `tail -f /dev/null`.
    # Scripts arrive via `docker exec -u dmh_ai-u<uid> -w
    # /data/user_workspaces/<email>/<session>/`.

  searxng:
    image: searxng/searxng:latest
    container_name: __SEARXNG_NAME__
    network_mode: host
    restart: unless-stopped
    environment:
      - GRANIAN_HOST=127.0.0.1
      - GRANIAN_PORT=8888
      - SEARXNG_BASE_URL=http://localhost:8080/
    volumes:
      - ${DMHAI_HOME:-.}/searxng-settings.yml:/etc/searxng/settings.yml:ro
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8888/healthz"]
      interval: 10s
      timeout: 3s
      start_period: 15s
COMPOSE

#  Create SearXNG config 
cp "$ROOT_DIR/deploy/searxng-settings.yml" "$DIST_DIR/searxng-settings.yml"

#  Create install.sh 
echo "Creating install.sh..."
cat > "$DIST_DIR/install.sh" << 'INSTALL'
#!/bin/bash
set -e

DIST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="production"
    INSTALL_DIR="/opt/dmh_ai"
# BE listen address. Mode-specific default — resolved after arg parsing:
#   production → 0.0.0.0 (host firewall is the expected boundary; the
#     reverse proxy may live on the same box OR on a separate LAN host
#     such as firegate_shield, both of which need the BE reachable off
#     loopback).
#   stage      → 127.0.0.1 (developer workstation; nothing exposed on
#     external NICs without explicit opt-in).
# Override either with `--bind-host=<ip>` to pin to a specific NIC.
BIND_HOST=""
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) MODE="stage"; shift ;;
        --bind-host=*) BIND_HOST="${1#*=}"; shift ;;
        --bind-host) BIND_HOST="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Apply mode-specific defaults if the operator didn't pass --bind-host.
if [ -z "$BIND_HOST" ]; then
    if [ "$MODE" = "stage" ]; then
        BIND_HOST="127.0.0.1"
    else
        BIND_HOST="0.0.0.0"
    fi
fi

#  Production mode: elevate to root 
if [ "$MODE" = "production" ] && [ "$(id -u)" -ne 0 ]; then
        echo "Elevating to root (production install needs /opt/dmh_ai + systemd)..."
    sudo "$0" "${ORIG_ARGS[@]}"
    exit $?
fi

if [ "$MODE" = "stage" ]; then
    #  Stage install 
    INSTALL_DIR="$HOME/.dmh_ai"
    CONTAINER_PREFIX="dmh_ai_stage"

    echo "=== DMH-AI Stage Install ==="
    echo "Install directory: $INSTALL_DIR"
    echo ""

    #  Prerequisites 
    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker is required but not installed."
        exit 1
    fi

    #  Images are already in registry from build.sh --stage 
    echo "Using images from local Docker registry (built by build.sh --stage)"

    #  Set up install directory
    # Pre-create all bind-mount targets so docker compose doesn't
    # auto-create them as root — the existing dirs would otherwise
    # work but the browser-daemon socket dir MUST exist before the
    # sandbox container starts (the daemon binds the socket on boot).
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/db" "$INSTALL_DIR/user_assets" "$INSTALL_DIR/user_workspaces" \
             "$INSTALL_DIR/system_logs"
    rm -rf "$INSTALL_DIR/searxng-settings.yml"
    cp "$DIST/searxng-settings.yml" "$INSTALL_DIR/searxng-settings.yml"
    # No chown -R: master runs as root post-#190 and doesn't need a
    # specific host UID. Per-user subdirs under user_workspaces/ are
    # owned by per-user UIDs (10001+) for the OS-level isolation
    # fence — clobbering them with `chown -R 1000:1000` on reinstall
    # would break that. See arch_wiki/dmh_ai/isolation.md.

    #  Generate docker-compose for stage
    cat > "$INSTALL_DIR/docker-compose.yml" << COMPOSE
services:
  master:
    image: dmh-ai:latest
    container_name: dmh_ai-master
    network_mode: host
    restart: unless-stopped
    volumes:
      - ${INSTALL_DIR}/db:/data/db
      - ${INSTALL_DIR}/user_assets:/data/user_assets
      - ${INSTALL_DIR}/user_workspaces:/data/user_workspaces
      - ${INSTALL_DIR}/system_logs:/data/system_logs
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      searxng:
        condition: service_healthy
      sandbox:
        condition: service_started
    environment:
      - DEPLOY_ENV=stage
      # Stage default: bind to loopback. The host's localhost:8080
      # reaches the BE; nothing is exposed on external NICs without
      # the operator opting in via env (DMHAI_BIND_HOST=0.0.0.0).
      - DMHAI_BIND_HOST=\${DMHAI_BIND_HOST:-127.0.0.1}
      # Primitive 0.3 — process toggles + ports. In-process MCP
      # REST translator boots unconditionally on DMH_AI_REAL_MCP_PORT
      # (default 8087). The mock vendor MCP is opt-in via
      # DMH_AI_ENABLE_VENDOR_MOCKS=true (binds to DMH_AI_GW_MOCK_PORT
      # for the GW mock). Connector details (client_id / secret /
      # mcp_url) are admin-set via External Connectors, never here.
      # See demo/layer-0.3/google_workspace/01_assistant.md.
      - DMH_AI_ENABLE_VENDOR_MOCKS=\${DMH_AI_ENABLE_VENDOR_MOCKS:-false}
      - DMH_AI_GW_MOCK_PORT=\${DMH_AI_GW_MOCK_PORT:-8086}
      - DMH_AI_REAL_MCP_PORT=\${DMH_AI_REAL_MCP_PORT:-8087}

  sandbox:
    image: dmh-ai-sandbox:latest
    container_name: dmh_ai-assistant-sandbox
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    volumes:
      - ${INSTALL_DIR}/user_assets:/data/user_assets:ro
      - ${INSTALL_DIR}/user_workspaces:/data/user_workspaces

  searxng:
    image: searxng/searxng:latest
    container_name: dmh_ai-searxng
    network_mode: host
    restart: unless-stopped
    environment:
      - GRANIAN_HOST=127.0.0.1
      - GRANIAN_PORT=8888
      - SEARXNG_BASE_URL=http://localhost:8080/
    volumes:
      - ${INSTALL_DIR}/searxng-settings.yml:/etc/searxng/settings.yml:ro
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8888/healthz"]
      interval: 10s
      timeout: 3s
      start_period: 15s
COMPOSE

    #  Tear down any prior DMH-AI stack cleanly.
    # Two stages, in order:
    #   1. `compose down --volumes` — if a prior install was launched
    #      via compose, this is the canonical way to tear it down: it
    #      removes the containers AND the anonymous volumes attached
    #      to them (SearXNG's image declares /etc/searxng and
    #      /var/cache/searxng as VOLUMEs, which would otherwise leak
    #      two anonymous vols per restart cycle).
    #   2. Defensive sweep — for the case where a prior install was
    #      torn down dirty and compose has lost track of the
    #      containers. `docker rm -fv` removes them and their anon
    #      vols too.
    # The 1-second settle before `up` is necessary because the master
    # container uses `network_mode: host` — Docker's network-namespace
    # teardown isn't synchronous with `rm -f` returning, and a
    # too-quick `up` afterwards racing with cleanup makes compose
    # destroy the freshly-created master container with no diagnostic
    # (just "No such container: <hash>"). One second is overkill but
    # imperceptible at install time.
    cd "$INSTALL_DIR"
    docker compose -p dmh_ai -f docker-compose.yml down --volumes --remove-orphans 2>/dev/null || true
    LEGACY=$(docker ps -aq --filter "name=^dmh_ai" | sort -u | tr -d ' ')
    if [ -n "$LEGACY" ]; then
        echo "Reaping legacy DMH-AI containers..."
        echo "$LEGACY" | xargs docker rm -fv >/dev/null
    fi
    sleep 1

    #  Start server — DMHAI_BIND_HOST forwarded into compose env so the
    # `${DMHAI_BIND_HOST:-127.0.0.1}` interpolation picks up a non-default
    # value when the operator passed `--bind-host=…`.
    DMHAI_BIND_HOST="$BIND_HOST" docker compose -p dmh_ai -f docker-compose.yml up -d --remove-orphans

    sleep 3

    #  Create local CLI wrapper
    CLI_DIR=""
    for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
        if [ -d "$d" ]; then
            CLI_DIR="$d"
            break
        fi
    done
    if [ -z "$CLI_DIR" ]; then
        CLI_DIR="$HOME/.local/bin"
        mkdir -p "$CLI_DIR"
    fi

    cat > "$CLI_DIR/dmh_ai" << 'WRAPPER'
#!/bin/bash
DMHAI_HOME="$HOME/.dmh_ai"
COMPOSE="docker compose -p dmh_ai -f $DMHAI_HOME/docker-compose.yml"

# Why `down --volumes` everywhere: SearXNG's upstream image declares
# /etc/searxng + /var/cache/searxng as VOLUMEs. Without --volumes,
# every `down` orphans two anonymous volumes; over ~hundreds of
# start/stop cycles this fills the disk with thousands of dead vols.
# --volumes only removes anonymous volumes attached to this project's
# containers — named volumes from other projects on the same host
# are untouched.

case "${1:-}" in
    start)   $COMPOSE up -d --remove-orphans ;;
    stop)    $COMPOSE down --volumes ;;
    restart) $COMPOSE down --volumes && $COMPOSE up -d --remove-orphans ;;
    logs)    $COMPOSE logs -f ;;
    status)  $COMPOSE ps ;;
    prune)
        # Belt-and-braces sweep. `stop` / `restart` already nuke this
        # cycle's anonymous volumes; `prune` cleans up historical
        # orphans from prior dirty teardowns. The label filter
        # restricts removal to volumes Docker auto-created from image
        # VOLUME directives — named volumes (test build caches, other
        # projects' explicit volumes) carry no `anonymous` label and
        # are left alone. Volumes attached to running containers are
        # skipped by `docker volume prune` automatically.
        echo "Pruning orphaned anonymous Docker volumes..."
        docker volume prune -f --filter "label=com.docker.volume.anonymous"
        STOPPED=$(docker ps -aq --filter "name=^dmh_ai" --filter "status=exited" --filter "status=created")
        if [ -n "$STOPPED" ]; then
            echo "Removing stopped DMH-AI containers..."
            echo "$STOPPED" | xargs docker rm -fv
        fi
        echo "Prune complete."
        ;;
    *)
        echo "Usage: dmh_ai {start|stop|restart|logs|status|prune}"
        exit 1
        ;;
esac
WRAPPER
    chmod +x "$CLI_DIR/dmh_ai"

    echo ""
    echo "Stage install complete: $INSTALL_DIR"
    echo "CLI installed: $CLI_DIR/dmh_ai"
    echo ""
    echo "Usage:"
    echo "  dmh_ai start|stop|restart|logs|status"
    echo "  dmh_ai prune    # sweep orphaned anonymous Docker volumes"
else
    #  Production install 
    echo "=== DMH-AI Installer ==="
    echo "Install directory: $INSTALL_DIR"
    echo ""

    #  Prerequisites 
    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker is required but not installed."
        exit 1
    fi
    if ! command -v systemctl &>/dev/null; then
        echo "ERROR: systemctl is required (systemd)."
        exit 1
    fi

    #  Load Docker images
    # Prefer tarballs in $DIST/images/. If absent (build was --no-export
    # or --stage), fall back to whatever's already loaded in the local
    # Docker daemon. This lets you build + install on the same host
    # without paying the save/load round-trip.
    if ls "$DIST/images/"*.tar.gz 1>/dev/null 2>&1; then
        echo "Loading Docker images..."
        for img in "$DIST/images/"*.tar.gz; do
            echo "  $(basename "$img")..."
            docker load < "$img"
        done
        echo ""
    else
        echo "No image tarballs in $DIST/images/ — checking local Docker registry..."
        MISSING=""
        for img in dmh-ai:latest dmh-ai-sandbox:latest searxng/searxng:latest; do
            if ! docker image inspect "$img" >/dev/null 2>&1; then
                MISSING="$MISSING $img"
            fi
        done
        if [ -n "$MISSING" ]; then
            echo "ERROR: required image(s) not in local registry:$MISSING"
            echo "  Re-run the build to populate them:"
            echo "    ./scripts/build.sh             # bundles tarballs"
            echo "    ./scripts/build.sh --no-export # skip tarballs, registry-only"
            exit 1
        fi
        echo "  All required images present locally."
        echo ""
    fi

    #  Set up install directory
    # Pre-create all bind-mount targets so docker compose doesn't
    # auto-create them as root.
    mkdir -p "$INSTALL_DIR/db" "$INSTALL_DIR/user_assets" "$INSTALL_DIR/user_workspaces" \
             "$INSTALL_DIR/system_logs"
    rm -rf "$INSTALL_DIR/searxng-settings.yml"
    cp "$DIST/searxng-settings.yml" "$INSTALL_DIR/searxng-settings.yml"
    # No chown -R: master runs as root post-#190 and doesn't need a
    # specific host UID. Per-user subdirs under user_workspaces/ are
    # owned by per-user UIDs (10001+) for the OS-level isolation
    # fence — `chown -R 1000:1000` on reinstall would silently
    # flatten that. See arch_wiki/dmh_ai/isolation.md.

    #  Create dmh_ai service user
    if ! getent passwd dmh_ai &>/dev/null; then
        echo "Creating system user: dmh_ai"
        useradd --system --user-group --no-create-home --shell /usr/sbin/nologin dmh_ai
    fi
    # Ensure dmh_ai is in docker group (idempotent)
    usermod -aG docker dmh_ai

    #  Configure docker-compose
    sed -i \
        -e "s/__CONTAINER_NAME__/dmh_ai-master/g" \
        -e "s/__SANDBOX_NAME__/dmh_ai-assistant-sandbox/g" \
        -e "s/__SEARXNG_NAME__/dmh_ai-searxng/g" \
        -e "s/__DEPLOY_ENV__/production/g" \
        "$DIST/docker-compose.yml"

    # Copy the configured docker-compose to install dir
    cp "$DIST/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"

    #  Write systemd service 
    cat > /etc/systemd/system/dmh_ai.service << EOF
[Unit]
Description=DMH-AI Server
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=dmh_ai
Group=dmh_ai
WorkingDirectory=$INSTALL_DIR
# BE listen address — set at install time via \`--bind-host=…\`. Keep
# the default \`127.0.0.1\` for same-box reverse-proxy setups (nginx
# locally, Cloudflare Tunnel); set to \`0.0.0.0\` (or a specific NIC
# IP) when the reverse proxy lives on a different host on the LAN.
Environment=DMHAI_BIND_HOST=$BIND_HOST
# --volumes on every teardown path is required: SearXNG's upstream
# image declares two VOLUMEs (/etc/searxng, /var/cache/searxng), and
# without --volumes each restart cycle orphans two anonymous volumes
# that compound on disk indefinitely. Same reason ExecReload does an
# explicit down-then-up instead of --force-recreate (which preserves
# anon vols and leaks just like a bare `down`).
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down --volumes
ExecReload=/bin/sh -c '/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down --volumes && /usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d --remove-orphans'

[Install]
WantedBy=multi-user.target
EOF

    #  Tear down any prior DMH-AI stack cleanly (single-instance
    # invariant) — same two-stage pattern as the stage path above:
    # compose down for compose-tracked containers + their anon vols,
    # then a defensive sweep for anything compose has lost track of,
    # then a 1-second settle for host-networking namespace teardown.
    docker compose -f "$INSTALL_DIR/docker-compose.yml" -p dmh_ai down --volumes --remove-orphans 2>/dev/null || true
    LEGACY=$(docker ps -aq --filter "name=^dmh_ai" | sort -u | tr -d ' ')
    if [ -n "$LEGACY" ]; then
        echo "Reaping legacy DMH-AI containers..."
        echo "$LEGACY" | xargs docker rm -fv >/dev/null
    fi
    sleep 1

    systemctl daemon-reload
    systemctl enable dmh_ai
    systemctl restart dmh_ai

    #  Symlink CLI 
    cat > /usr/local/bin/dmh_ai << 'CLI'
#!/bin/bash
case "${1:-}" in
    prune)
        # Sweep orphaned anonymous Docker volumes. Production normally
        # leaks none — systemd ExecStop / ExecReload both pass
        # --volumes — but if the host has ever been bounced uncleanly,
        # historical orphans accumulate. The filter scopes removal to
        # image-VOLUME-directive vols only (named volumes from other
        # projects are skipped).
        echo "Pruning orphaned anonymous Docker volumes..."
        docker volume prune -f --filter "label=com.docker.volume.anonymous"
        echo "Prune complete."
        ;;
    *)
        echo "DMH-AI running at http://localhost:8080"
        echo "Manage: sudo systemctl start|stop|restart|status dmh_ai"
        echo "Maintenance: sudo dmh_ai prune"
        ;;
esac
CLI
    chmod +x /usr/local/bin/dmh_ai

    echo ""
    echo "Installed to $INSTALL_DIR"
    echo "CLI symlinked: /usr/local/bin/dmh_ai"
    echo ""
    echo "Manage:"
    echo "  sudo systemctl start|stop|restart|status dmh_ai"
    echo "  sudo dmh_ai prune    # sweep orphaned anonymous volumes"
    echo ""
    echo "Connect:"
    echo "  http://localhost:8080"
fi
INSTALL
chmod +x "$DIST_DIR/install.sh"

#  Done 
echo ""
echo "=== Build Complete ==="
echo ""
echo "Distribution ready in: dist/"
echo ""
echo "Contents:"
find "$DIST_DIR" -type f | sort | while read f; do
    size=$(du -sh "$f" | cut -f1)
    printf "  %-45s %s\n" "${f#$DIST_DIR/}" "$size"
done
echo ""
echo "To install:"
echo "  Production: sudo ./dist/install.sh"
echo "  Stage:      ./dist/install.sh --stage"
echo ""
