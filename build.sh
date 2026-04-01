#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="dmh-ai"
DIST_DIR="$SCRIPT_DIR/dist"

echo "Building Docker image..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR/code"

echo "Exporting image to dist/..."
mkdir -p "$DIST_DIR"
docker save "$IMAGE_NAME" -o "$DIST_DIR/dmh-ai.tar"

echo "Pulling and exporting SearXNG image..."
docker pull searxng/searxng
docker save searxng/searxng -o "$DIST_DIR/searxng.tar"

echo "Assembling deployment package..."
rm -f "$DIST_DIR/searxng-settings.yml"
cp "$SCRIPT_DIR/code/searxng-settings.yml" "$DIST_DIR/searxng-settings.yml"
cp "$SCRIPT_DIR/code/docker-compose.yml"   "$DIST_DIR/docker-compose.yml"
cp "$SCRIPT_DIR/code/run.sh"               "$DIST_DIR/run.sh"
chmod +x "$DIST_DIR/run.sh"
mkdir -p "$DIST_DIR/db"
mkdir -p "$DIST_DIR/user_assets"
mkdir -p "$DIST_DIR/system_logs"

echo "Done. Deployable artifact: dist/"
echo "  dmh-ai.tar             $(du -sh "$DIST_DIR/dmh-ai.tar" | cut -f1)"
echo "  searxng.tar            $(du -sh "$DIST_DIR/searxng.tar" | cut -f1)"
echo "  docker-compose.yml"
echo "  run.sh"
echo "  searxng-settings.yml"
