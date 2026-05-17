# Layer 0.3 — Typed connectors (live-portal UAT runbooks)

These runbooks are live-portal UAT scripts: chat prompts the
staff user runs against DMH-AI wired to **real vendor accounts**.
Each connector folder ships exactly two files — the admin's
one-time vendor-side setup (`*_SETUP.md`) and the staff user's
UAT script (`01_uat_real_portal.md`). The Calendly folder adds a
third (`02_uat_cross_connector.md`) — the cross-vendor demo
that chains HubSpot + Calendly in one chat turn.

Mock-driven scenarios are not in the demo path — vendor mocks
remain available for the integration test suite
(`test/itgr_p03_*.exs` + `test/flows/F<NN>_*.exs`), but
customer-facing demos run only against live accounts.

The framework rails (Dispatcher, MCPAdapter, Caller, catalog
seeders) carry every connector — slice-3's 10 remaining vendors
(Shopify / Salesforce / Slack / etc., tracked as `#359`-`#369`,
minus Calendly which already shipped) inherit the proven path
with only per-vendor manifest + UAT runbook. **Calendly** is the
first Case-A connector (DMH-AI hosts the MCP server because
Calendly has no first-party MCP) and the first connector to
ship a cross-vendor demo.

## Connectors

One subfolder per connector vertical. Each folder carries the
vendor-side setup walkthrough the admin needs once and the
live-portal UAT script the staff user runs.

### Google Workspace — [`google_workspace/`](google_workspace/)

| # | Runbook |
|---|---|
| 01 | [`google_workspace/01_uat_real_portal.md`](google_workspace/01_uat_real_portal.md) — 4 reads + 2 writes against the real Workspace account |

Admin setup: [`google_workspace/CLOUD_SETUP.md`](google_workspace/CLOUD_SETUP.md).

### Microsoft 365 — [`m365/`](m365/)

| # | Runbook |
|---|---|
| 01 | [`m365/01_uat_real_portal.md`](m365/01_uat_real_portal.md) — 4 reads + 2 writes against the real tenant |

Admin setup: [`m365/AZURE_SETUP.md`](m365/AZURE_SETUP.md).

### HubSpot — [`hubspot/`](hubspot/)

| # | Runbook |
|---|---|
| 01 | [`hubspot/01_uat_real_portal.md`](hubspot/01_uat_real_portal.md) — 3 reads + 2 writes against the real portal |

Admin setup: [`hubspot/HUBSPOT_APP_SETUP.md`](hubspot/HUBSPOT_APP_SETUP.md).

### Calendly — [`calendly/`](calendly/)

First Case-A connector (own MCP server). Also hosts the
cross-connector demo: HubSpot find → Calendly link → HubSpot
log + task in one chat turn.

| # | Runbook |
|---|---|
| 01 | [`calendly/01_uat_real_portal.md`](calendly/01_uat_real_portal.md) — 3 reads + 2 writes against the real Calendly account |
| 02 | [`calendly/02_uat_cross_connector.md`](calendly/02_uat_cross_connector.md) — **cross-vendor**: HubSpot `contact.find` → Calendly `event_type.list` + `single_use_link.create` → HubSpot `activity.log` + `task.create` |

Admin setup: [`calendly/CALENDLY_APP_SETUP.md`](calendly/CALENDLY_APP_SETUP.md).

## Common pre-requisites (every scenario in this folder)

- Running DMH-AI stage instance:
  ```bash
  ./scripts/build.sh --stage && ./dist/install.sh --stage
  ```
- Admin + staff user in the same org.
- For each connector the staff user will exercise:
  1. Admin walks the connector's `*_SETUP.md` once (Google
     Cloud / Entra / HubSpot Developer / Calendly Developer
     portal — vendor-side OAuth app).
  2. Admin opens **External Connectors** (`/connectors`) →
     pastes Client ID + Secret, ticks capabilities,
     **Save** → **Test connection** (green).
  3. Staff user clicks **My Services → Connect <vendor>** →
     real consent screen → callback → green badge on My
     Services.
- Chat session in **Assistant** mode (not Confidant).

## Where to look when something breaks

| Symptom | First place to look |
|---|---|
| `External Connectors → Test connection` fails | `mcp_catalog.mcp_url` row not yet saved. Open `/connectors` → vendor card → MCP URL field; if empty, paste the in-process default from the placeholder and **Save**. |
| Staff user's **My Services → Connect <vendor>** opens vendor consent but the chat tab never gets the toast | OAuth callback returned an error pre-callback (e.g. consent rejected, scope mismatch). Vendor's error page shows the cause; close that tab and re-try. Common: scope set in the OAuth app's portal doesn't match the capability ticks DMH-AI requests. |
| Chat reply says `missing_credentials` for `<slug>` even though My Services shows green | The OAuth flow completed but the credential row wasn't written. Check `user_credentials WHERE target = 'oauth:<slug>'`. Rare — usually fix is re-Connect. |
| Read returns 0 results but the vendor account has data | Either the capability scope set is wrong (vendor returned an empty list silently because the scope's too narrow), or the staff user's account in the vendor portal has no matching records. Read your prompt — *"find Brian"* needs a Brian to exist. |
| Write returns `:duplicate` / `:not_found` | Vendor-specific error envelope. The agent's reply surfaces the canonical class; check the vendor's UI for the real cause. |

## Cleanup

Each runbook has its own Cleanup section (delete the test
records the writes created). To wipe ALL connector state for a
staff user and start fresh:

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

Vendor-side: each connector's `*_SETUP.md` has a
**Decommissioning** section showing how to delete the OAuth
app from the vendor's developer portal.
