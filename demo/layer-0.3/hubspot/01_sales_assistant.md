# 01 — HubSpot Sales Assistant (CRM contacts + deals)

First HubSpot demo, third connector vertical overall: real Caller
→ mock vendor MCP server → canned response → agent grounds its
reply in the HubSpot connector's output. Same shape as the
Google Workspace + Microsoft 365 `01_assistant.md` runbooks but
on a CRM data surface (contacts / deals / activities) instead of
mail / calendar / files.

## Who

- **Admin** (operator) flips one env-var on the stage host then
  configures the HubSpot connector via External Connectors.
- **Sales user** asks SME questions in chat:
    - *"Welche Deals stehen diese Woche auf der Kippe?"* → agent
      fires `hubspot.deal.find(stage: …)` (read, free chat).
    - *"Entwirf eine Follow-up-Notiz für den Deal mit
      Mustermann GmbH"* → opens a task, fires
      `hubspot.activity.log` (write, idempotency-keyed).

## Why

DMH-AI's value for a B2B sales team isn't another inbox — it's
the agent answering *"what should I do next in this pipeline?"*
without the rep having to open three browser tabs. Two-line
chat replaces a pipeline scan + a follow-up draft. This runbook
is the first end-to-end proof on the CRM surface.

## Pre-requisites

- All of the **Common pre-requisites** in the parent
  `../README.md` (stage running, two users, mock subprocess
  enabled).
- HubSpot mock subprocess running on `127.0.0.1:8089` (boots
  alongside the GW + M365 mocks when
  `DMH_AI_ENABLE_VENDOR_MOCKS=true` is set).

## Steps

### 1. Rebuild + redeploy stage with vendor mocks on

```bash
export DMH_AI_ENABLE_VENDOR_MOCKS=true
./scripts/build.sh --stage
./dist/install.sh --stage
```

Verify the HubSpot mock is reachable:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  http://127.0.0.1:8089/ | jq .result.serverInfo
```

Expected: `{"name":"dmh-ai-mock-vendor","version":"0.1.0", …}`.

### 2. Admin configures the HubSpot connector via External Connectors

1. Log in as admin → **External Connectors** → **HubSpot**.
2. **MCP URL** — clear the in-process default
   (`http://127.0.0.1:8087/hubspot`) and paste
   `http://127.0.0.1:8089/` so the dispatcher routes through
   the mock.
3. **Capabilities to expose** — leave all three ticked
   (Contacts, Deals, Activities).
4. (Client ID / Client Secret left empty — the mock doesn't run
   OAuth.)
5. **Save** → **Test connection** → expect ✅ *"Reachable — 6
   functions exposed by dmh-ai-mock-vendor."*

### 3. Bypass the OAuth flow (mock path only)

```bash
USER_ID=$(docker exec dmh_ai-master /app/bin/dmh_ai rpc '
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  [[id]] = query!(Repo, "SELECT id FROM users WHERE email=?",
                  ["test@dmhai.local"]).rows
  IO.write(id)
')

docker exec dmh_ai-master /app/bin/dmh_ai rpc "
  user_id = \"$USER_ID\"
  slug = \"hubspot\"
  mock_url = \"http://127.0.0.1:8089/\"

  :ok = DmhAi.MCP.Registry.authorize(user_id, slug, mock_url, mock_url, nil)
  :ok = DmhAi.Auth.Credentials.save(user_id, \"oauth:\" <> slug, \"oauth2\",
                                    %{\"access_token\" => \"stage-hubspot-mock-token\"},
                                    account: \"\")
  :ok = DmhAi.Auth.Credentials.save(user_id, \"mcp:\" <> mock_url, \"oauth2_mcp\",
                                    %{\"access_token\" => \"stage-hubspot-mock-bearer\"},
                                    account: \"\",
                                    expires_at: :os.system_time(:millisecond) + 3_600_000)
  IO.puts(\"authorized\")
"
```

### 4. Chat as the sales user (⚠ ASSISTANT MODE)

```bash
USER_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"test@dmhai.local","password":"<employee password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)

SESSION="demo-hubspot-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"HubSpot demo\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Welche Deals stehen diese Woche auf der Kippe? Bitte ueber den HubSpot Connector pruefen.\"}" \
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

Expected — the reply cites the fixture deal name (*"Mustermann
GmbH — Q2 Stiftungsfeier"*) and deal id (`hs_deal_mock_002`).
Progress trace shows `CreateTask → ConnectMcp → HubSpot.deal.find →
final_text`.

Both strings are unique to the HubSpot fixture
(`Connectors.Mock.Fixtures.HubSpot`). The agent could not have
produced either without the mock's canned response flowing
through the real Caller path.

## Verifying (acceptance checklist)

- ✅ Step 1: `curl http://127.0.0.1:8089/` returns mock
  `initialize` response.
- ✅ Step 2: External Connectors page shows HubSpot card with
  `MCP URL ✓` badge; Test connection succeeds with 6 functions.
