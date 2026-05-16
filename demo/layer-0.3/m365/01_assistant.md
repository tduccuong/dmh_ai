# 01 — Microsoft 365 Assistant (Outlook Mail / Calendar / OneDrive)

First Microsoft 365 demo, second connector vertical overall: real
Caller → mock vendor MCP server → canned response → agent grounds
its reply in the M365 connector's output. Same shape as the
Google Workspace `01_assistant.md` but on the Microsoft 365
surface instead of Gmail / Calendar / Drive — proves the
connector framework generalises.

The runbook below validates that DMH-AI's M365 connector works
end-to-end on the live stage against deterministic fixtures.

## Who

- **Admin** (operator) flips one env-var on the stage host before
  install + reboot. Then ticks the capabilities in External
  Connectors. From that point every per-user authorize-then-chat
  exchange routes through the M365 mock without needing real
  Microsoft tenant credentials.
- **Employee** asks SME questions in chat. The agent fires
  `m365.mail.search` / `cal.find_free_slots` / `files.list`
  automatically; writes (`mail.send`, `cal.create_event`,
  `files.upload`) open a task first per the dispatcher's
  write-requires-task gate.

## Why

Many DACH SMEs run on Microsoft 365 (Outlook + Teams + OneDrive)
rather than Google Workspace. This demo proves the connector
framework treats them as equal first-class platforms — same
agent UX, same admin curation surface (the capability ticker),
same enforcement rules. SMEs that picked Microsoft don't have to
wait for "Google Workspace parity" — it's already done.

## Pre-requisites

- Running DMH-AI stage at `http://127.0.0.1:8080`.
- Admin + non-admin user in the same org.
- Either:
  - **Mock path (default for demos)** — no Microsoft Entra creds
    needed; the mock vendor MCP server stands in for Microsoft
    Graph. **This is what step 1 sets up.**
  - **Real-Microsoft path (production UAT)** — an Entra app
    registration with the 6 Graph delegated permissions; see
    `AZURE_SETUP.md` for the click-through.

## Steps

### 1. Rebuild + redeploy stage with the M365 mock subprocess on

The `DMH_AI_ENABLE_VENDOR_MOCKS=true` env var starts every
connector's mock vendor MCP server (today: Google Workspace at
`127.0.0.1:8086`, Microsoft 365 at `127.0.0.1:8088`). This is the
ONLY env var the operator sets — connector details are admin-set
via the FE in step 2.

```bash
export DMH_AI_ENABLE_VENDOR_MOCKS=true
./scripts/build.sh --stage
./dist/install.sh --stage
```

Verify the mock is up + reachable:

```bash
curl -s -o /dev/null -w "master=%{http_code}\n" http://127.0.0.1:8080/
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  http://127.0.0.1:8088/ | jq '.result.serverInfo'
```

Expected: `master=200` and `{"name":"dmh-ai-mock-vendor", "version":"0.1.0"}`.

### 2. Admin configures the M365 connector via External Connectors

Same FE workflow used for real Microsoft 365 — only difference
is that for the mock demo the admin overrides the pre-filled
MCP URL with the mock's address.

1. Log in as admin (`admin@dmhai.local`).
2. User-menu → **External Connectors** (or `/connectors`).
3. Click **Microsoft 365** in the sidebar.
4. **MCP URL** field is pre-filled with the in-process default
   (`http://127.0.0.1:8087/m365`). For the mock demo, **clear it
   and paste `http://127.0.0.1:8088/`** — the port the M365 mock
   subprocess from step 1 is listening on. (For real-Microsoft
   UAT, leave the default untouched.)
5. **Capabilities to expose** — leave all three ticked (Outlook
   Mail, Outlook Calendar, OneDrive Files).
