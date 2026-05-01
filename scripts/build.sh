#!/bin/bash
# build.sh  Build DMH-AI production distribution into dist/
#
# Usage:
#   ./scripts/build.sh              # build using Docker cache, export images
#   ./scripts/build.sh --no-cache   # force rebuild all layers
#   ./scripts/build.sh --stage      # build without exporting images (local staging)

set -e

NO_CACHE=false
STAGE=false
for arg in "$@"; do
  case "$arg" in
    --no-cache) NO_CACHE=true ;;
    --stage) STAGE=true ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$ROOT_DIR/dist"

echo "=== Building DMH-AI ==="
if $NO_CACHE; then echo "(--no-cache  Docker cache bypassed)"; fi
if $STAGE; then echo "(--stage  local install, no image export)"; fi
echo ""

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
if ! $STAGE; then mkdir -p "$DIST_DIR/images"; fi

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

#  Save images as tarballs 
if $STAGE; then
    echo "Skipping image export (--stage)"
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
      - ${DMHAI_HOME:-.}/system_logs:/data/system_logs
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
    network_mode: host
    restart: unless-stopped
    volumes:
      - ${DMHAI_HOME:-.}/user_assets:/data/user_assets
    # tail -f /dev/null is the image CMD; scripts arrive via docker exec.

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
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/db" "$INSTALL_DIR/user_assets" "$INSTALL_DIR/system_logs"
    rm -rf "$INSTALL_DIR/searxng-settings.yml"
    cp "$DIST/searxng-settings.yml" "$INSTALL_DIR/searxng-settings.yml"
    chown -R 1000:1000 "$INSTALL_DIR"

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
      - ${INSTALL_DIR}/system_logs:/data/system_logs
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
    network_mode: host
    restart: unless-stopped
    volumes:
      - ${INSTALL_DIR}/user_assets:/data/user_assets

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
    if ls "$DIST/images/"*.tar.gz 1>/dev/null 2>&1; then
        echo "Loading Docker images..."
        for img in "$DIST/images/"*.tar.gz; do
            echo "  $(basename "$img")..."
            docker load < "$img"
        done
        echo ""
    else
        echo "ERROR: no Docker images found in $DIST/images/."
        echo "  Re-run the build WITHOUT --stage to include images:"
        echo "    ./scripts/build.sh"
        exit 1
    fi

    #  Set up install directory
    # Pre-create bind-mount targets so docker compose doesn't auto-create
    # them as root — the container runs as UID 1000 and would otherwise
    # hit EACCES on first write to /data/db, /data/system_logs, etc.
    mkdir -p "$INSTALL_DIR/db" "$INSTALL_DIR/user_assets" "$INSTALL_DIR/system_logs"
    rm -rf "$INSTALL_DIR/searxng-settings.yml"
    cp "$DIST/searxng-settings.yml" "$INSTALL_DIR/searxng-settings.yml"
    chown -R 1000:1000 "$INSTALL_DIR"

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
