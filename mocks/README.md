# Mocks — Test Servers for DMH-AI

Collection of mock servers used for integration testing without external dependencies.

## Folder Layout

```
mocks/
├── src/              # Go source files
│   ├── bitrix24.go   # Bitrix24 OAuth2 mock
│   ├── wiki.go       # Wiki service mock
│   └── mcp.go        # MCP server mock
├── bin/              # Compiled binaries (gitignored)
│   ├── bitrix24
│   ├── wiki
│   └── mcp
├── build.sh          # Build all mocks
└── README.md         # This file
```

## Available Mocks

### 1. bitrix24 — Bitrix24 OAuth2 Mock

**Purpose:** Implements OAuth 2.1 authorization-code + refresh-token grants for testing Phase B without a real provider.

**Endpoints:**
- `GET /oauth/authorize` — Mints auth code (5-min TTL), 302s to redirect_uri
- `POST /oauth/token` — Handles authorization_code and refresh_token grants

**Hardcoded credentials:**
```
client_id     = app.test123
client_secret = test_secret_123
```

**Build:**
```bash
cd mocks
./build.sh
# or manually:
go build -o bin/bitrix24 src/bitrix24.go
```

**Run:**
```bash
./bin/bitrix24
# Prints: Server running on http://localhost:<PORT>
```

**Test:**
```bash
cd code/backend
mix test test/itgr_oauth_bitrix_mock.exs --only network
```

---

### 2. wiki — Wiki Service Mock

**Purpose:** Mock wiki service for testing document/wiki-related features.

**Build:**
```bash
go build -o bin/wiki src/wiki.go
```

**Run:**
```bash
./bin/wiki
```

---

### 3. mcp — MCP Server Mock

**Purpose:** Standard MCP (Model Context Protocol) server for testing MCP client integrations.

**Exposed Tools:**
- `list_dir` — List contents of a directory (path parameter)
- `read_file` — Read contents of a file (path parameter)

**Protocol:** JSON-RPC 2.0 over stdin/stdout

**Build:**
```bash
go build -o bin/mcp src/mcp.go
```

**Run:**
```bash
./bin/mcp
# Reads JSON-RPC requests from stdin, prints responses to stdout
```

**Test:**
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' | ./bin/mcp
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./bin/mcp
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_dir","arguments":{"path":"/tmp"}}}' | ./bin/mcp
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"/etc/hostname"}}}' | ./bin/mcp
```

---

### 4. mcp_api_key — API Key Authenticated MCP Server

**Purpose:** HTTP-transport MCP server requiring Bearer API key. Tests `connect_mcp(auth_method: "api_key")` flow end-to-end.

**Transport:** HTTP, single endpoint `POST /mcp` (streamable-HTTP transport, JSON-RPC 2.0)

**Listening:** Port via `--port <N>` flag, default 9091. Prints `MCP api_key mock running on http://localhost:<N>/mcp` on startup.

**Auth:**
- Valid key (hardcoded): `test-api-key-12345`
- Read from `Authorization: Bearer <key>` header
- Missing/wrong key → HTTP 401 with body `{"jsonrpc":"2.0","error":{"code":-32001,"message":"Authentication required"},"id":null}`
- Sets `WWW-Authenticate: Bearer realm="mcp_api_key"` header (signals api_key auth, not OAuth)
- No OAuth metadata endpoints (no `/.well-known/oauth-protected-resource` or `/.well-known/oauth-authorization-server`)

**MCP Methods:**
- `initialize` → `{protocolVersion: "2024-11-05", capabilities: {tools: {}}, serverInfo: {name: "mcp_api_key_mock", version: "0.1.0"}}`
- `tools/list` → 2 sample tools:
  - `echo` — Echo a message back (param: `message: string`)
  - `current_time` — Return current UTC time as RFC3339
- `tools/call` →
  - `echo` → `{content:[{type:"text",text:"echo: <message>"}]}`
  - `current_time` → `{content:[{type:"text",text:"<RFC3339 now>"}]}`
  - other → JSON-RPC error -32601 "Method not found"

**Build:**
```bash
go build -o bin/mcp_api_key src/mcp_api_key.go
```

**Run:**
```bash
./bin/mcp_api_key --port 9091
# MCP api_key mock running on http://localhost:9091/mcp
```

**Test:**
```bash
# 1. Unauth → 401
curl -s -X POST http://localhost:9091/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}'

# 2. Auth → success
curl -s -X POST http://localhost:9091/mcp \
  -H 'Authorization: Bearer test-api-key-12345' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}'

# 3. tools/list
curl -s -X POST http://localhost:9091/mcp \
  -H 'Authorization: Bearer test-api-key-12345' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 4. tools/call echo
curl -s -X POST http://localhost:9091/mcp \
  -H 'Authorization: Bearer test-api-key-12345' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}'

# 5. tools/call current_time
curl -s -X POST http://localhost:9091/mcp \
  -H 'Authorization: Bearer test-api-key-12345' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"current_time","arguments":{}}}'
```

---

## Build All Mocks

```bash
cd mocks
./build.sh
```

Or manually:
```bash
cd mocks
go build -o bin/bitrix24 src/bitrix24.go
go build -o bin/wiki src/wiki.go
go build -o bin/mcp src/mcp.go
```

## Requirements

- Go 1.16+ toolchain
- No third-party dependencies (standard library only)

## .gitignore

The `bin/` directory and compiled binaries are gitignored in `../.gitignore`:
```
mocks/bin
mocks/*.log
```
