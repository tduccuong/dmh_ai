# MCP — multi-provider service integration

## Goal

Let DMH-AI users connect to **arbitrary** external services (Slack, Gmail, Bitrix24, internal APIs, anything) and have the model call them as tools, without DMH-AI maintaining per-provider integration code.

The strategy: **DMH-AI is an MCP client.** When the user wants to use a service, the harness connects to its MCP server; the server's tool catalog becomes additional tools the LLM can invoke. Authentication uses the MCP authorization framework (OAuth 2.1 + PRM/ASM discovery + Resource Indicators).

One tool — `connect_service(url)` — covers the entire ecosystem.

## Scoping model

Two tiers, separately persisted:

**User-tier (auth, persistent).** `authorized_services` carries one row per service the user has ever authorized: `(user_id, alias, canonical_resource, server_url, asm_json, server_tools_json, server_tools_cached_at, created_ts)`. Tokens live in `user_credentials` at `target="mcp:<canonical>"`; DCR client identifiers at `target="oauth_client:<auth-server>"`. Authorization survives across sessions, restarts, and deployments.

**Task-tier (catalog, ephemeral).** `task_services` is a junction table: `(task_id, user_id, alias, attached_ts)`. One row per attached service per active task. The per-turn tool catalog returned to the LLM is filtered to the services attached to the **current anchor task** — a session with no anchor task, or a task with no attached services, sees zero MCP tools.

Lifecycle:
- New session: no anchor task ⇒ MCP catalog is empty, regardless of how many services the user has authorized in the past.
- Task created: still empty until something attaches a service.
- `connect_service` runs successfully: authorizes (if needed) AND attaches the service to the current anchor task. Tools become live on the next chain turn.
- `complete_task` / `cancel_task`: every `task_services` row for that task drops. Next turn's catalog reverts to whatever's attached to whatever task is now active (often nothing).
- `pause_task`: attachments persist. Resume (`pickup_task`) reuses them without re-running `connect_service`.

Token-cost effect: the model sees only the tools its current task explicitly attached. A user with 5 authorized services across 100+ tools spends per-turn token budget only on the 1-2 services this task attached.

## What's in vs out of this spec

**In scope:**
- The MCP client (`Dmhai.MCP.Client`).
- Discovery + OAuth handshake (`Dmhai.Auth.Discovery` + `Dmhai.Auth.OAuth2`).
- Token storage (`Dmhai.Auth.Credentials`).
- The single `connect_service` tool.
- Per-task dynamic tool catalog.

**Out of scope:**
- Running DMH-AI itself as an MCP server.
- stdio transport (subprocess MCP servers). Streamable HTTP only.
- Dashboard UI for managing authorizations — chat-driven only.

## Module layout

```
lib/dmhai/
  auth/
    oauth2.ex        # generic OAuth 2.1 client, metadata-driven
    discovery.ex     # PRM (RFC 9728) + ASM (RFC 8414) fetcher
    credentials.ex   # token vault
  mcp/
    client.ex        # MCP protocol client: handshake, list_tools, call_tool
    transport.ex     # Streamable HTTP transport (Mcp-Session-Id threaded)
    registry.ex      # authorized_services + task_services + per-user tools cache
  tools/
    connect_service.ex   # the single user-facing tool
    request_input.ex
    save_creds.ex
    lookup_creds.ex
    delete_creds.ex
```

## The single tool

```
connect_service(url, alias?, auth_method?)
```

`url` identifies the service. `alias` is an optional friendly name (defaults to a host-derived slug). `auth_method` is `"auto"` (default, runs spec-compliant discovery) | `"api_key"` (static-header form) | `"oauth"` (manual OAuth-without-discovery form) | `"none"` (open MCP, no auth).

Police gates `connect_service` in `@gated_tools`: the model must establish an anchor task (`create_task` or `pickup_task`) before calling it. Tool execution attaches the service to that task on success.

Return values are one of:

| Status | Meaning | Payload |
|--------|---------|---------|
| `connected` | Authorized + attached. Tools live on the next turn. | `{tools: [...], alias}` |
| `needs_auth` | Discovery succeeded; OAuth dance pending. Chain ends; auth callback attaches on success. | `{auth_url, alias}` |
| `needs_setup` | Discovery failed or AS doesn't support DCR/CIMD. Chain ends; form submission attaches on success. | `{form, alias}` |

