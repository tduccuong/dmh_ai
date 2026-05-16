# 02 — Google Workspace Scheduling (Calendar)

Second Primitive 0.3 demo: composite read + write across one
connector. The agent finds a free slot, then creates an event in
the user's calendar — exercising `gcal.find_free_slots` (read,
free chat) followed by `gcal.create_event` (write, task-gated,
idempotency-key threaded). The mock vendor MCP server returns
fixture slots and a fixture event id so the live run is
deterministic.

Same engineer-assisted shape as demo 01: pre-stage credentials,
show only the chat in front of the customer.

## Who

- **Employee** asks for a calendar slot in chat, then asks for
  the event to be created. The agent's dispatcher handles the
  free-chat read and opens a task for the write.

## Why

SME schedule-juggling is a real time sink. *"Finde mir am
Donnerstag einen freien Slot zwischen 9 und 17 Uhr"* is the
exact phrasing a 30-person GmbH operations lead types into chat
six times a day. With DMH-AI's connector, the agent looks at the
real calendar (or here: the mock), picks an open slot, and
turns it into an event — one round-trip per question, no
context-switching.

## Pre-requisites

- All of demo `01_gw_assistant.md`'s pre-requisites already
  satisfied (vendor mocks running, oauth_catalog + mcp_catalog
  seeded, the test user's `authorized_services` + credentials
  in place). This runbook re-uses that seed; **complete demo 01
  first** if you haven't.
- The same test user (`test@dmhai.local`).

## Steps

Verified live on stage 2026-05-14.

### 1. Send the scheduling question (⚠ ASSISTANT MODE)

