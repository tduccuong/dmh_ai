# 01 — Google Workspace Assistant (Gmail / Calendar / Drive)

First Primitive 0.3 demo: real Caller → mock vendor MCP server →
canned response → agent grounds its reply in the connector's
output. Exercises the entire dispatcher → adapter → caller →
transport → vendor path with **fixture-deterministic results**.

The runbook below proves I1 / I2 / I3 closed for Google
Workspace on the live stage (2026-05-14): real Caller works,
oauth_catalog + mcp_catalog rows seeded at boot, manifest
re-verified against vendor docs (Gmail v1 / Calendar v3 /
Drive v3).

## Who

- **Admin** (operator) flips one env-var pair on the stage host
  before install + reboot. From then on, every per-user
  authorize-then-chat exchange routes through the mock without
  needing real Google Cloud credentials.
- **Employee** asks SME questions in chat. The agent fires
  `google_workspace.gmail.search` / `gcal.find_free_slots` /
  `drive.list` automatically; writes (`gmail.send`,
  `gcal.create_event`, `drive.upload`) open a task first per
  the dispatcher's write-requires-task gate.

## Why

SMEs already live inside Gmail / Calendar / Drive. The value of
DMH-AI isn't "another inbox" — it's an agent that, when asked
*"Was ist heute morgen reingekommen, was ist dringend?"*, looks
up the unread messages, ranks them, drafts a reply, and only
sends after the user confirms. This runbook is the first
end-to-end proof that the agent can talk to a vendor's MCP
surface through the dispatcher's 4-rule contract (permission,
write-requires-task, idempotency, credentials).

## Pre-requisites

- Running DMH-AI stage at `http://127.0.0.1:8080`. Demo assumes
  127.0.0.1.
- Admin + non-admin user in the same org (`admin@dmhai.local` and
  `test@dmhai.local` — re-use the demo-01 / 02 / 03 accounts).
- Either:
  - **Mock path (default for demos)** — no Google Cloud creds
    needed; the mock vendor MCP server stands in for the real
    Google MCP endpoint. **This is what steps 1–2 set up.**
  - **Real-Google path (production UAT)** — your own Google
    Cloud OAuth client_id / secret + the official Google
    Workspace MCP endpoint URL, all pasted into the External
    Connectors admin page. See `CLOUD_SETUP.md` for the
    Cloud Console walk-through.

## Steps

Verified live on stage 2026-05-14.

### 1. Rebuild + redeploy stage with the mock vendor subprocess on

The `DMH_AI_ENABLE_VENDOR_MOCKS=true` env var:

- Starts `DmhAi.Connectors.Mock.VendorMCPServer` on
  `127.0.0.1:8086` (Plug app inside the master container).
- The `Connectors.Bootstrap` post-start hook in `Application.start`
  reads the connector's `mock_descriptor/0` and brings up one
  mock per connector that ships fixtures (today: Google
  Workspace).

This is the ONLY env var the operator sets — it's a
process-control toggle (whether the mock subprocess boots),
not connector data. The MCP URL the admin types into the FE
in step 2 below points at this mock.

```bash
export DMH_AI_ENABLE_VENDOR_MOCKS=true
./scripts/build.sh --stage
./dist/install.sh --stage
```

Verify mock is up + reachable from inside the master:

```bash
# Master should be 200, mock should JSON-RPC-respond.
curl -s -o /dev/null -w "master=%{http_code}\n" http://127.0.0.1:8080/
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  http://127.0.0.1:8086/ | jq '.result.serverInfo'
```

Expected: `master=200` and `{"name":"dmh-ai-mock-vendor", "version":"0.1.0"}`.

### 2. Admin configures the GW connector via External Connectors

Same FE workflow used for real Google — only difference is
that for the mock demo the admin overrides the pre-filled MCP
URL with the mock's address.

1. Log in as the admin (`admin@dmhai.local`).
2. Click the user-menu icon → **External Connectors** (or
   navigate to `/connectors`).
