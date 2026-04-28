#!/bin/bash
# Build script for mocks - compiles all Go source files into executables

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BIN_DIR="$SCRIPT_DIR/bin"

echo "Building mocks..."

# Build bitrix24
echo "  → bitrix24"
go build -o "$BIN_DIR/bitrix24" "$SRC_DIR/bitrix24.go"

# Build wiki
echo "  → wiki"
go build -o "$BIN_DIR/wiki" "$SRC_DIR/wiki.go"

# Build mcp
echo "  → mcp"
go build -o "$BIN_DIR/mcp" "$SRC_DIR/mcp.go"

# Build mcp_api_key
echo "  → mcp_api_key"
go build -o "$BIN_DIR/mcp_api_key" "$SRC_DIR/mcp_api_key.go"

echo "Done. Binaries in $BIN_DIR/"
ls -la "$BIN_DIR/"