```bash
USER_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"test@dmhai.local","password":"<employee password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)

SESSION="demo-gw-cal-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"GW cal demo\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Finde mir am Donnerstag den 21. Mai 2026 zwischen 9 und 17 Uhr einen freien 45-Minuten-Slot in meinem Google Calendar. Sobald du einen hast, erstelle daraus einen Termin mit dem Titel 'Lieferantengespraech Mustermann GmbH'.\"}" \
  http://127.0.0.1:8080/agent/chat
```

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
> Der Termin "Lieferantengespraech Mustermann GmbH" wurde
> erfolgreich am Donnerstag, den 21. Mai 2026, von 12:15 bis
> 13:00 Uhr in deinem Google Calendar erstellt. Du kannst ihn
> hier einsehen:
> [Termin anzeigen](https://calendar.google.com/calendar/event?eid=evt_mock_dmh_demo_001).

**Progress trace:**
- `CreateTask → Suche freien Slot und erstelle Termin` (done)
- `ConnectMcp → google_workspace` (done)
- `GoogleWorkspace.gcal.findFreeSlots → 2026-05-21` (done)
- `GoogleWorkspace.gcal.createEvent → 2026-05-21T13:00:00Z` (done)
- `final_text`

The event id **`evt_mock_dmh_demo_001`** is unique to the mock
fixture (`Connectors.Mock.Fixtures.GoogleWorkspace.sentinels()`).
Its presence in the chat reply proves the dispatcher routed both
functions through the real Caller to the mock and back. The
`gcal.create_event` write was gated correctly — the model opened
a task BEFORE invoking the write function; the dispatcher injected
an `__idempotency_key` derived from `(task_id, step_seq, function)`
so a retry of the same step won't double-book.

## Verifying (acceptance checklist)

- ✅ Two distinct connector tool calls in the progress trace:
  `gcal.findFreeSlots` (read) and `gcal.createEvent` (write).
  Both `done`.
- ✅ A `CreateTask` row appears in the trace BEFORE
  `gcal.createEvent`. The write is task-gated by the dispatcher;
  no task → `write_requires_task` envelope and no vendor call.
- ✅ Final reply mentions the fixture event id
  **`evt_mock_dmh_demo_001`** (or includes it in the Google
  Calendar link). If absent, the chain bypassed the create
  step — check `mode: "assistant"` actually landed.

## Demoing this to a customer (human-driven, browser-based)

Same engineer-assisted pattern as 0.2 demos and demo 01.

### Demoability today — the friction you can't avoid

- **Step 0 — demo 01 must run first** to seed the
  authorized_services row + credentials. The two scenarios share
  state. If you're showing both in a customer meeting, run 01
  before this one; otherwise pre-seed via 01's Step 2 RPC.
- **`mode: "assistant"` flag** — same as every other demo.
- **The mock free-slot fixture returns one slot.** If the
  customer asks *"can I see three options?"* the demo answer is
  "production reads your real calendar and lists all open
  slots; here we seeded one for clarity".

### Day-before staging

1. Demo 01 pre-requisites (mocks running, credentials seeded).
2. Two browser tabs at `http://127.0.0.1:8080`:
   - **Tab A** — admin (optional).
   - **Tab B** — employee, fresh session pre-created with
     `mode: "assistant"`.
3. Run the verification query yourself once. Confirm the reply
   cites `evt_mock_dmh_demo_001`.

### In the meeting (customer watches)

1. **Tab B.** Type into chat:
   > *"Finde mir am Donnerstag den 21. Mai 2026 zwischen 9 und
   > 17 Uhr einen freien 45-Minuten-Slot in meinem Google
   > Calendar. Sobald du einen hast, erstelle daraus einen
   > Termin mit dem Titel 'Lieferantengespraech Mustermann
   > GmbH'."*
2. Wait ~30 seconds. The agent narrates: opening a task,
   connecting Google Workspace, finding the slot, creating the
   event.
3. **Point out** to the customer:
   > *"Sehen Sie die ID `evt_mock_dmh_demo_001` im Link? Die
   > kommt aus der Google-MCP-Antwort. In Produktion klicken
   > Sie hier und landen direkt in Ihrem echten Google
   > Calendar."*

### The pitch in one paragraph

> *"Jeder Termin mit einem externen Lieferanten kostet Sie
> normalerweise drei E-Mails hin und her: Slot vorschlagen,
> Slot bestätigen, Einladung verschicken. Mit DMH-AI tippen Sie
> einen Satz — Termin steht. Der Agent prüft Ihre echte
> Verfügbarkeit, schlägt vor, legt an. Sie genehmigen mit
> einem Klick."*

### Reset between demos

Re-seed credentials via demo 01's Step 2 if the session got
into an odd state; otherwise just open a fresh Tab B session.

## Primitives exercised

- `0.3 Tools.Dispatcher` — Rule 2 (write requires task), Rule 3
  (idempotency-key injection).
- `0.3 Connectors.GoogleWorkspace.gcal.find_free_slots` — vendor
  anchor `freebusy.query`, shim-computed slot list.
- `0.3 Connectors.GoogleWorkspace.gcal.create_event` — vendor
  anchor `events.insert`, idempotency-key-required write.
- `0.3 Connectors.MCPAdapter.Caller.do_real_invoke/5` — same
  real-transport bridge used by demo 01.
- Composite-function composition within one chain: read → task →
  write, all in a single user message.

## Known gaps

- **The mock returns a single fixture slot** (`2026-05-21T14:30+02:00`
  in `Fixtures.GoogleWorkspace.sentinels()`). The agent's
  scheduling choice in the live trace was `12:15–13:00` — the
  model picked its own start time within the 9–17 window and
  invoked `create_event` with that, ignoring the slot the read
  returned. Reality: the model didn't strictly compose the two
  functions; it used the user's window + duration to pick a slot
  independently. For the next-iteration demo, tighten the
  prompt to force "use the slot from findFreeSlots verbatim".
- **`createEvent`'s reply doesn't yet expose the
  `__idempotency_key`** in the chat trace. The key is threaded
  in the function args but not surfaced to the user — fine for
  production (idempotency is a runtime guarantee, not a user
  affordance) but means the customer can't visually verify
  Rule 3 from the chat alone. The audit log row carries it.