3. Click **Google Workspace** in the left sidebar.
4. **MCP URL** field is pre-filled with the in-process default
   (`http://127.0.0.1:8087/google_workspace`). For the mock
   demo, **clear it and paste `http://127.0.0.1:8086/`** — the
   port the `Mock.VendorMCPServer` subprocess from step 1 is
   listening on. (For real-Google UAT, leave the default
   untouched.)
5. **Enabled** → leave ticked
6. (Client ID / Client Secret left empty — the mock has no
   OAuth handler, so credentials don't apply on the mock path.)
7. Click **Save**.
8. Click **Test connection** → expect ✅ "Reachable — 6
   functions exposed by dmh-ai-mock-vendor."

Confirm via the DB:

```bash
docker exec dmh_ai-master /app/bin/dmh_ai rpc '
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  IO.inspect(query!(Repo,
    "SELECT slug, mcp_url, enabled FROM mcp_catalog WHERE slug=?",
    ["google_workspace"]).rows, label: "mcp_catalog")
'
```

Expected: `mcp_catalog: [["google_workspace", "http://127.0.0.1:8086/", 1]]`.

### 3. Bypass the OAuth flow (mock path only)

For the deterministic demo we skip the real Google OAuth dance
— the mock vendor MCP server doesn't run an OAuth handler.
Instead, seed the `authorized_services` + `user_credentials`
rows directly via the master's IEx RPC so the agent's normal
chat path finds the credential.

```bash
# Pull the test user's id once.
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
  slug = \"google_workspace\"
  # Canonical resource = the MCP server URL (per MCP spec convention).
  # The same value is the bearer-credential target key, so the auth
  # row's user_credentials.target = 'mcp:http://127.0.0.1:8086/'.
  mock_url = \"http://127.0.0.1:8086/\"

  :ok = DmhAi.MCP.Registry.authorize(user_id, slug, mock_url, mock_url, nil)
  :ok = DmhAi.Auth.Credentials.save(user_id, \"oauth:\" <> slug, \"oauth2\",
                                    %{\"access_token\" => \"stage-precheck-token\"},
                                    account: \"\")
  :ok = DmhAi.Auth.Credentials.save(user_id, \"mcp:\" <> mock_url, \"oauth2_mcp\",
                                    %{\"access_token\" => \"stage-mcp-bearer\"},
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

SESSION="demo-gw-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"GW demo\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Welche ungelesenen E-Mails habe ich heute? Bitte ueber den Google Workspace Connector abrufen.\"}" \
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

Live run (2026-05-14) produced:

**Final reply:**
> Sie haben heute zwei ungelesene E-Mails:
>
> 1. **Lieferanten-Update Q2** von
>    nina.beispiel@dmh-demo.example (8:12 Uhr)
> 2. **Re: Vertragsentwurf** von
>    tobias.beispiel@dmh-demo.example (7:48 Uhr)

**Progress trace:**
- `CreateTask → Ungelesene E-Mails abrufen` (done)
- `ConnectMcp → google_workspace` (done)
- `GoogleWorkspace.gmail.search` (done)
- `final_text`

Both senders (`nina.beispiel@dmh-demo.example` and
`tobias.beispiel@dmh-demo.example`) are **unique to the mock
fixture** (`Connectors.Mock.Fixtures.GoogleWorkspace`). The
agent could not have produced either string without the mock's
canned response flowing through the real Caller path.

## Verifying (acceptance checklist)

- ✅ Step 1: `curl http://127.0.0.1:8086/` returns the mock's
  `initialize` response with `name=dmh-ai-mock-vendor`.
- ✅ Step 1: `mcp_catalog` row for `google_workspace` has
  `mcp_url=http://127.0.0.1:8086/` and `enabled=1`.
- ✅ Step 2: External Connectors page shows the GW card with
  `MCP URL ✓` badge. Test connection succeeds.
- ✅ Step 3: RPC prints `authorized`. Confirm by querying
  `authorized_services` for the test user — one row,
  `alias=google_workspace`, `server_url=http://127.0.0.1:8086/`.
- ✅ Step 5: Final reply mentions **both** sentinel emails
  (`nina.beispiel@dmh-demo.example` AND
  `tobias.beispiel@dmh-demo.example`) AND **both** fixture
  subjects (`Lieferanten-Update Q2` AND `Re: Vertragsentwurf`).
  If any is missing, the chain bypassed the connector — check
  `mode: "assistant"` actually landed on the session row.

## Demoing this to a customer (human-driven, browser-based)

Same engineer-assisted pattern as the 0.2 runbooks. The
operator pre-stages everything; the customer only sees the
chat.

### Demoability today — the friction you can't avoid

- **Step 1 — process-control env var + rebuild** is a one-time
  setup per stage host (`DMH_AI_ENABLE_VENDOR_MOCKS=true`). Do
  this before any customer meeting.
- **Step 2 — FE admin paste of the mock URL.** Identical
  workflow to real Google — same External Connectors page, same
  Save button. Only the URL value differs.
- **Step 3 — manual credential seed via RPC.** The real
  customer demo would walk through Google's OAuth (a popup,
  consent screen). For the *mock* path the operator skips OAuth
  with the IEx snippet above. The friction here is "the
  customer sees you run `docker exec rpc`" — frame it as the
  demo's deterministic shortcut, not a production step.
