# 03 — Google Workspace Drive Upload

Third Primitive 0.3 demo: write-only verb against Drive. The
agent takes free-form text from the user and uploads it as a
file. Exercises `drive.upload` end-to-end — `Pipelines.URL`-like
shape but on the Drive side: task-gated write, multipart upload,
fixture file_id sentinel.

## Who

- **Employee** asks the agent to save a piece of text (a
  contract draft, a meeting note, a quote) as a Drive file. The
  agent opens a task and invokes `drive.upload` with the
  user-supplied name + content.

## Why

SME staff routinely turn chat exchanges into Drive files —
contract drafts, customer-call notes, weekly status memos. The
manual workflow is: open Drive in a new tab, click "New", click
"File upload" (or paste into a Doc), name it, save. Five clicks
and a context switch for a 100-character document. With DMH-AI
the same outcome is one chat message.

## Pre-requisites

- All of `01_gw_assistant.md`'s pre-requisites already
  satisfied. This runbook re-uses that seed; **complete demo 01
  first** if you haven't.
- The same test user (`test@dmhai.local`).

## Steps

Verified live on stage 2026-05-14.

### 1. Send the upload request (⚠ ASSISTANT MODE)

```bash
USER_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"test@dmhai.local","password":"<employee password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)

SESSION="demo-gw-drive-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"GW drive\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Lade folgenden Inhalt als Datei 'Vertrag_Mustermann_2026-05.txt' in mein Google Drive hoch: 'Vertragsentwurf Mustermann GmbH Q2 2026. Mengenrabatt 12%.'. Sobald die Datei hochgeladen ist, bestaetige mit dem genauen Dateinamen und der vom Drive zugewiesenen file_id, damit ich sie spaeter wiederfinden kann.\"}" \
  http://127.0.0.1:8080/agent/chat
```

The trailing *"bestaetige mit dem genauen Dateinamen und der
file_id"* is deliberate — without it the model produces a vague
"uploaded successfully" reply; with it the model surfaces the
mock's fixture-prefixed file_id, which is what the runbook
verification asserts on. In a real customer demo you can drop
the explicit ask once the FE renders a citation chip.

### 2. Read the answer + verify the trace

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
> The file was uploaded successfully. Here are the details:
>
> - **File name**: `Vertrag_Mustermann_2026-05.txt`
> - **File ID**: `drv_mock_uploaded_388`
>
> You can use this ID to locate or reference the file later.

**Progress trace:**
- `CreateTask → Upload file to Google Drive` (done)
- `ConnectMcp → google_workspace` (done)
- `GoogleWorkspace.drive.upload` (done)
- `final_text`

The file_id prefix **`drv_mock_uploaded_`** is the mock's
`drive_upload` fixture (the suffix is a per-call unique
integer). Its presence in the chat reply proves the dispatcher
routed the write through the real Caller and the mock returned
its canned response. The `drive.upload` verb is `permission:
:write, idempotency_key: :required` — the chain opened a task
first AND the dispatcher injected an `__idempotency_key` so a
retry of the same upload step won't double-write.

## Verifying (acceptance checklist)

- ✅ A `CreateTask` row appears in the trace BEFORE
  `drive.upload`. The write is task-gated.
- ✅ Final reply mentions a file_id matching
  `drv_mock_uploaded_<integer>`. The prefix is the proof point.
- ✅ Final reply echoes the user-supplied filename
  `Vertrag_Mustermann_2026-05.txt`.

## Demoing this to a customer (human-driven, browser-based)

### Demoability today — the friction you can't avoid

- **Step 0 — demo 01 must run first** to seed credentials.
- **`mode: "assistant"` flag** — same as every other demo.
- **The fixture file_id is synthetic** — `drv_mock_uploaded_<int>`
  doesn't open a real Drive URL. Real Google would return a
  Drive web URL the customer could click; the mock just makes
  up an id.
- **The agent's "confirm with the file_id" behaviour depends on
  the user asking.** Without it, the reply is a generic
  "uploaded successfully". Plan to phrase your customer-meeting
  prompt to include the request, or add a system-prompt
  instruction (separate, larger change) that always surfaces
  write-verb return identifiers.

### Day-before staging

1. Demo 01 pre-requisites complete.
2. Two browser tabs at `http://127.0.0.1:8080`:
   - **Tab A** — admin (optional).
   - **Tab B** — employee, fresh assistant-mode session.
3. Run the verification query yourself once. Confirm the reply
   surfaces a `drv_mock_uploaded_<int>` file_id.

### In the meeting (customer watches)

1. **Tab B.** Type into chat:
   > *"Lade folgenden Inhalt als Datei
   > `Vertrag_Mustermann_2026-05.txt` in mein Google Drive
   > hoch: 'Vertragsentwurf Mustermann GmbH Q2 2026.
   > Mengenrabatt 12%.'. Sobald die Datei hochgeladen ist,
   > bestätige mit dem genauen Dateinamen und der vom Drive
   > zugewiesenen file_id."*
2. Wait ~15 seconds. The agent opens a task, fires
   `drive.upload`, and replies with the filename + file_id.
3. **Point out** to the customer:
   > *"Die file_id beginnt mit `drv_mock_uploaded_` — das ist
   > unser Demo-Fixture. In Produktion bekommen Sie hier die
   > echte Google-Drive-ID und einen direkten Link zur Datei."*

### The pitch in one paragraph

> *"Ihr Vertriebsteam tippt eine Angebotszusammenfassung in den
> Chat, der Agent legt sie sofort als Drive-Datei im richtigen
> Ordner ab — keine Pop-ups, keine Klick-Wege durch Drive's
> 'Neu → Datei hochladen'. Der gleiche Pfad funktioniert für
> Meetingnotizen, Vertragsentwürfe, Wochenberichte. Eine
> Konversation, ein Speicherort, sofort archiviert."*

### Reset between demos

Re-seed credentials via demo 01's Step 2 if needed; otherwise
just open a fresh Tab B session.

## Primitives exercised

- `0.3 Tools.Dispatcher` — Rule 2 (write requires task), Rule 3
  (idempotency-key injection).
- `0.3 Connectors.GoogleWorkspace.drive.upload` — vendor anchor
  `files.create` multipart (Drive API v3),
  idempotency-key-required write.
- `0.3 Connectors.MCPAdapter.Caller.do_real_invoke/5` — same
  real-transport bridge.

## Known gaps

- **No folder placement.** The current `drive.upload` verb
  doesn't accept `folder_id` — the file lands at the Drive
  root. Customers will ask for this; track in a future
  manifest extension (the Drive v3 API supports it via
  `parents:` in the metadata multipart).
- **`mime_type` defaults to `application/octet-stream`** when
  the user doesn't provide one. For `.txt` content this is
  technically wrong (`text/plain` would be better) — the agent
  should sniff from the filename extension. Punt as a manifest
  refinement.
- **Content size limits not enforced.** The verb accepts
  arbitrary string content. A 200 MB paste would try to go
  through the chain. Add a soft cap in the connector once
  resumable-upload support lands.