## Flow

```
connect_service(url, alias?, auth_method?)  with anchor_task_id from ctx
  │
  ├─ 0. Already-authorized check
  │     authorized_services row exists for (user_id, alias) AND
  │     credentials at target="mcp:<canonical>" are valid (or
  │     refresh succeeds) → rehandshake (initialize + tools/list,
  │     Mcp-Session-Id threaded), update cached server_tools_json,
  │     attach(task_id, alias), return `connected`.
  │
  ├─ 1. Discovery cascade  (auth_method = "auto")
  │     a. PRM at <host>/.well-known/oauth-protected-resource<path>
  │        (RFC 8615 well-known: insert `.well-known/<suffix>` between
  │        host and path; do NOT append).
  │     b. ASM at <auth-server>/.well-known/oauth-authorization-server.
  │     c. PRM 404 → fall through to api_key form (`needs_setup`).
  │     d. ASM 404 OR no S256 PKCE advertised → ditto.
  │
  ├─ 2. Client identification  (CIMD → DCR → manual)
  │     CIMD: publish metadata doc, use URL as client_id.
  │     DCR: POST our metadata to ASM.registration_endpoint, save the
  │          returned client_id+secret at target="oauth_client:<auth-server>"
  │          for reuse across sibling resources.
  │     Manual: needs_setup form for client_id+client_secret.
  │
  ├─ 3. Authorization-code flow (OAuth 2.1)
  │     Mint state token + PKCE verifier (S256). Persist
  │     pending_oauth_states with {user_id, session_id, anchor_task_id,
  │     alias, canonical_resource, server_url, asm_json, client_id,
  │     client_secret, pkce_verifier, redirect_uri, scopes, expires_at}.
  │     Build authorization URL (response_type=code, code_challenge,
  │     code_challenge_method=S256, state, scope, resource per RFC 8707).
  │     Return `needs_auth`.
  │
  ├─ 4. Callback at /oauth/callback?code=…&state=…
  │     Look up + consume pending state. Exchange code at
  │     ASM.token_endpoint (PKCE verifier, resource indicator,
  │     client credentials). Persist tokens at target="mcp:<canonical>".
  │     Upsert authorized_services with cached tools (initialize +
  │     tools/list, Mcp-Session-Id threaded). Attach(anchor_task_id, alias).
  │     Append synthetic `kind="service_connected"` user message.
  │     Send {:auto_resume_assistant, session_id} to UserAgent.
  │
  └─ 5. Per-turn catalog assembly
        Tools.Registry.all_definitions(user_id, anchor_task_id) =
          built-in tools (always)
          ++ for each task_services row matching anchor_task_id,
             splice authorized_services.server_tools_json with names
             namespaced as <alias>.<tool>.
        Persistent_term cache keyed {Dmhai.MCP.Registry, user_id}
          holds the per-user authorized catalog; per-turn filter by
          attached aliases is a small DB read.
```

## OAuth callback URL — single endpoint, state in query

```
GET /oauth/callback?code=…&state=…
```

The state token (single-use, TTL-bounded; default `oauthStateTtlSecs` = 600 s) ties the callback to a `pending_oauth_states` row carrying everything needed to resume — including `anchor_task_id` so the callback knows which task to attach the service to. Redirect URI registered with each AS is the same fixed path `<oauth_redirect_base_url>/oauth/callback`; per-deployment, not per-service.

For localhost dev: most providers (Google, Microsoft, GitHub, Slack, HuggingFace) accept `http://localhost:<port>/oauth/callback` as a registered redirect URI. Public hosting only matters for multi-user production.

## Storage

`user_credentials` carries three target-key conventions:

| Target key | Kind | Meaning |
|------------|------|---------|
| `mcp:<canonical>` | `oauth2_mcp` / `api_key_mcp` | Per-user access/refresh tokens or static API key for an MCP server. |
| `oauth_client:<auth-server>` | `oauth_client` | Per-user OAuth client_id/secret from DCR or manual entry. Reused across all MCP servers behind that AS. |
| (free-form) | (anything) | Ad-hoc credentials (API keys, passwords) the user explicitly stored. |