- **No citation chip in the chat reply.** Same as the 0.2 demos
  — point out the sentinel emails / subjects manually.
- **`mode: "assistant"` flag** — same as every other demo.
- **The mock fixture is canned.** Customers will ask "but it
  only shows two emails?" The answer is *"those are the two
  emails we seeded for this demo; production reads your real
  inbox."*

### Day-before staging (you, with shell access)

1. Run **Steps 1–3** of the runbook on the stage host. Confirm
   the External Connectors page shows GW with the MCP URL saved
   and `Test connection` succeeds, and the RPC prints
   `authorized`.
2. Open two browser tabs at `http://127.0.0.1:8080`:
   - **Tab A** — `admin@dmhai.local`, already on `/connectors`
     from step 2 of the runbook. Useful for the "this is where I
     configured it" beat of the customer pitch — they see the
     Google Workspace card with green badges (MCP URL ✓,
     Enabled).
   - **Tab B** — `test@dmhai.local`, session pre-created with
     `mode: "assistant"`.
3. Run the verification query yourself once (Step 4's chat
   curl). Confirm both sentinel emails appear in the reply.

### In the meeting (customer watches)

1. **Tab B.** Type into chat:
   > *"Welche ungelesenen E-Mails habe ich heute? Bitte über
   > den Google Workspace Connector abrufen."*
2. Wait ~20–30 seconds. The agent opens a task, fires
   `gmail.search`, and composes a reply listing both messages.
3. **Point out** to the customer:
   > *"`nina.beispiel@dmh-demo.example` und
   > `tobias.beispiel@dmh-demo.example` — diese Adressen
   > existieren nicht im Internet. Sie stammen direkt aus der
   > Google-MCP-Antwort, die der Agent abgefragt hat. In
   > Produktion zieht er Ihre echten Mails."*

### The pitch in one paragraph

> *"Ihre Mitarbeiterinnen verbringen jeden Morgen 30 Minuten in
> ihrem Postfach. Mit DMH-AI fragen sie im Chat, der Agent
> öffnet Gmail im Hintergrund, fasst die Inbox zusammen und
> entwirft Antworten — Sie genehmigen mit einem Klick. Der
> gleiche Mechanismus funktioniert für Kalender (Slots finden)
> und Drive (Dateien ablegen) — alles über die offiziellen
> Google-Schnittstellen, ohne zusätzliche SaaS-Anbindung."*

### Reset between demos

The mock keeps running until the stage container restarts. To
re-run a fresh demo cycle:

- Same Tab B can keep going; or open a fresh session.
- If you want to reset credentials: `dmh_ai rpc` to DELETE the
  user_credentials rows, then re-seed via Step 3.

## Switching to real Google (production UAT)

For real-Google testing, just turn the mock off and rebuild —
the in-process MCP REST translator is always on. Everything
else is the admin pasting into the FE.

```bash
unset DMH_AI_ENABLE_VENDOR_MOCKS   # or export ...=false
./scripts/build.sh --stage && ./dist/install.sh --stage
```

Then on the running stage:

