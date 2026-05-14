# 01 — Employee Handbook Q&A

Smallest 0.2 scenario: one local file, sync ingest, retrieval from
chat. Exercises only `Pipelines.File` + `FetchIndex` + the admin
KB-management endpoints.

## Who

- **Admin** uploads the handbook once.
- **Every employee** in the org asks ad-hoc questions in chat
  *("Wie viele Urlaubstage habe ich?", "What's the parental-leave
  policy?", "wen kontaktiere ich bei Arbeitsunfall?")*.

## Why

HR fields the same dozen handbook questions every week. Each costs
~5 minutes of HR time and ~10 minutes of employee wait. A 30-person
SME loses ~10 hours/week to handbook Q&A. With DMH-AI: the handbook
is a single ingest; every employee self-serves from the canonical
source; HR only sees the questions the handbook can't answer.

## Pre-requisites

- Running DMH-AI stage at `http://127.0.0.1:8080` (or your install's
  URL). The remainder assumes 127.0.0.1.
- Two users in the same org: an admin and a non-admin "employee".
  On a fresh install the admin is auto-created at first boot; add a
  member via the Manage Users admin overlay (or POST `/users` from
  the admin token — same path).
- Admin password known to the operator. If you forgot it, see
  *"Resetting the admin password"* at the end.
- Fixture: `mitarbeiterhandbuch.pdf` lives under
  `demo/layer-0.2/fixtures/` in this repo. It's regenerable via
  `python3 generate_handbook.py` (the script lives next to it).

## Steps

The runbook below was verified live on stage on 2026-05-14. Copy
each block as-is, substituting your admin / employee emails and
passwords. **`mode: "assistant"` on session creation is
load-bearing** — see the "How the mechanics work" section below.

### 1. Stage the handbook into the admin's assets directory

The `/index` command takes a **container-absolute path**. The
master container's `user_assets` is a Docker volume; copy the
fixture in:

```bash
# Adjust to your admin email and DMH-AI container name.
ADMIN_EMAIL="admin@dmhai.local"
docker cp demo/layer-0.2/fixtures/mitarbeiterhandbuch.pdf \
  dmh_ai-master:/data/user_assets/$ADMIN_EMAIL/mitarbeiterhandbuch.pdf

# Sanity: confirm visible inside the container at the expected path.
docker exec dmh_ai-master ls /data/user_assets/$ADMIN_EMAIL/mitarbeiterhandbuch.pdf
```

### 2. Get an admin auth token

```bash
ADMIN_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"admin@dmhai.local","password":"<your admin password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)
echo "admin token: ${ADMIN_TOK:0:16}..."
```

### 3. Create an assistant-mode session and run `/index`

`/index` is a slash-command intercepted by the runtime; it doesn't
need an LLM turn. Either mode (confidant / assistant) accepts it.
We use `confidant` here because it's cheap:

```bash
SESSION="demo-handbook-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"index handbook\",\"createdAt\":$(date +%s%3N)}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"/index /data/user_assets/admin@dmhai.local/mitarbeiterhandbuch.pdf\"}" \
  http://127.0.0.1:8080/agent/chat
# → {"handled":true,"user_ts":...}
```

### 4. Verify ingestion

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOK" \
  http://127.0.0.1:8080/admin/kb-sources \
  | jq '.sources[] | select(.source_kind == "file")'
```

Expected: one row, `title="mitarbeiterhandbuch.pdf"`, `ingest_status="indexed"`,
a sha256 `content_sha256` value, a non-zero `last_indexed_at`. Live
run with the committed fixture produces **3 chunks** (verifiable
via `SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id=…`).

### 5. Ask the question as the employee — ⚠ ASSISTANT MODE

```bash
USER_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"test@dmhai.local","password":"<employee password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)

SESSION="demo-employee-$(date +%s)"
# NOTE the explicit `"mode":"assistant"` — without it the session
# defaults to confidant, which has zero tools available and the
# model will answer from training (wrong: generic BUrlG, not your
# handbook). See "How the mechanics work" below.
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"handbook q\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Wie viele Urlaubstage habe ich nach drei Jahren?\"}" \
  http://127.0.0.1:8080/agent/chat
```

### 6. Watch the chain land + verify the answer

```bash
sleep 25
# Progress trace — for a question the auto-fetched indexed context
# already answers, the trace is just `final_text`. No `fetch_index`
# tool call: the runtime fetched the chunks before the model turn,
# so the model never needed to dig deeper.
curl -s -H "Authorization: Bearer $USER_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION/progress" | jq

# The final assistant text.
curl -s -H "Authorization: Bearer $USER_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION" \
  | jq '.messages[-1].content'
```

Live run (2026-05-14) produced:
- Progress: `final_text` only (the runtime's auto-fetch happens
  in the same turn as the LLM call, so no separate progress row).
- Final reply: `"Nach drei Jahren Betriebszugehörigkeit bei der
  DMH SME Demo GmbH haben Sie Anspruch auf 28 Urlaubstage pro
  Jahr."`

The number **28** comes from §3 of the handbook fixture; the
company name **DMH SME Demo GmbH** is the fixture's letterhead.
Both prove the indexed-context block landed in the model's
prompt. The generic German employment-law default
(Bundesurlaubsgesetz) is 20 days — if you see 20 in the reply,
the model bypassed the indexed context and answered from
training; check that `mode: "assistant"` actually landed on the
session row (`docker exec dmh_ai-master sqlite3 /data/db/chat.db
"SELECT mode FROM sessions WHERE id='$SESSION'"`).

## Verifying (acceptance checklist)

- ✅ `docker exec ls` shows the PDF at the expected container path.
- ✅ `/index` ack is `{"handled":true, ...}`.
- ✅ `/admin/kb-sources` returns one file row with `ingest_status=indexed`.
- ✅ Final answer is the org-specific number (28) AND mentions the
  handbook's company name (DMH SME Demo GmbH) — both prove the
  indexed-context block reached the model. The generic legal
  default would be 20 and would never mention the company.
- ✅ Cross-org user (member of a different org) sees zero hits on the
  same query. F35 pins this; if you want to verify by hand, create
  a second org + user and re-run step 5.

## Cleanup

Remove the source (admin only). `source_id` is server-generated
(sha256 over org_id + absolute path) — fetch it from the list first:

```bash
SOURCE_ID=$(curl -s -H "Authorization: Bearer $ADMIN_TOK" \
              http://127.0.0.1:8080/admin/kb-sources \
            | jq -r '.sources[] | select(.title | contains("mitarbeiterhandbuch")) | .source_id')

curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"source_id\":\"$SOURCE_ID\",\"reason\":\"end of demo\"}" \
  http://127.0.0.1:8080/admin/kb-sources/remove
```

Confirms by:
- `GET /admin/kb-sources` no longer lists the row.
- A `kb_source_history` row records the removal (audit trail).
- Employee re-asking the question gets a non-handbook answer
  (training default).

## Demoing this to a customer (human-driven, browser-based)

The runbook above is the operator-replayable verification (curl
commands, deterministic, scriptable). A live sales demo is
different: the customer doesn't want to watch you SSH into a
container. Pre-stage everything; show only the chat in the
meeting.

### Demoability today — the friction you can't avoid

Three things make this an *engineer-assisted* demo rather than
a *drag-drop sales* demo. Know them, work around them:

- **`docker cp` step (Step 1) requires shell access.** No
  drag-drop file upload in the FE today. Do this before the
  customer is in the room.
- **`mode: "assistant"` is a JSON flag (Step 5).** The FE has
  a mode toggle but a session created without it answers from
  training only — the demo silently fails (plausible-sounding
  generic German labour-law answer). Pre-create the employee
  session with the flag set.
- **No citation chip in the chat reply.** The agent
  paraphrases the handbook without a visible *"see
  Mitarbeiterhandbuch §3"*. You must point out the
  fixture-specific identifiers manually (see below).

### Day-before staging (you, with shell access)

1. Run **Steps 1–4** of the runbook so the handbook is
   ingested.
2. Open two browser tabs at `http://127.0.0.1:8080`:
   - **Tab A** — logged in as `admin@dmhai.local`.
   - **Tab B** — logged in as `test@dmhai.local`. Create the
     session here with `mode: "assistant"` (Step 5's first
     curl block) so you don't have to in front of the
     customer.
3. Run the verification query yourself once (Step 5's second
   curl block) and confirm the reply mentions **28 Tage** AND
   **DMH SME Demo GmbH**. If either is missing, fix before the
   meeting — do not improvise in front of the customer.
4. Clear Tab B's chat input, ready for the customer.

### In the meeting (customer watches)

1. **Tab A.** Show `/admin/kb-sources` — *"Hier sehen Sie alle
   indexierten Quellen Ihrer Organisation: aktuell eine Datei,
   das Mitarbeiterhandbuch."* This grounds that the corpus is
   concrete and visible.
2. **Switch to Tab B.** Type into the chat:
   > *"Wie viele Urlaubstage habe ich nach drei Jahren?"*
3. Wait ~5–10 seconds. The agent replies with **28
   Urlaubstage** and mentions **DMH SME Demo GmbH**.
4. **Point out** to the customer:
   > *"Die Zahl 28 steht so nur in IHREM Handbuch. Die
   > deutsche Gesetzes-Default-Zahl wäre 20 (Bundesurlaubsgesetz).
   > Und 'DMH SME Demo GmbH' steht nirgends im Trainingsdatensatz
   > eines LLMs — der Agent zitiert IHREN Inhalt, nicht das
   > Internet."*

### The pitch in one paragraph

> *"Stellen Sie sich vor, Ihre HR-Abteilung beantwortet jede Woche
> die gleichen zwölf Handbuch-Fragen — fünf Minuten pro Antwort,
> zehn Minuten Wartezeit pro Mitarbeiterin. Mit DMH-AI laden Sie
> das Handbuch einmal hoch, jede Mitarbeiterin fragt direkt im
> Chat, die Antwort zitiert Ihr Handbuch — nicht das Internet.
> HR sieht nur noch die Fragen, die das Handbuch nicht
> beantwortet."*

### Reset between demos

Run **Cleanup**, then re-run the day-before staging. The full
cycle is ~30 seconds of operator time per customer.

## How the mechanics work (so you can debug)

The chain has two modes:

| Mode | Retrieval | Use for |
|---|---|---|
| `confidant` | none — no indexed auto-fetch, no `web_search`, no tools | Casual chat that should NOT consult external sources. |
| `assistant` | runtime auto-fetch (indexed + memo) on every turn; `fetch_index` / `fetch_memo` / `web_search` available as dig-deeper tools | SME knowledge / agentic work. |

`POST /sessions` defaults to `confidant` when the body omits `mode`.
For *every* handbook-Q&A scenario the employee's session MUST be
created with `"mode": "assistant"` — otherwise the runtime does
not auto-fetch indexed context, and the model answers from
training only (the reply looks plausible, just isn't grounded in
YOUR handbook).

In assistant mode, the chain is:

1. **Runtime auto-fetch (before LLM call):** `Agent.UserAgent` calls
   `build_indexed_context/3` (org-scoped KB vector search) +
   `build_memo_context/3` (user-scoped encrypted memo search) on
   the latest user message.
2. **Context engine wraps both:** `Agent.ContextEngine` prepends
   `<augmented_facts type="indexed">…</augmented_facts>` and
   `<augmented_facts type="memo">…</augmented_facts>` blocks to
   the user message, in that order (encoding precedence
   `indexed > memo > web_search > training`).
3. **LLM call:** the model reads the augmented blocks first, then
   the user's text. For the handbook question, the indexed block
   already contains the §3 chunk (28 days), so the model produces
   a final answer without invoking any tool.
4. **Dig-deeper path:** if the auto-fetched blocks are thin
   (broad query, off-topic, or KB empty), the model can call
   `fetch_index(q)` or `fetch_memo(q)` for a fresh retrieval, or
   `web_search(q)` for external lookup. These appear as separate
   progress rows when invoked.

## Primitives exercised

- `0.2 Pipelines.File.run/3` — file-path ingest, content-hash idempotent
- `0.2 Ingest.upsert_kb_source` — atomic upsert
- `0.2 Tools.FetchIndex` — retrieval at chat time, BG-refresh enqueue
- `0.2 Handlers.AdminKbSources` — list + remove
- `0.2 Ingest.remove_source!` — admin-only cascade + history row
- `0.1 Org scoping` — cross-org user gets zero hits
- `Agent.UserAgent` assistant-mode chain — tool catalog assembly + model orchestration

## Known gaps

- **Container-absolute-path requirement.** Operators currently need
  shell access to `docker cp` the fixture into the right volume.
  The runbook works around it but it's not "drag-drop in a buyer
  room". A file-upload-to-ingestion FE flow is in the larger 0.2
  user-experience roadmap, not the primitive.
- **No in-chat progress UI for slow ingests.** The /index call
  returns `handled:true` immediately; for a large PDF the admin
  has to poll `/admin/kb-sources` to know when chunks land.
- **No citation rendering in chat UI.** The tool result includes
  source path / chunk text, but the assistant reply is a single
  paragraph — there's no clickable "see source" affordance yet.
  Operator can verify by reading the fixture PDF.
- **Operator must remember `mode: "assistant"`.** This is the
  largest "I can demo this in a buyer room without an engineer"
  friction surfaced by the live walk-through. The FE's chat-mode
  selector exists, but the API caller in this runbook has to set
  the flag explicitly. Worth promoting to a primitive-level
  improvement: either default new sessions to assistant for orgs
  with at least one kb_sources row, or surface the mode toggle
  more prominently.

## Resetting the admin password

If the admin password is unknown (forgotten / fresh handover), the
operator can reset it via the master container's IEx:

```bash
docker exec dmh_ai-master /app/bin/dmh_ai rpc '
  h = DmhAi.AuthPlug.hash_password("<new-password>")
  Ecto.Adapters.SQL.query!(DmhAi.Repo,
    "UPDATE users SET password_hash=? WHERE email=?",
    [h, "admin@dmhai.local"])
  IO.puts("password updated")'
```

For this runbook's live verification we used `demo-handbook-pass`
on both `admin@dmhai.local` and `test@dmhai.local` (clearly fake
per repo rule; rotate before any real usage).
