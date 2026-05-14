# Layer 0.2 — Document ingestion (demo scenarios)

These runbooks exercise Primitive 0.2 (the ingest pipelines,
`/index` slash command, runtime auto-fetch of indexed context on
every Assistant turn, BG refresh, and admin KB management
endpoints) against three DACH SME stories.
All scenarios assume the **single-tenant on-prem install** (one
org, one admin, several employees). Cross-org behaviour is
covered by F34 / F35 in the test suite, not here.

## Scenarios

Listed in coverage order — smallest primitive surface first, each
subsequent scenario adds one new primitive class. Work them in
order for the first stage walkthrough; the number prefix in each
filename mirrors this ordering.

| # | File | One-line description | Adds primitive |
|---|---|---|---|
| 01 | [`01_kb_handbook.md`](01_kb_handbook.md) | Employee handbook self-service — admin uploads a PDF, every employee asks HR questions in chat. | `Pipelines.File` + `FetchIndex` |
| 02 | [`02_kb_sop_folder.md`](02_kb_sop_folder.md) | Operations SOP self-service — admin places a folder of SOPs; on-call ops queries at 3am. | adds `Pipelines.Folder` (walker, recursion, async dispatch) |
| 03 | [`03_kb_docs_site.md`](03_kb_docs_site.md) | Live product docs Q&A — admin indexes a URL, support team queries; BG refresh keeps content fresh. | adds `Pipelines.URL` (BFS), `Web.Fetcher`, `Web.ReaderExtractor`, `BgRefreshWorker` |

## Common pre-requisites (apply to every scenario in this folder)

- Running DMH-AI stage or production instance reachable via HTTP.
- An admin user can log in (created during fresh-install via the
  first-user superuser path).
- For scenarios needing a non-admin "employee" viewer: at least one
  additional user exists in the same org (admin invites via the
  Manage Users overlay).

## Where to look when something breaks

| Symptom | First place to look |
|---|---|
| `/index` returns "permission denied" | User isn't admin in their org — `Permissions.can?(:administer, :org_settings)` is the gate (0.1 primitive). |
| `/index <url>` reports `0 pages indexed (N failed)` | URL pipeline's `Pipelines.URL.@min_chars_for_useful_page = 500` rejects pages whose extracted text is below the threshold. Marketing-style short landing pages or sites without an `<article>` / `<main>` density target get silently dropped. Verify the page renders ≥ 500 chars of body text after chrome-strip. |
| `/index <url>` BFS crawls only the seed | If you self-host the test site with stdlib `python3 -m http.server`, it's single-threaded and rejects parallel BFS fetches as `connection closed`. Use `demo/layer-0.2/fixtures/docs-site/serve.py` (ThreadingHTTPServer) or any production-grade server. |
| `/index <path>` returns "File is empty or contains no readable text" | The file body after whitespace strip is shorter than `AgentSettings.min_extracted_text_chars` (default 50). |
| Employee asks an org-specific question and gets a generic training-default answer | The session was created without `mode: "assistant"`, so the runtime did NOT auto-fetch indexed context. Confirm: `docker exec dmh_ai-master sqlite3 /data/db/chat.db "SELECT mode FROM sessions WHERE id='<sid>';"` should print `assistant`. |
| Cross-user retrieval works when it shouldn't | F35 should be failing too — file a bug; org scoping is broken at the primitive level, not a runbook problem. |

## Cleanup

Every scenario has its own Cleanup section that removes only the
sources it ingested. If you've run all three back-to-back and
want a clean KB, sweep everything under `/admin/kb-sources`:

```bash
curl -s -H "Authorization: Bearer <admin-token>" \
     http://127.0.0.1:8080/admin/kb-sources \
  | jq -r '.sources[].source_id' \
  | while read SID; do
      curl -s -X POST -H "Authorization: Bearer <admin-token>" \
           -H "Content-Type: application/json" \
           -d "{\"source_id\":\"$SID\",\"reason\":\"cleanup after demo\"}" \
           http://127.0.0.1:8080/admin/kb-sources/remove
    done
```
