#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Loading images..."
docker load -i "$SCRIPT_DIR/dmh-ai.tar"
docker load -i "$SCRIPT_DIR/searxng.tar"

echo "Stopping any existing containers..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" down 2>/dev/null || true
docker rm -f dmh-ai searxng 2>/dev/null || true

mkdir -p "$SCRIPT_DIR/user_assets"
mkdir -p "$SCRIPT_DIR/system_logs"

echo "Starting DMH-AI..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
echo "Running. Visit http://localhost:8080"
