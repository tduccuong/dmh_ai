#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
DMHAI_HOME="$HOME/.dmhai"
BIN_DIR="$HOME/.local/bin"

# ── Preflight ──────────────────────────────────────────────────────────────────
if [ ! -d "$DIST_DIR" ]; then
    echo "Error: dist/ not found. Run ./build.sh first." >&2
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "Error: docker not found in PATH." >&2
    exit 1
fi

# ── Install directory ──────────────────────────────────────────────────────────
mkdir -p "$DMHAI_HOME"

# ── Load docker images (only if tars are present) ─────────────────────────────
if [ -f "$DIST_DIR/dmh-ai.tar" ] && [ -f "$DIST_DIR/searxng.tar" ]; then
    echo "Loading docker images..."
    docker load -i "$DIST_DIR/dmh-ai.tar"
    docker load -i "$DIST_DIR/searxng.tar"
fi

# ── Copy config files (always overwrite — idempotent) ─────────────────────────
# Remove first in case prior install left files owned by a container user
rm -f "$DMHAI_HOME/docker-compose.yml" "$DMHAI_HOME/searxng-settings.yml"
cp "$DIST_DIR/docker-compose.yml"   "$DMHAI_HOME/docker-compose.yml"
cp "$DIST_DIR/searxng-settings.yml" "$DMHAI_HOME/searxng-settings.yml"

# ── Data directories: migrate per-file from dist only if file absent in dest ───
# Checks each individual file — not just whether the directory is non-empty —
# so a fresh empty-schema db in ~/.dmhai/db/ won't block migration of real data.
_migrate_dir() {
    local name="$1"
    local dst="$DMHAI_HOME/$name"
    local src="$DIST_DIR/$name"
    mkdir -p "$dst"
    [ -d "$src" ] || return 0
    for f in "$src"/*; do
        [ -e "$f" ] || continue          # glob miss (empty dir)
        local fname
        fname="$(basename "$f")"
        if [ ! -e "$dst/$fname" ]; then
            cp -r "$f" "$dst/$fname"
            echo "  Migrated $name/$fname"
        else
            echo "  $name/$fname already exists — skipping."
        fi
    done
    return 0
}
_migrate_dir db
_migrate_dir user_assets
_migrate_dir system_logs

# ── Write the dmhai command script ────────────────────────────────────────────
# Use an expanding heredoc so DMHAI_HOME is baked in — no readlink needed,
# works on both Linux and macOS.
cat > "$DMHAI_HOME/dmhai" << EOF
#!/bin/bash
DMHAI_HOME="$DMHAI_HOME"

if docker compose version &>/dev/null 2>&1; then
    DC_BIN="docker compose"
else
    DC_BIN="docker-compose"
fi

DC="\$DC_BIN -f \$DMHAI_HOME/docker-compose.yml -p dmhai"

_start() {
    echo "Stopping any existing containers..."
    \$DC down 2>/dev/null || true
    \$DC_BIN -f "\$DMHAI_HOME/docker-compose.yml" -p dist down 2>/dev/null || true
    mkdir -p "\$DMHAI_HOME/user_assets" "\$DMHAI_HOME/system_logs"
    echo "Starting DMH-AI..."
    \$DC up -d
    echo "Running."
    echo "  http://localhost:8080  — standard"
    echo "  https://localhost:8443 — HTTPS (accept cert warning once; required for voice input)"
}

_stop() {
    echo "Stopping DMH-AI..."
    \$DC down
    echo "Stopped."
}

_status() {
    \$DC ps
}

case "\${1:-}" in
    start)   _start ;;
    stop)    _stop ;;
    restart) _stop; _start ;;
    status)  _status ;;
    *)
        echo "Usage: dmhai {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF

chmod +x "$DMHAI_HOME/dmhai"

# ── Symlink into user bin ──────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
ln -sf "$DMHAI_HOME/dmhai" "$BIN_DIR/dmhai"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "Installed to $DMHAI_HOME"
echo "Symlinked:  $BIN_DIR/dmhai -> $DMHAI_HOME/dmhai"
echo ""

if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
    echo "Note: $BIN_DIR is not in your PATH."
    if [ "$(uname)" = "Darwin" ]; then
        echo "Add this to your ~/.zshrc (or ~/.bash_profile) and re-open your terminal:"
    else
        echo "Add this to your ~/.bashrc or ~/.zshrc and re-open your terminal:"
    fi
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

echo "Usage: dmhai {start|stop|restart|status}"
