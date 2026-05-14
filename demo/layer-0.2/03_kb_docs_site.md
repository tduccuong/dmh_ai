# 03 — Live Product Documentation Q&A

URL-pipeline scenario: BFS-crawl a small product-docs site,
auto-fetch retrieval at chat time, BG refresh keeps the corpus
fresh when the upstream changes. Exercises `Pipelines.URL` +
`Web.Fetcher` + `Web.ReaderExtractor` + `Ingest.BgRefreshWorker`
(parent-child debounce) + `kb_sources.parent_source_id`.

## Who

- **Admin** registers the company's product-docs URL once.
- **Support / sales / onboarding team** asks "how do I do X with
  the product?" in chat and gets a current answer grounded in
  the live docs site, with the right fixture-specific
  identifiers (audience IDs, attribute names, escalation
  thresholds).

## Why

Product docs change frequently. Pasting a URL into chat and
hoping the model "knows" the page leaves staff with stale or
hallucinated answers. With DMH-AI's URL pipeline + BG refresh:

1. Admin runs `/index <url>` once.
2. The pipeline BFS-crawls same-prefix pages, ingests text.
3. The runtime auto-fetches indexed context on every Assistant
   turn.
4. The BG refresh worker re-crawls stale sources after they're
   hit, so the next query reflects fresh content automatically.

## Pre-requisites

- Running DMH-AI stage at `http://127.0.0.1:8080`.
- Admin + non-admin user in the same org (`admin@dmhai.local` and
  `test@dmhai.local` from the demo-01 / demo-02 runbooks — re-use
  them).
- `python3` on the host (used to serve the docs-site fixture).
- Fixture: `demo/layer-0.2/fixtures/docs-site/` in this repo —
  4 cross-linked German HTML pages
  (`index.html`, `sso.html`, `webhooks.html`,
  `rate-limits.html`) plus a tiny `serve.py` wrapper.

## Why a local fixture (not a live public docs URL)

A public docs URL would: (a) change content under our feet,
breaking deterministic verification; (b) be rate-limited / WAF'd
when the crawler issues 4 fetches in seconds; (c) require
network egress from the stage host. The checked-in fixture
served on `127.0.0.1:8085` removes all three.

## Steps

Verified live on stage 2026-05-14.

### 1. Start the docs-site server (multi-threaded)

The URL pipeline's BFS issues the seed + child fetches **in
parallel**. The stdlib `python3 -m http.server` is
single-threaded and drops concurrent requests with "connection
closed". Use the checked-in `serve.py` wrapper, which uses
`ThreadingHTTPServer`:

```bash
python3 demo/layer-0.2/fixtures/docs-site/serve.py 8085 &
echo "docs-server pid=$!"
# Sanity:
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8085/index.html
docker exec dmh_ai-master sh -c 'wget -qO- --tries=1 --timeout=3 http://127.0.0.1:8085/index.html | head -1'
```

Expected: both checks return `200` / valid HTML. The master
container shares the host's network namespace (`network: host`
on the compose service) — so anything bound to `127.0.0.1` on
the host is reachable as `127.0.0.1` from inside master.

### 2. Get an admin token

```bash
ADMIN_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"admin@dmhai.local","password":"<your admin password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)
```

### 3. /index the docs root

```bash
SESSION="demo-docs-idx-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"index docs\",\"createdAt\":$(date +%s%3N)}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"/index http://127.0.0.1:8085/index.html\"}" \
  http://127.0.0.1:8080/agent/chat
# → {"handled":true, ...}
```

The seed URL is fetched + extracted + indexed, the BFS extracts
same-prefix links from the seed's HTML, queues them, and runs
each through the same path. Depth + page cap come from
`AgentSettings.learn_url_max_depth` / `learn_url_max_pages`.

### 4. Wait for the crawl to finish + verify

```bash
sleep 25
# Final ack message reports the total indexed.
curl -s -H "Authorization: Bearer $ADMIN_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION" \
  | jq '.messages[] | select(.role == "assistant") | .content'
```

