# 02 — Operations SOP Folder Self-Service

Folder-walker scenario: one `/index` against a directory of `.md`
SOPs, retrieval grounded in the right file. Exercises
`Pipelines.Folder` (recursive walk + extension-whitelist skip) +
`Pipelines.File` per readable child + auto-fetch retrieval.

## Who

- **Admin / ops lead** places a folder of SOPs on the master
  container's volume.
- **On-call / ops staff** asks *"wen muss ich bei X wecken?"* at
  3 a.m. and gets the right SOP cited verbatim.

## Why

A 30-person SME often has dozens of SOPs spread across Notion / a
shared drive / `internal-wiki/`. On-call staff can't find the
right one fast enough; the wrong one gets followed; outages
extend. With DMH-AI's folder pipeline: ingest the whole folder
once, every employee self-serves from the canonical procedure.

## Pre-requisites

- Running DMH-AI stage at `http://127.0.0.1:8080`. Demo assumes
  127.0.0.1.
- Admin + non-admin user in the same org (`admin@dmhai.local` and
  `test@dmhai.local` from the demo-01 runbook — re-use them).
- Fixture: `demo/layer-0.2/fixtures/sops/` in this repo. Four
  German Markdown SOPs (`01_eskalation-matrix.md`,
  `02_datenbank-failover.md`, `03_deployment-rollback.md`,
  `04_secret-rotation.md`). All checked in.

## Steps

Verified live on stage 2026-05-14. Copy each block as-is.

### 1. Stage the SOP folder into the admin's assets directory

```bash
docker cp demo/layer-0.2/fixtures/sops \
  dmh_ai-master:/data/user_assets/admin@dmhai.local/sops

# Sanity check.
docker exec dmh_ai-master ls /data/user_assets/admin@dmhai.local/sops/
```

Expected: four `.md` files listed (`01_…` through `04_…`).

### 2. Get an admin token

```bash
ADMIN_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"admin@dmhai.local","password":"<your admin password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)
```

### 3. Create a session and run `/index` on the folder

```bash
SESSION="demo-sops-idx-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"index sops\",\"createdAt\":$(date +%s%3N)}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"/index /data/user_assets/admin@dmhai.local/sops\"}" \
  http://127.0.0.1:8080/agent/chat
# → {"handled":true,"user_ts":...}
```

The Folder pipeline walks the directory, applies the
extension-whitelist (`.md` / `.txt` / `.rst` / … on the text side;
`.pdf` / `.docx` / … on the doc side), skips hidden + skiplist
entries, and delegates each readable file to `Pipelines.File`.
The ack arrives quickly (sync intake); per-file ingestion runs
in the background and finishes within seconds for small text
files.

### 4. Verify ingestion

Poll until you see four file rows. Per the current admin API
shape, the SOP titles come back as basenames in `title`; the
`source_ref` column isn't surfaced in the JSON envelope (known
gap — see below).

```bash
sleep 8
curl -s -H "Authorization: Bearer $ADMIN_TOK" \
  http://127.0.0.1:8080/admin/kb-sources \
  | jq '[.sources[] | select(.title | endswith(".md"))] | length'
```

Expected: `4`. Each row carries `source_kind="file"`,
`ingest_status="indexed"`, a content_sha256, a non-zero
`last_indexed_at`.

### 5. Ask the escalation question (as the employee — ⚠ ASSISTANT MODE)

```bash
USER_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"test@dmhai.local","password":"<employee password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)

SESSION="demo-sops-q-$(date +%s)"
# `mode: "assistant"` is load-bearing — without it the runtime
# does NOT auto-fetch indexed context and the model answers from
# training only (will produce a generic "wake your manager" reply
# that is NOT grounded in YOUR SOPs).
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"sop q\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Wen muss ich bei einem kritischen Datenbankausfall um 3 Uhr nachts wecken? Wie ist der Eskalationsweg?\"}" \
  http://127.0.0.1:8080/agent/chat
```

### 6. Read the answer + verify the trace