1. Admin opens `/connectors` → Google Workspace → pastes
   Client ID + Client Secret (from Google Cloud Console). MCP
   URL is already pre-filled with the in-process default
   (`http://127.0.0.1:8087/google_workspace`) — leave it as-is
   for production. → **Save** → **Test connection**.
2. See `CLOUD_SETUP.md` for the exact Google Cloud
   Console steps + redirect URI to register.

Then the employee walks through the **real OAuth flow** click-
driven from the FE: **My Services** → **Connect Google Workspace**
→ browser redirects to Google's consent screen → approve →
returns to DMH-AI with "Connected as <email>". Step 3's RPC is
skipped — the OAuth callback writes the credentials via the
`connector_oauth` flow path.

Run the live-portal UAT script — six chat prompts (four reads,
two writes) — in `02_uat_real_portal.md`.

## Cleanup

To remove the demo credentials (e.g. between customer demos):

```bash
docker exec dmh_ai-master /app/bin/dmh_ai rpc "
  user_id = \"$USER_ID\"
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  query!(Repo, \"DELETE FROM user_credentials WHERE user_id=?\", [user_id])
  query!(Repo, \"DELETE FROM authorized_services WHERE user_id=?\", [user_id])
  IO.puts(\"cleaned\")
"
```

To turn vendor mocks off and revert to a clean production-ish
boot:

```bash
unset DMH_AI_ENABLE_VENDOR_MOCKS
./dist/install.sh --stage   # re-deploys without mocks
```

## Primitives exercised

- `0.3 Tools.Dispatcher` — 4-rule chokepoint (permission,
  write-requires-task, idempotency-key, credentials).
- `0.3 Connectors.MCPAdapter` — base behaviour, manifest +
  remap_error + mcp_slug callbacks.
- `0.3 Connectors.MCPAdapter.Caller.do_real_invoke/5` — real
  bridge into `MCP.Client.call_tool/4` (closes I1).
- `0.3 Connectors.OAuthCatalogSeed` — boot-time oauth_catalog
  upsert (closes I2 generically).
- `0.3 Connectors.MCPCatalogSeed` — boot-time mcp_catalog
  upsert (closes #373 generically).
- `0.3 Connectors.Bootstrap.start_vendor_mocks_if_enabled/0` —
  conditional mock vendor MCP boot.
- `0.3 Connectors.Mock.VendorMCPServer` — Plug-based JSON-RPC
  mock; same module powers both `T.start_mock_vendor/2` in tests
  AND the live stage demo (modularity: shared between tests +
  demo).
- `0.3 Connectors.Mock.Fixtures.GoogleWorkspace` — canned
  responses for all 6 functions; sentinel identifiers
  (`nina.beispiel@…`, etc.).
- `0.3 Connectors.GoogleWorkspace` — manifest with `# vendor:
  <endpoint>` line per function (closes I3 for GW).

## Known gaps

- **Real Google MCP endpoint URL TBD.** The runbook documents
  the env-var path, but a production install needs the actual
  vendor URL (Google's official MCP endpoint, or a self-hosted
  thin wrapper over the Gmail/Calendar/Drive REST APIs).
  Tracked as `#373` — partially closed (the mechanism exists;
  the URL still needs to be supplied per deployment).
- **Real OAuth flow with the official Google Cloud project
  not yet UAT'd.** Mock path is fully exercised; the
  real-Google path is described but the
  `Tools.AuthorizeService` walk-through against a real Google
  consent screen hasn't been replayed end-to-end yet. Tracked
  as `#374`.
- **The model invoked `connect_mcp` once during the live walk.**
  Expected — the user's first interaction with the connector
  needs the service registered against the active task.
  `task_services` row gets written; subsequent function calls in
  the same task skip the connect step.
- **No FE surface for "show me my connected services" /
  "disconnect Google".** Operator manages via `dmh_ai rpc`.
  Out of scope for primitive 0.3; this is an admin UX gap to
  pick up alongside the per-connector slice 3 rollout.
- **Mock fixture data is static.** A more elaborate demo would
  parameterise fixtures per call (e.g., search results that
  respond to the query). Today the mock echoes the query but
  the message list is fixed.
