# mock_mcp — Bitrix24-shaped OAuth2 mock for testing Phase B

Tiny Go server that implements the parts of the OAuth 2.1
authorization-code + refresh-token grants needed to exercise
DMH-AI's manual-OAuth path (#149) end-to-end without standing up a
real provider account. Drives the `:network`-tagged tests in
`code/backend/test/itgr_oauth_bitrix_mock.exs`.

## What it implements

Two endpoints:

| Endpoint | Behavior |
|---|---|
| `GET /oauth/authorize?client_id=…&redirect_uri=…&state=…` | Mints a 32-char authorization code (5-minute TTL, in-memory) and 302s to `<redirect_uri>?code=<code>&state=<state>`. No human approval — the redirect fires immediately. |
| `POST /oauth/token` (form-encoded) | Validates `client_id` / `client_secret` against a hardcoded pair (`app.test123` / `test_secret_123`), then handles `grant_type=authorization_code` (consumes the code, returns access + refresh tokens) or `grant_type=refresh_token` (returns rotated tokens). |

Bitrix-shaped token response fields (`client_endpoint`, `server_endpoint`, `domain`, `member_id`, `scope`, `status`) are populated alongside the standard `access_token` / `refresh_token` / `expires_in` so the mock matches the production token-response shape DMH-AI consumes.

The server listens on a random port (`net.Listen("tcp", ":0")`) and prints the chosen port on stdout. Tests parse this line; humans can copy/paste it for ad-hoc curl probing.

## Build

```bash
cd mock_mcp
go build -o server bitrix24.go
```

No third-party dependencies — standard library only. Any Go 1.16+ toolchain works.

## Run manually

```bash
./server
# Bitrix24 OAuth2 mock server running
# Endpoints:
#   - GET /oauth/authorize?client_id=...&redirect_uri=...&state=...
#   - POST /oauth/token
# Server running on http://localhost:37895
```

Then probe:

```bash
PORT=37895
curl -i "http://localhost:$PORT/oauth/authorize?client_id=app.test123&redirect_uri=http://localhost:8080/oauth/callback&state=xyz"
# → 302 Location: http://localhost:8080/oauth/callback?code=<32hex>&state=xyz

CODE=…  # paste from the redirect
curl -X POST "http://localhost:$PORT/oauth/token" \
  -d "grant_type=authorization_code&client_id=app.test123&client_secret=test_secret_123&code=$CODE"
# → JSON with access_token, refresh_token, …
```

## Run the test suite against it

The test spawns + tears down the mock automatically:

```bash
cd code/backend
mix test test/itgr_oauth_bitrix_mock.exs --only network
```

Default `mix test` skips it (the `@moduletag :network` opt-in mirrors the convention used by `itgr_mcp_huggingface.exs` and `itgr_tool_capability.exs`).

If the `server` binary is missing, the test flunks with a clear message — rebuild via `go build` above.

## Hardcoded client credentials

The mock accepts exactly one client:

```
client_id     = app.test123
client_secret = test_secret_123
```

These match the values in `itgr_oauth_bitrix_mock.exs`'s setup. To extend with more clients, edit the `clientSecrets` map at the top of `bitrix24.go` and rebuild.

## What it does NOT implement

- No MCP endpoint. The mock is purely an OAuth 2.1 AS — it never returns tools or handles JSON-RPC. Coverage of the MCP handshake side (initialize / tools/list / tools/call) lives in `itgr_open_mcp.exs` (stubbed Transport) and `itgr_mcp_huggingface.exs` (real HuggingFace).
- No `/.well-known/oauth-authorization-server`. The mock is for the **manual** OAuth path (Phase B). DMH-AI never queries discovery against it; the test feeds endpoints in via the form values directly.
- No revocation_endpoint. RFC 7009 revocation is covered offline in `itgr_delete_creds_cascade.exs` against a stubbed unrouteable endpoint.
- No PKCE enforcement on the AS side. The test verifies our **client** side emits the right `code_challenge` / `code_challenge_method=S256` query params; the mock doesn't validate them. Sufficient for the round-trip contract we're checking.