Expected last ack: `"Ich habe 4 Seiten von
\`http://127.0.0.1:8085/\` indiziert."` — all four fixture
pages indexed. Each one is a separate `kb_sources` row.

Cross-check directly:

```bash
docker exec dmh_ai-master sqlite3 /data/db/chat.db \
  "SELECT title, source_id, parent_source_id IS NOT NULL AS has_parent
   FROM kb_sources WHERE source_kind='url' AND source_ref LIKE 'http://127.0.0.1:8085/%'
   ORDER BY indexed_at;"
```

Expected: 4 rows. The seed (`index.html`) has `has_parent=0`;
the three child pages (`sso.html`, `webhooks.html`,
`rate-limits.html`) have `has_parent=1`. The parent column is
what `BgRefreshWorker`'s parent-child debounce JOIN uses.

### 5. Ask the SSO question (employee — ⚠ ASSISTANT MODE)

```bash
USER_TOK=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"test@dmhai.local","password":"<employee password>"}' \
  http://127.0.0.1:8080/auth/login | jq -r .token)

SESSION="demo-docs-q-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$SESSION\",\"name\":\"sso q\",\"createdAt\":$(date +%s%3N),\"mode\":\"assistant\"}" \
  http://127.0.0.1:8080/sessions > /dev/null

curl -s -X POST -H "Authorization: Bearer $USER_TOK" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION\",\"content\":\"Wie konfiguriere ich SSO mit Azure AD bei der DMH SME Demo Cloud? Welche Audience-ID brauche ich, und welche Attribute werden erwartet?\"}" \
  http://127.0.0.1:8080/agent/chat
```

### 6. Read the answer + verify

```bash
sleep 25
curl -s -H "Authorization: Bearer $USER_TOK" \
  "http://127.0.0.1:8080/sessions/$SESSION" \
  | jq '.messages[-1].content'
```

Live run (2026-05-14) produced an answer that cited:

- The exact admin path **`/admin/sso`**
- The SAML 2.0 setup flow with **"Neue Verbindung anlegen"**
- The **Audience-Identifier `urn:dmh-sme-demo:saml`**
- The Entra-Admin-Center step *"Unternehmensanwendungen →
  Neue Anwendung → Eigene Anwendung erstellen"*
- The expected attributes **`email`, `name`, `group_id`**
- The diagnostics endpoint **`/admin/sso/diagnostics`**
- The **300-second clock-skew** failure cause

Every one is unique to `sso.html`. The model could not have
invented `urn:dmh-sme-demo:saml` or `/admin/sso/diagnostics`
from training. The training default for an SSO answer would be
generic ("download metadata, configure SAML in your IdP") and
would never name these specific identifiers.

Progress trace: `final_text` only — auto-fetch retrieves the
chunks before the LLM turn; the model doesn't need to invoke a
separate `fetch_index` tool for this kind of grounded query.

## Verifying freshness (optional, ~10 min wait)

To verify the BG-refresh loop end-to-end:

1. Edit one of the fixture HTML files **on disk** (the docs
   server picks up the new content immediately):
   ```bash
   sed -i 's/urn:dmh-sme-demo:saml/urn:dmh-sme-demo:saml-v2/' \
     demo/layer-0.2/fixtures/docs-site/sso.html
   ```
2. Wait `bg_refresh_min_interval_s` (default 600s = 10 min) past
   the *last `fetch_index`-triggered refresh* for that source.
3. Re-ask the SSO question. The chunk returned the FIRST time
   is still the cached one — the asynchronous refresh runs in
   parallel. The SECOND time you ask, the refresh has
   committed and the new wording (`urn:dmh-sme-demo:saml-v2`)
   appears in the answer.

Behind the scenes per `Ingest.BgRefreshWorker`:
- First query → auto-fetch returns the stale hit → enqueues a
  refresh job for the source_id.
- Worker re-fetches the page, hashes it, sees the difference,
  atomically replaces the chunks (Guarantee ii).
