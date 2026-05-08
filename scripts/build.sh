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
      # Browser-daemon Unix socket. The sandbox container binds the
      # socket here; bind-mounting on the master side too lets the
      # host-side Elixir process connect directly via
      # :gen_tcp.connect({:local, "/data/run/dmh-browser/daemon.sock"})
      # without paying `docker exec` overhead per turn. See
      # arch_wiki/dmh_ai/architecture.md §Browser tools.
      - ${DMHAI_HOME:-.}/run/dmh-browser:/data/run/dmh-browser
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      searxng:
        condition: service_healthy
      sandbox:
        condition: service_started
    environment:
      - DEPLOY_ENV=__DEPLOY_ENV__

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
      # Browser-daemon socket directory. Daemon binds
      # /var/run/dmh-browser/daemon.sock at boot; same dir is bind-
      # mounted on the master side at /data/run/dmh-browser for
      # host-side Elixir IPC (see master volumes above).
      - ${DMHAI_HOME:-.}/run/dmh-browser:/var/run/dmh-browser
    # /sandbox-start.sh sets sysctl + iptables, spawns browser_daemon
    # under a supervisor loop, then `tail -f /dev/null`. Scripts
    # arrive via `docker exec -u dmh_ai-u<uid> -w /data/user_workspaces/<email>/<session>/`.

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
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) MODE="stage"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
             "$INSTALL_DIR/system_logs" "$INSTALL_DIR/run/dmh-browser"
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
      - ${INSTALL_DIR}/run/dmh-browser:/data/run/dmh-browser
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      searxng:
        condition: service_healthy
      sandbox:
        condition: service_started
    environment:
      - DEPLOY_ENV=stage

  sandbox:
    image: dmh-ai-sandbox:latest
    container_name: dmh_ai-assistant-sandbox
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    volumes:
      - ${INSTALL_DIR}/user_assets:/data/user_assets:ro
      - ${INSTALL_DIR}/user_workspaces:/data/user_workspaces
      - ${INSTALL_DIR}/run/dmh-browser:/var/run/dmh-browser

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

    #  Reap any prior DMH-AI containers
    echo "Reaping any prior DMH-AI containers..."
    LEGACY=$(
        docker ps -aq --filter "name=^dmh_ai"
    )
    LEGACY=$(echo "$LEGACY" | sort -u | tr -d ' ')
    if [ -n "$LEGACY" ]; then
        echo "$LEGACY" | xargs docker rm -f >/dev/null
    fi

    #  Start server
    cd "$INSTALL_DIR"
    docker compose -p dmh_ai -f docker-compose.yml up -d --remove-orphans

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

case "${1:-}" in
    start)   $COMPOSE up -d --remove-orphans ;;
    stop)    $COMPOSE down ;;
    restart) $COMPOSE down && $COMPOSE up -d --remove-orphans ;;
    logs)    $COMPOSE logs -f ;;
    status)  $COMPOSE ps ;;
    *)
        echo "Usage: dmh_ai {start|stop|restart|logs|status}"
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
    # Pre-create ALL bind-mount targets so docker compose doesn't
    # auto-create them as root. Critical ones beyond the data dirs:
    #   run/dmh-browser — daemon binds its Unix socket here on boot;
    #     dir must exist before sandbox container starts.
    mkdir -p "$INSTALL_DIR/db" "$INSTALL_DIR/user_assets" "$INSTALL_DIR/user_workspaces" \
             "$INSTALL_DIR/system_logs" "$INSTALL_DIR/run/dmh-browser"
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
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down
ExecReload=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up -d --force-recreate --remove-orphans

[Install]
WantedBy=multi-user.target
EOF

    #  Reap any prior DMH-AI containers (single-instance invariant) 
    echo "Reaping any prior DMH-AI containers..."
    LEGACY=$(
        docker ps -aq --filter "name=^dmh_ai"
    )
    LEGACY=$(echo "$LEGACY" | sort -u | tr -d ' ')
    if [ -n "$LEGACY" ]; then
        echo "$LEGACY" | xargs docker rm -f >/dev/null
    fi

    systemctl daemon-reload
    systemctl enable dmh_ai
    systemctl restart dmh_ai

    #  Symlink CLI 
    cat > /usr/local/bin/dmh_ai << 'CLI'
#!/bin/bash
echo "DMH-AI running at http://localhost:8080"
echo "Manage: sudo systemctl start|stop|restart|status dmh_ai"
CLI
    chmod +x /usr/local/bin/dmh_ai

    echo ""
    echo "Installed to $INSTALL_DIR"
    echo "CLI symlinked: /usr/local/bin/dmh_ai"
    echo ""
    echo "Manage:"
    echo "  sudo systemctl start|stop|restart|status dmh_ai"
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