`authorized_services`:
```
user_id                TEXT NOT NULL
alias                  TEXT NOT NULL
canonical_resource     TEXT NOT NULL
server_url             TEXT NOT NULL
asm_json               TEXT
server_tools_json      TEXT          -- last-known tools/list result
server_tools_cached_at INTEGER
created_ts             INTEGER NOT NULL
PRIMARY KEY (user_id, alias)
```

`task_services`:
```
task_id     TEXT NOT NULL
user_id     TEXT NOT NULL
alias       TEXT NOT NULL
attached_ts INTEGER NOT NULL
PRIMARY KEY (task_id, alias)
```

`pending_oauth_states` (additions to spec-compliant flow):
```
state              TEXT PRIMARY KEY
user_id            TEXT NOT NULL
session_id         TEXT NOT NULL
anchor_task_id     TEXT NOT NULL    -- task attaching on callback
alias              TEXT NOT NULL
canonical_resource TEXT NOT NULL
server_url         TEXT NOT NULL
pkce_verifier      TEXT NOT NULL
client_id          TEXT NOT NULL
client_secret      TEXT
asm_json           TEXT NOT NULL
scopes             TEXT
redirect_uri       TEXT NOT NULL
created_at         INTEGER NOT NULL
expires_at         INTEGER NOT NULL
```

## MCP client transport

Streamable HTTP. The client:

- POSTs JSON-RPC messages to the server URL with `Accept: application/json, text/event-stream` (Streamable HTTP requires both).
- Captures `Mcp-Session-Id` from `initialize`'s response headers and echoes it on every subsequent request — spec-compliant servers reject sessionless calls with `-32600 Session ID required`.
- Carries `Authorization: Bearer <access_token>` (OAuth) or `<custom-header>: <key>` (API key) per the connection's auth descriptor.
- Each `call_tool` opens its own session: `initialize` → grab session id → `tools/call`. Two roundtrips per call; sessions are local to one logical operation, not shared across processes.
- 401 → one transparent OAuth refresh + retry. Still 401: returns `{:error, :unauthorized}`; caller flips status to `needs_auth` and the model re-prompts via `connect_service`.

The transport is a separable trait so adding stdio later is parallel work, not a rewrite.

## `Dmhai.MCP.Registry` API

User-tier (authorization) operations:
- `authorize(user_id, alias, canonical, server_url, asm)` — upsert `authorized_services` row.
- `set_authorized_tools(user_id, alias, tools)` — cache tools after a fresh handshake.
- `find_authorized(user_id, alias)` — read.
- `find_authorized_by_resource(user_id, canonical)` — read.

Task-tier (attachment) operations:
- `attach(task_id, user_id, alias)` — upsert `task_services` row.
- `detach_all_for_task(task_id)` — drop every row for that task. Called on `complete_task` / `cancel_task`.
- `attached_aliases(task_id)` — list aliases attached to a task.

Catalog assembly:
- `tools_for_task(user_id, task_id)` — the flat namespaced tool list returned to the LLM. Empty when `task_id` is nil or no rows attached.

Cache invalidation:
- `:persistent_term` keyed `{Dmhai.MCP.Registry, user_id}` holds the user's authorized service catalog (alias → tools). Invalidated on `authorize` and `set_authorized_tools`. Per-turn filter by attached aliases is a small DB query, not cached.

## Disconnection

- `delete_creds(target="mcp:<canonical>")` drops the credential row, calls the AS's `revocation_endpoint` if present (RFC 7009), drops the matching `authorized_services` row, and `detach_all_for_task` for any task currently holding the alias. Cache invalidated.
- A future `disconnect_service(alias)` tool can layer on the same primitives. The model can already chain `delete_creds` for the same effect.

## Prompt — §Connecting external services

System prompt teaches the model:

> When the current task needs tools from an external service the assistant doesn't have, call `connect_service(url, alias?)`. Tools attach to the current task and become available on your next turn. The tool returns either an authorization URL (relay it as a clickable link; chain ends; chain auto-resumes after authorization) or an inline form (relay via the form widget). Tools detach automatically when the task closes — re-call `connect_service` from the next task that needs them.
>
> If you don't know the URL, ask the user or `web_search` for the provider's MCP endpoint documentation. Don't invent URLs.