- Parent-child debounce: if the worker just refreshed the seed
  page, all three child sources skip until the window expires
  (the `LEFT JOIN` on `parent_source_id` covers this).
- Second query → fresh chunks.

## Verifying (acceptance checklist)

- ✅ Step 1: docs server reachable from both host and master.
- ✅ Step 3: `/index` ack returns `{"handled":true, ...}` and
  the follow-up `command_ack` reports
  `"Ich habe 4 Seiten ... indiziert"`.
- ✅ Step 4: `kb_sources` shows 4 rows; the seed has no
  `parent_source_id`, the three children point back at the
  seed.
- ✅ Step 6: answer cites `urn:dmh-sme-demo:saml`,
  `/admin/sso/diagnostics`, attributes `email name group_id`,
  300-second clock-skew. Any of those missing means the
  indexed-context block didn't reach the model — check that
  `mode: "assistant"` actually landed.

## Cleanup

```bash
# Remove the docs-site sources. source_id for URL is
# normalised(url) — fetch from list first.
curl -s -H "Authorization: Bearer $ADMIN_TOK" \
  http://127.0.0.1:8080/admin/kb-sources \
  | jq -r '.sources[] | select(.source_kind == "url") | .source_id as $id | $id' \
  | while read SID; do
      docker exec dmh_ai-master sqlite3 /data/db/chat.db \
        "SELECT source_ref FROM kb_sources WHERE source_id='$SID' \
         AND source_ref LIKE 'http://127.0.0.1:8085/%';" \
      | grep -q . && \
        curl -s -X POST -H "Authorization: Bearer $ADMIN_TOK" \
          -H "Content-Type: application/json" \
          -d "{\"source_id\":\"$SID\",\"reason\":\"end of demo\"}" \
          http://127.0.0.1:8080/admin/kb-sources/remove
    done

# Stop the docs server.
kill $(lsof -t -i:8085) 2>/dev/null
```

After cleanup, re-asking the SSO question returns a generic
SAML procedure that does NOT mention `urn:dmh-sme-demo:saml`
or any other fixture-specific identifier.

## Demoing this to a customer (human-driven, browser-based)

Same engineer-assisted pattern as demos 01 / 02, with one extra
moving part: the docs server. Start it BEFORE the customer is
in the room.

### Demoability today — the friction you can't avoid

- **`serve.py` runs on the host** outside DMH-AI. If it dies
  mid-demo the BFS fails silently. Start before the meeting,
  spot-check it (`curl http://127.0.0.1:8085/index.html`) right
  before showing the customer.
- **`/index <url>` is pasted into chat.** No admin
  "register a URL for indexing" button in the FE; the operator
  types the slash-command.
- **`mode: "assistant"` flag (Step 5)** — same as demos 01 / 02.
- **No citation chip.** Point out `urn:dmh-sme-demo:saml` and
  `/admin/sso/diagnostics` manually as proof points.
- **BG refresh is *narrated*, not *live*.** The 10-minute
  debounce window is too long for a customer meeting. Explain
  the freshness loop in words; offer a follow-up if the
  customer wants to see it end-to-end.

### Day-before staging (you, with shell access)

1. Start the docs server:
   ```bash
   python3 demo/layer-0.2/fixtures/docs-site/serve.py 8085 &
   ```
   Confirm it's up and reachable from inside master:
   ```bash
   docker exec dmh_ai-master sh -c \
     'wget -qO- --tries=1 --timeout=3 http://127.0.0.1:8085/index.html | head -1'
   ```
2. Run **Steps 2–4** of the runbook so all four pages are
   indexed.
3. Open two browser tabs at `http://127.0.0.1:8080`:
   - **Tab A** — admin.
   - **Tab B** — employee, session pre-created with
     `mode: "assistant"`.
4. Run the verification query yourself once (Step 5's second
   curl block). Confirm the reply cites `urn:dmh-sme-demo:saml`
   AND `/admin/sso/diagnostics` AND the attributes
   `email`, `name`, `group_id`.

### In the meeting (customer watches)

