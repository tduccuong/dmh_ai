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

## Connectors

One subfolder per connector vertical. Each folder carries that
connector's runbooks (numbered per-connector) + the vendor-side
setup walkthrough (`CLOUD_SETUP.md` / `AZURE_SETUP.md` / …) the
admin needs once before any user can connect.

### Google Workspace — [`google_workspace/`](google_workspace/)

| # | Runbook | Functions exercised |
|---|---|---|
| 01 | [`google_workspace/01_assistant.md`](google_workspace/01_assistant.md) | `gmail.search` (read, free chat) |
| 02 | [`google_workspace/02_scheduling.md`](google_workspace/02_scheduling.md) | `gcal.find_free_slots` (read) + `gcal.create_event` (write) |
| 03 | [`google_workspace/03_drive.md`](google_workspace/03_drive.md) | `drive.upload` (write) |

Vendor setup: [`google_workspace/CLOUD_SETUP.md`](google_workspace/CLOUD_SETUP.md).

### Microsoft 365 — [`m365/`](m365/)

| # | Runbook | Functions exercised |
|---|---|---|
| 01 | [`m365/01_assistant.md`](m365/01_assistant.md) | `mail.search` (read, free chat) |

Vendor setup: [`m365/AZURE_SETUP.md`](m365/AZURE_SETUP.md).

## Common pre-requisites (apply to every scenario in this folder)

- Running DMH-AI stage instance, rebuilt with the mock vendor MCP
  subprocess enabled:
  ```bash
  export DMH_AI_ENABLE_VENDOR_MOCKS=true
  ./scripts/build.sh --stage && ./dist/install.sh --stage
  ```
  `DMH_AI_ENABLE_VENDOR_MOCKS=true` makes
  `Connectors.Bootstrap.start_vendor_mocks_if_enabled/0` bring
  up a `Mock.VendorMCPServer` per connector that exposes
  `mock_descriptor/0`. Today that's just Google Workspace,
  bound to `127.0.0.1:8086`.
- Admin then opens **External Connectors** → **Google Workspace**
  in the browser. The **MCP URL** field is pre-filled with the
  in-process default (`http://127.0.0.1:8087/google_workspace`);
  for the mock demo, override it with `http://127.0.0.1:8086/`
  and **Save**. (For real-Google UAT the default stays put.) The
  catalog seeders never write the URL — the admin's FE Save is
  the only writer of `mcp_url`, `client_id`, `client_secret`.
- An admin + employee user in the same org (re-use demo-01
  accounts from layer 0.2).
- For demo 01 only: an IEx RPC into the master to seed
  `authorized_services` + `user_credentials` (bypassing real
  Google OAuth, since the mock has no OAuth handler). Demos 02
  and 03 reuse the same row.

## Production / real-Google path

Each scenario has a "Switching to real Google" appendix (today
only in `google_workspace/01_assistant.md`'s "Switching to real Google"
section). The mock is for deterministic demos; for production
UAT the operator sets:

- `DMH_AI_ENABLE_VENDOR_MOCKS=false` (or unset) — turn the mock
  subprocess off. The in-process REST translator is always on,
  no flag needed.
- Admin opens **External Connectors** (`/connectors`) → Google
  Workspace card → pastes `client_id` + `client_secret` from
  Google Cloud Console (see `google_workspace/CLOUD_SETUP.md`) → **Save**
  → **Test connection**. MCP URL stays at the pre-filled
  in-process default.

Sales staff then click-connects via **My Services** →
**Connect Google Workspace** → real OAuth dance → returns
authorized. Demo 01's Step 2 RPC is *skipped* — the OAuth
callback writes the credential rows via the `connector_oauth`
flow.

## Where to look when something breaks

| Symptom | First place to look |
|---|---|
| `curl http://127.0.0.1:8086/` returns connection refused | `DMH_AI_ENABLE_VENDOR_MOCKS=true` wasn't set when `dist/install.sh --stage` ran. Re-export and reinstall. |
| `mcp_catalog` row has empty `mcp_url` | Admin hasn't saved the URL via External Connectors yet. Open `/connectors` → Google Workspace → paste `http://127.0.0.1:8086/` → **Save**. The seeder only writes vendor metadata; the URL is FE-set. |
| Agent invokes `connect_mcp(url: "<canonical_resource>")` and fails | The context block's "already-authorized servers" section instructs the model to use `connect_mcp(slug: "<slug>")`. If you see `url: ...`, the system prompt and context engine are out of sync — file a bug. |
| Final reply doesn't mention a fixture sentinel | Either `mode: "assistant"` didn't land on the session row, OR the chain bypassed the connector. Check the progress trace for the connector function call. |
| `drive.upload` reply is generic ("uploaded successfully") with no file_id | The model's reply isn't surfacing write-function return ids by default. Phrase the prompt to ask for it explicitly (see demo 03's chat content). |

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