6. **Enabled** — leave ticked.
7. (Client ID / Client Secret left empty — the mock has no OAuth
   handler, so credentials don't apply on the mock path.)
8. Click **Save**.
9. Click **Test connection** → expect ✅ "Reachable — 6 functions
   exposed by dmh-ai-mock-vendor."

Confirm via the DB:

```bash
docker exec dmh_ai-master /app/bin/dmh_ai rpc '
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  IO.inspect(query!(Repo,
    "SELECT slug, mcp_url, enabled FROM mcp_catalog WHERE slug=?",
    ["m365"]).rows, label: "mcp_catalog")
'
```

Expected: `mcp_catalog: [["m365", "http://127.0.0.1:8088/", 1]]`.

### 3. Bypass the OAuth flow (mock path only)

For the deterministic demo we skip Microsoft's OAuth dance —
the mock has no OAuth handler. Seed the `authorized_services` +
`user_credentials` rows directly via the master's IEx RPC.

```bash
USER_ID=$(docker exec dmh_ai-master /app/bin/dmh_ai rpc '
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  [[id]] = query!(Repo, "SELECT id FROM users WHERE email=?",
                  ["test@dmhai.local"]).rows
  IO.write(id)
')
echo "user_id=$USER_ID"

docker exec dmh_ai-master /app/bin/dmh_ai rpc "
  user_id = \"$USER_ID\"
  slug = \"m365\"
  mock_url = \"http://127.0.0.1:8088/\"

  :ok = DmhAi.MCP.Registry.authorize(user_id, slug, mock_url, mock_url, nil)
  :ok = DmhAi.Auth.Credentials.save(user_id, \"oauth:\" <> slug, \"oauth2\",
                                    %{\"access_token\" => \"stage-m365-token\"},
                                    account: \"\")
  :ok = DmhAi.Auth.Credentials.save(user_id, \"mcp:\" <> mock_url, \"oauth2_mcp\",
                                    %{\"access_token\" => \"stage-m365-bearer\"},
                                    account: \"\",
                                    expires_at: :os.system_time(:millisecond) + 3_600_000)
  IO.puts(\"authorized\")
"
```

Expected: `authorized`.

### 4. Chat as the employee (⚠ ASSISTANT MODE)

```bash
USER_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"test@dmhai.local","password":"<employee password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)

SESSION="demo-m365-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"M365 demo\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Welche ungelesenen Nachrichten habe ich heute in Outlook? Bitte ueber den Microsoft 365 Connector pruefen.\"}" \
  http://127.0.0.1:8080/agent/chat
```

### 5. Read the answer + verify the trace

```bash
sleep 30
curl -s -H "Authorization: Bearer $USER_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION" \
  | jq '.messages[-1].content'

curl -s -H "Authorization: Bearer $USER_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION/progress" \
  | jq '.progress[]? | {label, status}'
```

Expected — the reply cites BOTH sentinel addresses
(`anna.beispiel@dmh-m365-demo.example` AND
`stefan.beispiel@dmh-m365-demo.example`) AND both fixture
subjects (`Outlook Pilot — Onboarding Plan` AND
`Re: Q2 Reporting — Termin vorschlagen`). Progress trace shows
`CreateTask → ConnectMcp → M365.mail.search → final_text`.

Both senders are unique to the M365 fixture
(`Connectors.Mock.Fixtures.M365`). The agent could not have
produced either string without the mock's canned response
flowing through the real Caller path.

## Verifying (acceptance checklist)

- ✅ Step 1: `curl http://127.0.0.1:8088/` returns the mock's
  `initialize` response.
- ✅ Step 2: External Connectors page shows the M365 card with
  `MCP URL ✓` badge; Test connection succeeds.
- ✅ Step 3: RPC prints `authorized`. Confirm by querying
  `authorized_services` for the test user — one row,
  `alias=m365`, `server_url=http://127.0.0.1:8088/`.
- ✅ Step 5: Final reply mentions **both** sentinel emails AND
  **both** fixture subjects. If any is missing, the chain
  bypassed the connector — check `mode: "assistant"` actually
  landed on the session row.

## Demoing this to a customer (human-driven, browser-based)

Same engineer-assisted pattern as `../google_workspace/01_assistant.md`. The
operator pre-stages everything; the customer only sees the chat.

### Day-before staging

1. Run **Steps 1–3** of the runbook on the stage host. Confirm
   the External Connectors page shows M365 with the MCP URL
   saved + Test connection green, and the RPC prints
   `authorized`.
2. Open two browser tabs at `http://127.0.0.1:8080`:
   - **Tab A** — admin, already on `/connectors` from step 2.
     Useful for the "this is where I curated the capabilities"
     beat of the pitch.
   - **Tab B** — employee, session pre-created with
     `mode: "assistant"`.
3. Run the verification query yourself once (step 4's chat curl).
   Confirm both sentinel addresses appear.

### In the meeting (customer watches)

1. **Tab B.** Type into chat:
   > *"Welche ungelesenen Nachrichten habe ich heute in Outlook?
   > Bitte über den Microsoft 365 Connector prüfen."*
2. Wait ~20–30 seconds. The agent opens a task, fires
   `mail.search`, composes a reply listing both messages.
3. **Point out** to the customer:
   > *"`anna.beispiel@dmh-m365-demo.example` und
   > `stefan.beispiel@dmh-m365-demo.example` — diese Adressen
   > existieren nicht im Internet. Sie stammen direkt aus der
   > Microsoft-Graph-Antwort, die der Agent abgefragt hat. In
   > Produktion zieht er Ihre echten Mails."*

### The pitch in one paragraph

> *"Microsoft-Mitarbeiterinnen verwenden Outlook und Teams
> täglich. DMH-AI redet jetzt direkt mit der Microsoft-Graph-API,
> genau wie mit Google Workspace zuvor — Mails durchsuchen,
> Termine vorschlagen, Dateien ins OneDrive ablegen. Sie wählen
> einmal in der Admin-Oberfläche, welche dieser Fähigkeiten Ihre
> Organisation freigibt, und Ihre Mitarbeiterinnen klicken sich
> mit einem Klick durch das Microsoft-Login. Keine Tickets, keine
> Sonderbehandlung — derselbe Agent, ein zweites Schienensystem."*

## Switching to real Microsoft (production UAT)

For real-Microsoft testing, just turn the mock off and rebuild —
the in-process MCP REST translator is always on.

```bash
unset DMH_AI_ENABLE_VENDOR_MOCKS
./scripts/build.sh --stage && ./dist/install.sh --stage
```

Then on the running stage:

1. Admin opens `/connectors` → Microsoft 365 → tick the
   capabilities your org needs → paste Client ID + Client
   Secret (from Entra app registration) → MCP URL stays at the
   pre-filled in-process default (`http://127.0.0.1:8087/m365`) →
   **Save** → **Test connection**.
2. See `AZURE_SETUP.md` for the exact Microsoft Entra steps
   + redirect URI to register.

Then the employee walks through the **real OAuth flow** click-
driven from the FE: **My Services** → **Connect Microsoft 365** →
browser redirects to Microsoft's consent screen → approve →
returns to DMH-AI with "Connected as <email>". Step 3's RPC is
skipped — the OAuth callback writes the credentials via the
`connector_oauth` flow path.

Run the live-portal UAT script — six chat prompts (four reads,
two writes) — in `02_uat_real_portal.md`.

## Primitives exercised

Same set as `../google_workspace/01_assistant.md` — proves the framework, not just
one connector:

- `0.3 Tools.Dispatcher` — 4-rule chokepoint (permission,
  write-requires-task, idempotency-key, credentials).
- `0.3 Connectors.MCPAdapter` — base behaviour, manifest +
  remap_error + mcp_slug + credential_kind.
- `0.3 Connectors.MCPAdapter.Caller.do_real_invoke/5` — real
  bridge into `MCP.Client.call_tool/4`.
- `0.3 Connectors.MCPCatalogSeed` + `OAuthCatalogSeed` — boot-time
  vendor metadata seed for M365.
- `0.3 Connectors.Bootstrap.start_vendor_mocks_if_enabled/0` —
  per-connector mock vendor MCP boot via `mock_descriptor/0`.
- `0.3 Connectors.Mock.VendorMCPServer` — shared mock server,
  parameterised by the M365 fixture map.
- `0.3 Connectors.Mock.Fixtures.M365` — canned responses with
  sentinel identifiers (German fake personas).
- `0.3 Connectors.M365` — manifest with `# vendor: <endpoint>`
  line per function (closes I3 for M365).
- `0.3 Connectors.M365.MCPHandler` — FunctionSpec map + custom
  handlers for KQL search, getSchedule slot computation, and
  small-file PUT upload.
- `0.3 Connectors.Capabilities` — admin's enabled_capabilities
  drives the 3-layer enforcement (OAuth scope filter, tool
  catalog filter, dispatcher gate).
- `0.3 Tools.ConnectMcp.InProcess` — attach path that resolves
  the M365 connector by slug, reads the compile-time tools list
  from the handler, applies the capability filter.

## Known gaps

- **Real Microsoft Graph endpoint URL is `https://graph.microsoft.com/v1.0/me/...`** — the in-process MCP REST translator hits this directly; production deploys don't need to change anything besides the OAuth credentials.
- **`files.upload` is small-file PUT only (<4 MB)** — the MCPHandler doesn't yet implement Microsoft's resumable upload session (`createUploadSession`). Large file uploads return upstream errors; track as a future enhancement.
- **`getSchedule` returns 30-minute availability blocks** — the slot computation client-side honors `duration_min` but the source resolution is fixed. Good enough for SME scheduling; precise sub-30-minute boundaries need a richer client-side merge.
- **Single-tenant override is an RPC tweak** — for SMEs that picked Single-tenant in Entra, the FE doesn't yet expose a tenant-id field. The `AZURE_SETUP.md` documents the RPC to override; an admin form-field is a future polish.
