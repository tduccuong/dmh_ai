# Layer 0.3 — Typed connectors (demo scenarios)

These runbooks exercise Primitive 0.3 (the connector dispatcher,
manifest contract, `Caller.do_real_invoke/5` real transport,
oauth/mcp catalog seeders, and the mock vendor MCP server)
against three DACH SME stories. Each scenario is independently
demoable but **demo 01 must run first per session** to seed the
shared authorization state.

The vertical pilot is **Google Workspace** (Gmail · Calendar ·
Drive). The same rails (Dispatcher, MCPAdapter, Caller,
catalog seeders, Mock.VendorMCPServer) carry every future
connector — slice-3's 11 vendors (Shopify / Salesforce / Slack /
etc., tracked as `#359`-`#369`) inherit the proven path with
only per-vendor manifest + fixture work.

## Scenarios

Listed in coverage order — smallest verb surface first, each
subsequent scenario adds a new verb shape or composition.

| # | File | Verbs exercised | What it adds over the previous |
|---|---|---|---|
| 01 | [`01_gw_assistant.md`](01_gw_assistant.md) | `gmail.search` (read, free chat) | Real Caller → mock vendor MCP → response back. First proof I1/I2/I3 closed on stage. |
| 02 | [`02_gw_scheduling.md`](02_gw_scheduling.md) | `gcal.find_free_slots` (read) + `gcal.create_event` (write) | Composite read→task→write in one chain. Exercises the write-requires-task gate and idempotency-key injection. |
| 03 | [`03_gw_drive.md`](03_gw_drive.md) | `drive.upload` (write) | Write-only path against a different vendor surface. Confirms the connector framework is verb-class-agnostic (Gmail vs Calendar vs Drive). |

## Common pre-requisites (apply to every scenario in this folder)

- Running DMH-AI stage instance, rebuilt with vendor mocks on:
  ```bash
  export DMH_AI_ENABLE_VENDOR_MOCKS=true
  export DMH_AI_GW_MCP_URL=http://127.0.0.1:8086/
  ./scripts/build.sh --stage && ./dist/install.sh --stage
  ```
  - `DMH_AI_ENABLE_VENDOR_MOCKS=true` makes
    `Connectors.Bootstrap.start_vendor_mocks_if_enabled/0` bring
    up a `Mock.VendorMCPServer` per connector that exposes
    `mock_descriptor/0`. Today that's just Google Workspace.
  - `DMH_AI_GW_MCP_URL=http://127.0.0.1:8086/` makes
    `MCPCatalogSeed` write that URL into the `mcp_catalog` row
    at boot. The user's `authorized_services.server_url` will
    point at the mock when demo 01's Step 2 runs.
- An admin + employee user in the same org (re-use demo-01
  accounts from layer 0.2).
- For demo 01 only: an IEx RPC into the master to seed
  `authorized_services` + `user_credentials` (bypassing real
  Google OAuth, since the mock has no OAuth handler). Demos 02
  and 03 reuse the same row.

## Production / real-Google path

Each scenario has a "Switching to real Google" appendix (today
only in `01_gw_assistant.md`'s "Switching to real Google"
section). The mock is for deterministic demos; for production
UAT the operator sets:

- `DMH_AI_ENABLE_VENDOR_MOCKS=false` (or unset)
- `DMH_AI_GW_MCP_URL=https://<google-mcp-endpoint>/`
- `DMH_AI_GW_CLIENT_ID` / `DMH_AI_GW_CLIENT_SECRET` from a real
  Google Cloud OAuth client

Then the existing `connect_mcp` / `authorize_service` chat flow
handles the real OAuth dance against Google's consent screen.
Demo 01's Step 2 RPC is *skipped* in that path — the OAuth flow
writes the credential rows.

## Where to look when something breaks

| Symptom | First place to look |
|---|---|
| `curl http://127.0.0.1:8086/` returns connection refused | `DMH_AI_ENABLE_VENDOR_MOCKS=true` wasn't set when `dist/install.sh --stage` ran. Re-export and reinstall. |
| `mcp_catalog` row has empty `mcp_url` | `DMH_AI_GW_MCP_URL` wasn't set at install time. Re-export and reinstall — `MCPCatalogSeed.upsert!/1` reads env at boot and overwrites the row. |
| Agent invokes `connect_mcp(url: "<canonical_resource>")` and fails | The context block's "already-authorized servers" section instructs the model to use `connect_mcp(slug: "<slug>")`. If you see `url: ...`, the system prompt and context engine are out of sync — file a bug. |
| Final reply doesn't mention a fixture sentinel | Either `mode: "assistant"` didn't land on the session row, OR the chain bypassed the connector. Check the progress trace for the connector verb call. |
| `drive.upload` reply is generic ("uploaded successfully") with no file_id | The model's reply isn't surfacing write-verb return ids by default. Phrase the prompt to ask for it explicitly (see demo 03's chat content). |

## Cleanup

Each scenario has its own Cleanup section. To wipe ALL demo state
(credentials, sessions) and start fresh:

```bash
USER_ID=$(docker exec dmh_ai-master /app/bin/dmh_ai rpc '
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  [[id]] = query!(Repo, "SELECT id FROM users WHERE email=?",
                  ["test@dmhai.local"]).rows
  IO.write(id)
')

docker exec dmh_ai-master /app/bin/dmh_ai rpc "
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  query!(Repo, \"DELETE FROM user_credentials WHERE user_id=?\", [\"$USER_ID\"])
  query!(Repo, \"DELETE FROM authorized_services WHERE user_id=?\", [\"$USER_ID\"])
  IO.puts(\"cleaned\")
"
```