```bash
sleep 30
# Progress: `final_text` only — auto-fetch is in-line, not a
# separate progress row. fetch_index would only appear if the
# model decided to dig deeper, which it doesn't need to here.
curl -s -H "Authorization: Bearer $USER_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION/progress" | jq '.progress[]? | {label, status}'

# Final assistant text.
curl -s -H "Authorization: Bearer $USER_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION" \
  | jq '.messages[-1].content'
```

Live run (2026-05-14) produced the verbatim answer:

> Bei einem kritischen Datenbankausfall (Sev1) um 3 Uhr nachts
> müssen Sie den On-Call-Engineer über PagerDuty (Service:
> `dmh-prod-sev1`) wecken. Wenn dieser nach 90 Sekunden nicht
> reagiert, rotiert der Anruf zur Sekundär-Schicht. Innerhalb
> von 15 Minuten müssen Sie den CTO über den Slack-Channel
> `#sev1-incidents` benachrichtigen und eine Incident-Bridge
> eröffnen. Falls der CTO nicht reagiert, müssen Sie innerhalb
> von 30 Minuten die Geschäftsführung (CEO) direkt anrufen. Die
> Notfall-Nummer finden Sie im 1Password-Vault
> `runtime-emergency`.

Every detail — PagerDuty service name `dmh-prod-sev1`, the 90 s
PagerDuty rotation, `#sev1-incidents`, the 30-minute CEO
escalation, the `runtime-emergency` 1Password vault — is unique
to `01_eskalation-matrix.md`. The model could not have invented
any of it without the indexed-context block. The training
default ("call your manager", "follow your incident process")
would be conspicuously generic by comparison.

## Verifying (acceptance checklist)

- ✅ Step 1: `docker exec ls` shows four `.md` files in
  `/data/user_assets/admin@dmhai.local/sops/`.
- ✅ Step 3: `/index` ack returns `{"handled":true,...}` and the
  follow-up `command_ack` reports `(4 indexed, 0 skipped)`.
- ✅ Step 4: kb-sources count of `.md` rows = 4, all `indexed`.
- ✅ Step 6: answer cites PagerDuty + `dmh-prod-sev1` + 90 s +
  CTO + `#sev1-incidents` + CEO + `runtime-emergency`. If any
  is missing, the indexed block didn't reach the model (check
  `mode: "assistant"` actually landed).

## Cross-checking which SOP file was hit

The `<augmented_facts type="indexed">` block isn't echoed in the
chat response, but you can confirm which source the chunks came
from by inspecting `kb_chunks_meta`:

```bash
docker exec dmh_ai-master sqlite3 /data/db/chat.db \
  "SELECT ks.title, COUNT(*) FROM kb_chunks_meta kcm
   JOIN kb_sources ks ON ks.id = kcm.source_id
   WHERE ks.title LIKE '%.md' GROUP BY ks.title;"
```

Expected: four rows, one per SOP file, each with ≥1 chunk.

## Cleanup

```bash
# Remove all SOP sources (loop the single-source endpoint —
# bulk-remove is a known gap).
curl -s -H "Authorization: Bearer $ADMIN_TOK" \
  http://127.0.0.1:8080/admin/kb-sources \
  | jq -r '.sources[] | select(.title | endswith(".md")) | .source_id' \
  | while read SID; do
      curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
        -H "Content-Type: application/json" \
        -d "{\"source_id\":\"$SID\",\"reason\":\"end of demo\"}" \
        http://127.0.0.1:8080/admin/kb-sources/remove
    done
```

After cleanup, re-asking the question returns a generic answer
that does NOT mention any of the fixture-specific identifiers.

## Demoing this to a customer (human-driven, browser-based)

Same engineer-assisted pattern as demo 01. Pre-stage everything;
show only the chat in the meeting.

### Demoability today — the friction you can't avoid

- **`docker cp` step (Step 1) requires shell access.** No
  folder-upload in the FE today. Do this before the customer
  is in the room.
- **`mode: "assistant"` flag (Step 5).** Pre-create the
  employee session with the flag set.
- **No citation chip.** The agent paraphrases the SOP without
  saying *"see 01_eskalation-matrix.md"*. You'll point out
  the fixture-specific identifiers manually: PagerDuty
  `dmh-prod-sev1`, the 90-second rotation, `#sev1-incidents`,
  the 30-minute CEO escalation, the `runtime-emergency`
  1Password vault.

