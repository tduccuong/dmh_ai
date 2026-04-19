#!/bin/sh
# Grant appuser access to the Docker socket by matching the host's docker group GID.
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "")
if [ -n "$DOCKER_GID" ]; then
    addgroup -g "$DOCKER_GID" dockerhost 2>/dev/null || true
    adduser appuser dockerhost 2>/dev/null || true
fi
exec su-exec appuser /app/bin/dmhai start