- ✅ Step 3: RPC prints `authorized`.
- ✅ Step 5: Final reply mentions **both** sentinel deal name
  AND deal id.

## Demoing this to a customer (human-driven, browser-based)

### Day-before staging

1. Run **Steps 1–3** of the runbook.
2. Open two browser tabs at `http://127.0.0.1:8080`:
    - **Tab A** — admin, on `/connectors` showing the HubSpot
      card with green badges. Useful for the *"this is how I
      curated the capabilities"* beat.
    - **Tab B** — sales user, session pre-created with
      `mode: "assistant"`.
3. Run the verification query once. Confirm the reply quotes
   `hs_deal_mock_002`.

### In the meeting (customer watches)

1. **Tab B.** Type into chat:
   > *"Welche Deals stehen diese Woche auf der Kippe? Bitte über
   > den HubSpot Connector prüfen."*
2. Wait ~20 seconds. The agent opens a task, fires
   `deal.find`, narrates the pipeline summary.
3. **Point out** to the customer:
   > *"Die Deal-ID `hs_deal_mock_002` stammt aus der HubSpot-MCP-
   > Antwort, die der Agent abgefragt hat. In Produktion zieht er
   > Ihre echten Deals aus Ihrem HubSpot-Portal."*

### The pitch in one paragraph

> *"Ihr Vertriebsteam scannt HubSpot nicht mehr manuell. DMH-AI
> spricht direkt mit Ihrem CRM — Pipeline-Status, Deal-Details,
> Notizen anlegen — alles im Chat. Eine Frage, eine Antwort, der
> Agent kümmert sich um die Klickwege durch HubSpot. Mit dem
> gleichen Schienensystem, das Sie schon für Google Workspace
> oder Microsoft 365 kennen — derselbe Admin-Bildschirm,
> dieselben Capability-Tickboxes, dasselbe One-Click-Connect."*

## Switching to real HubSpot (production UAT)

Turn the mock off and rebuild — the in-process MCP REST
translator is always on:

```bash
unset DMH_AI_ENABLE_VENDOR_MOCKS
./scripts/build.sh --stage && ./dist/install.sh --stage
```

Then on the running stage:

1. Admin opens `/connectors` → **HubSpot** → tick the
   capabilities your org needs → paste Client ID + Client
   Secret (from your HubSpot Public App — see
   `HUBSPOT_APP_SETUP.md`) → MCP URL stays at the pre-filled
   in-process default → **Save** → **Test connection**.
2. Sales staff clicks **My Services → Connect HubSpot** → real
   HubSpot consent screen → approve → callback page closes →
   chat shows green toast.
3. Run the live-portal UAT script — five chat prompts (three
   reads, two writes) — in `02_uat_real_portal.md`.

## Primitives exercised

Same set as the GW + M365 verticals — proves the framework, not
just one connector:

- `0.3 Tools.Dispatcher` — 4-rule chokepoint, capability gate
  (Layer 3).
- `0.3 Connectors.MCPAdapter.Caller.do_real_invoke/5` — real
  bridge.
- `0.3 Connectors.MCPCatalogSeed` + `OAuthCatalogSeed` —
  boot-time vendor metadata seed for HubSpot.
- `0.3 Connectors.Bootstrap.start_vendor_mocks_if_enabled/0` —
  per-connector mock boot via `mock_descriptor/0`.
- `0.3 Connectors.Mock.Fixtures.HubSpot` — canned responses with
  sentinel identifiers (German fake personas + deal IDs).
- `0.3 Connectors.HubSpot` — manifest with `# vendor: <endpoint>`
  lines per function (closes I3 for HubSpot).
- `0.3 Connectors.HubSpot.MCPHandler` — FunctionSpec map for the
  six CRM v3 endpoints + the deal.update custom handler with
  dynamic URL.
- `0.3 Connectors.Capabilities` — admin's `enabled_capabilities`
  drives the 3-layer enforcement.
- `0.3 Tools.ConnectMcp.InProcess` — attach path that resolves
  HubSpot by slug, reads tools list from the handler, applies
  capability filter.

## Known gaps

- **`activity.log` uses Notes engagements** — HubSpot has richer
  engagement types (Calls, Meetings, Emails) with their own API
  endpoints. The Notes shim is the simplest path; richer engagement-
  type support is deferred.
- **`contact.create` doesn't upsert by email** — HubSpot allows
  `idProperty=email` query param to convert create-into-upsert.
  Today the function will 409 on duplicate (mapped to `:duplicate`
  envelope); future polish is to pass `idProperty=email`.
- **Multi-portal connections** — a single user can today only
  authorize ONE HubSpot portal. Multi-account fan-out support
  exists in the credential schema (`account` field) but the
  HubSpot connector's `oauth_catalog_descriptor` doesn't yet
  carry a userinfo endpoint to resolve which portal was
  connected, so the `account` label stays empty.