1. **Tab A.** Show `/admin/kb-sources` filtered to
   `source_kind=url`. Four rows visible — *"Vier Seiten unserer
   Produkt-Dokumentation, automatisch durch den Crawler vom
   Server geholt und indexiert."*
2. **Tab B.** Type into chat:
   > *"Wie konfiguriere ich SSO mit Azure AD bei der DMH SME
   > Demo Cloud? Welche Audience-ID brauche ich, und welche
   > Attribute werden erwartet?"*
3. Wait ~15–25 seconds. The agent answers with the audience
   ID, the Entra-Admin-Center steps, the expected attributes,
   the diagnostics endpoint.
4. **Point out** to the customer:
   > *"`urn:dmh-sme-demo:saml` und `/admin/sso/diagnostics`
   > stehen nur in IHRER Doku. Der Agent hat sich das nicht
   > zusammengereimt — er hat Ihre Seite gelesen."*
5. **Freshness story (narrated, not live):**
   > *"Wenn Ihre Doku-Seite morgen einen Tippfehler bekommt,
   > fetcht DMH-AI die neue Version automatisch beim nächsten
   > Mitarbeiterzugriff. Sie müssen nichts re-indexieren. Beim
   > nächsten Lesen derselben Frage zitiert der Agent den neuen
   > Wortlaut."*

### The pitch in one paragraph

> *"Produkt-Dokumentationen ändern sich ständig. Ohne ein Werkzeug
> wie DMH-AI muss Ihr Support-Team entweder die Seite live öffnen
> (zu langsam für Live-Tickets) oder das Wissen im Kopf halten
> (zu fehleranfällig bei jedem Versions-Update). Mit DMH-AI fragen
> Sie im Chat, DMH zitiert die aktuelle Version Ihrer Doku. Wenn
> die Doku sich ändert, lernt DMH die neue Version selbständig
> nach — keine manuelle Re-Ingestion."*

### Reset between demos

Run **Cleanup** (removes URL sources AND kills the docs server),
then re-run the day-before staging. ~45 seconds operator time
per customer (the URL crawl takes ~20–25 s).

## Primitives exercised

- `0.2 Pipelines.URL.run_async/3` — BFS-crawl with
  same-prefix guard, depth + page cap, content-quality gate
- `0.2 Ingest.SourceId` — URL canonicalisation (normalised
  URL is the unit of replace + remove)
- `0.2 kb_sources.parent_source_id` — seed → child back-reference,
  populated by the BFS pipeline, read by BG-refresh debounce
- `0.2 Ingest.BgRefreshWorker` — fan-out collapse via parent
  debounce: one auto-fetch turn that hits N children
  re-checks the source-tree once, not N times
- `0.2 Runtime auto-fetch (Assistant mode)` — same indexed
  augmented_facts block as demos 01 / 02; this scenario
  exercises retrieval across a multi-page corpus where the
  best chunk lives on a non-seed page
- `0.2 Web.Fetcher` + `Web.ReaderExtractor` — HTML to text,
  chrome strip, link-heavy-line drop

## Known gaps

- **`python3 -m http.server` is single-threaded** and was
  rejecting parallel BFS fetches as "connection closed". The
  `serve.py` wrapper uses `ThreadingHTTPServer` instead. Worth
  documenting prominently — a casual operator who substitutes
  `python3 -m http.server` will see "0 pages indexed"
  failures and not understand why.
- **`@min_chars_for_useful_page = 500`** in
  `Pipelines.URL` silently drops thin pages. A real
  product-docs site with marketing-style short landing pages
  may need adjustment; the threshold isn't surfaced in
  `AgentSettings` today.
- **Page-count cap visible only via the ack message.** No
  in-chat progress feedback while the BFS runs; operator polls
  the session.
- **No in-chat citation rendering.** The reply paraphrases the
  doc but doesn't surface "see sso.html" inline.
- **Async crawl + `/index` returning before completion** can
  look like the cache was empty on a too-quick follow-up
  query. Step 4's `sleep 25` is the rule of thumb for a 4-page
  fixture; larger sites need proportionally longer.