### Day-before staging (you, with shell access)

1. Run **Steps 1–4** of the runbook so all four SOPs are
   ingested.
2. Open two browser tabs at `http://127.0.0.1:8080`:
   - **Tab A** — admin (`admin@dmhai.local`).
   - **Tab B** — employee (`test@dmhai.local`), session
     pre-created with `mode: "assistant"`.
3. Run the verification query yourself once (Step 5's second
   curl block). Confirm the reply cites at least three of:
   PagerDuty `dmh-prod-sev1`, `#sev1-incidents`, the CEO
   30-minute step, `runtime-emergency`. If any is missing, fix
   before the meeting.

### In the meeting (customer watches)

1. **Tab A.** Show `/admin/kb-sources` filtered to `.md` files —
   *"Vier SOPs sind indexiert: Eskalation, DB-Failover,
   Deployment-Rollback, Secret-Rotation. Diese Liste pflegen Sie
   selbst — neue SOP rein, alte raus, einmal pro Quartal."*
2. **Tab B.** Type into chat:
   > *"Wen muss ich bei einem kritischen Datenbankausfall um
   > 3 Uhr nachts wecken? Wie ist der Eskalationsweg?"*
3. Wait ~10–15 seconds. The agent answers with the PagerDuty
   service name, the rotation timing, the CTO Slack channel,
   the CEO escalation.
4. **Point out** to the customer:
   > *"`dmh-prod-sev1`, `#sev1-incidents`, `runtime-emergency` —
   > diese Bezeichner stehen nur in Ihrer Eskalations-SOP.
   > Kein Trainingsdatensatz der Welt kennt diese Strings. Der
   > Agent liest Ihre SOP wortgenau."*

### The pitch in one paragraph

> *"Ihre On-Call-Person um 3 Uhr nachts hat keine Zeit, sich
> durch Notion zur richtigen Eskalations-SOP zu klicken. Sie
> tippt einen Satz in den Chat, DMH-AI zitiert die richtige
> Prozedur, die Eskalation startet in unter einer Minute. Der
> gleiche Vorgang funktioniert, egal ob Ihr Unternehmen 4 oder
> 400 SOPs hat — der Agent skaliert mit dem Inhalt, nicht mit
> der Suchgeduld der Mitarbeiterin um 3 Uhr nachts."*

### Reset between demos

Cleanup removes all four SOP sources; re-run the staging.
~30 seconds operator time per customer.

## Primitives exercised

- `0.2 Pipelines.Folder.run_async/3` — recursive walker, skiplist,
  extension-whitelist, hidden-file skip
- `0.2 Pipelines.File.run/3` — per-file ingest (called by Folder)
- `0.2 Ingest.upsert_kb_source` — content-hash idempotent
- `0.2 Runtime auto-fetch (Assistant mode)` —
  `Agent.UserAgent.build_indexed_context/3` →
  `<augmented_facts type="indexed">` block
- `0.2 Handlers.AdminKbSources` — list + remove
- `0.1 Org scoping` — non-admin in a different org gets zero hits

## Known gaps

- **`source_ref` is not exposed in the `/admin/kb-sources` JSON
  envelope.** The column is populated in the DB but the handler
  doesn't include it in the response. Operator verification has
  to fall back to `title` + `kb_chunks_meta` queries. Minor admin
  UX issue, not a primitive bug.
- **No bulk-remove primitive.** Cleanup loops the
  single-source-remove endpoint; for 4 sources that's fine, for
  a 200-file folder it's awkward. If this becomes a frequent
  operator pattern, add `Ingest.remove_sources_by_prefix!/2`
  rather than scripting around it.
- **Container-absolute-path requirement.** Same friction as the
  handbook scenario — admin needs shell access to `docker cp`
  the folder in. A file-/folder-upload-to-ingestion FE flow is
  in the larger 0.2 user-experience roadmap, not the primitive.
- **No citation rendering in the chat reply.** The model
  paraphrases the SOP but doesn't surface "see
  `01_eskalation-matrix.md`" inline. Operator can verify via
  the `kb_chunks_meta` query above; a chat-UI citation
  affordance is roadmap, not primitive.