## Implementation phases

Phase A — **Spec-compliant MCP path.** Discovery + OAuth 2.1 + DCR/CIMD + MCP handshake (Mcp-Session-Id threaded). End-to-end against any RFC 9728 / 8414 / 8707-compliant MCP server. Smoke target: HuggingFace MCP at `https://huggingface.co/mcp`. Verified by `test/itgr_mcp_huggingface.exs` (run `mix test test/itgr_mcp_huggingface.exs --only network`); the test exercises PRM, ASM, Mcp-Session-Id threading, and canonical-resource shape against real HF.

Phase B — **Manual fallback.** `auth_method = "api_key" | "oauth" | "none"` paths return `needs_setup` forms; submission handler finalizes server-side and dispatches `auto_resume_assistant`. The `oauth` path synthesises an ASM map from the form values (auth + token endpoints, client_id/secret, scopes), saves the `oauth_client:<auth-server>` row so refresh-time reuse works, and feeds the same `Auth.OAuth2.init_flow/1` the `auto` path uses; the user is shown the auth URL inline and the OAuth callback completes the connection. Verified by `test/itgr_oauth_manual_setup.exs` (14 offline tests covering validation, ASM shape, oauth_client persistence, scopes/client_secret optionality, and the `complete_flow` round-trip contract).

Phase C — **Refresh, revoke, error polish.**
  * Proactive auto-refresh: `Auth.OAuth2.lookup_with_refresh/2` wraps `Credentials.lookup` and fires `refresh/2` when an `oauth2_mcp` row's `is_expired` is true. `MCP.Client.load_connection` uses it so the MCP call is made with a fresh token from the start, saving the 401-then-retry round-trip.
  * `delete_creds` cascade + RFC 7009 revocation: when `target` matches `mcp:<canonical>` the tool decodes `asm_json`, POSTs to `revocation_endpoint` if advertised (best-effort — transport errors / 4xx do not block local cleanup), drops the `authorized_services` row, and removes every `task_services` attachment for the alias. Other targets keep simple delete behavior.
  * `needs_auth` status flip: `authorized_services` carries `status TEXT NOT NULL DEFAULT 'authorized'` (values: `authorized | needs_auth`). When refresh fails (proactive path or reactive 401 path), `MCP.Registry.mark_needs_auth/2` flips it; `tools_for_task/2` filters the catalog so the LLM doesn't emit names it can no longer invoke; the §Authorized MCP services context block annotates `[needs re-auth]` rows pointing at `connect_service` for recovery; a successful re-`authorize/5` resets to `authorized`.
  * Verified by `test/itgr_mcp_needs_auth.exs` (10), `test/itgr_oauth_lookup_with_refresh.exs` (7), and `test/itgr_delete_creds_cascade.exs` (10).

Phase D — **Open MCP path.** When the auto cascade sees PRM `:not_found`, before falling to the api_key setup form, probe with an unauthenticated `initialize`: a 200 + `Mcp-Session-Id` response means the server is genuinely open (no Authorization header required). The cascade routes through the no-auth handshake (`Tools.ConnectService.no_auth_connect/4`) and returns `connected` with zero user friction. Open services persist a sentinel credential of kind `none_mcp` at `mcp:<canonical>` so subsequent `MCP.Client.load_connection` calls find a credential to route through; `MCP.Client.build_auth/3`'s `none_mcp` clause yields `%{type: "none"}` (the Resource Indicator stays for spec compliance, no auth header). `auth_method: "none"` (the model-explicit path from Phase B) shares the same helper, fixing the prior gap where it didn't persist a credential. Verified by `test/itgr_open_mcp.exs` (6 offline tests covering build_auth round-trip, credential persistence, gated/transport-error fallthrough, and re-attach to subsequent tasks).

Phase E — **Dashboard catalog UI.** Curated `code/catalog/mcp_services.json` (Slack, Gmail, Outlook, Notion, GitHub, Bitrix24, …); admin-overridable. New "Connections" tab listing authorized services, with click-to-(re)attach into the active task. Both UI and chat invoke the same `connect_service` backend.

Phase F — **stdio transport.** Subprocess MCP servers via `stdio://` URLs.
