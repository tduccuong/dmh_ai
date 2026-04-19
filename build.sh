#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="dmh-ai"
DIST_DIR="$SCRIPT_DIR/dist"
EXPORT=true
NO_CACHE=false

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --no-cache    Force Docker to rebuild all layers (bypass build cache)"
    echo "  --no-export   Skip exporting image tars to dist/ (faster local builds)"
    echo "  help          Show this help message"
    exit 0
}

for arg in "$@"; do
    case $arg in
        --no-export) EXPORT=false ;;
        --no-cache)  NO_CACHE=true ;;
        help)        usage ;;
    esac
done

BUILD_FLAGS=""
[ "$NO_CACHE" = true ] && BUILD_FLAGS="--no-cache"

echo "Building Docker images..."
docker build $BUILD_FLAGS -t "$IMAGE_NAME" "$SCRIPT_DIR/code"
docker build $BUILD_FLAGS -t "dmh-ai-sandbox" "$SCRIPT_DIR/code/sandbox"

mkdir -p "$DIST_DIR"

if [ "$EXPORT" = true ]; then
    echo "Exporting image to dist/..."
    docker save "$IMAGE_NAME" -o "$DIST_DIR/dmh-ai.tar"
    docker save "dmh-ai-sandbox" -o "$DIST_DIR/dmh-ai-sandbox.tar"

    echo "Pulling and exporting SearXNG image..."
    docker pull searxng/searxng
    docker tag searxng/searxng searxng/searxng:build-export
    docker save searxng/searxng:build-export -o "$DIST_DIR/searxng.tar"
    docker rmi searxng/searxng:build-export
else
    echo "Skipping image export (--no-export). Removing stale tars if present..."
    rm -f "$DIST_DIR/dmh-ai.tar" "$DIST_DIR/searxng.tar" "$DIST_DIR/dmh-ai-sandbox.tar"
fi

echo "Assembling deployment package..."
rm -f "$DIST_DIR/searxng-settings.yml"
cp "$SCRIPT_DIR/deploy/searxng-settings.yml" "$DIST_DIR/searxng-settings.yml"
cp "$SCRIPT_DIR/deploy/docker-compose.yml"   "$DIST_DIR/docker-compose.yml"
cp "$SCRIPT_DIR/deploy/run.sh"               "$DIST_DIR/run.sh"
chmod +x "$DIST_DIR/run.sh"
mkdir -p "$DIST_DIR/db"
mkdir -p "$DIST_DIR/user_assets"
mkdir -p "$DIST_DIR/system_logs"

echo "Done. Deployable artifact: dist/"
if [ "$EXPORT" = true ]; then
    echo "  dmh-ai.tar             $(du -sh "$DIST_DIR/dmh-ai.tar" | cut -f1)"
    echo "  searxng.tar            $(du -sh "$DIST_DIR/searxng.tar" | cut -f1)"
fi
echo "  docker-compose.yml"
echo "  run.sh"
echo "  searxng-settings.yml"
