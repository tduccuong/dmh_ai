# Vector Knowledge Base

## Goal

Persistent semantic memory the assistant retrieves at-will via three minimal
tools:

- `fetch_knowledge(q)` — global, shared across all users. Technical
  knowledge / API quirks / internal-domain facts learned via `/learn`.
- `fetch_memo(q)` — per-user, cross-session. Personal notes the user
  saved via `/memo`. Available in the catalog **only on turns whose
  user message starts with `/memo`**.
- `save_memo(text)` — counterpart to `fetch_memo`. Same dynamic gating.

Storage is **sqlite-vec** (SQLite extension, in-process, native KNN
indexing). Ingestion is owned by `specs/commands.md` (the `/learn`
runtime command); retrieval and storage shape live here.

## What's in / out

**In scope:**
- sqlite-vec virtual table for vector storage + native KNN search.
- `DmhAi.VectorDB.Backend` behaviour (one production impl: `SqliteVec`;
  one test impl: `Memory`).
- Storage layout for global + user-scoped chunks.
- Embedding pipeline using `miner::qwen3-embedding:0.6b` (1024-dim).
- Recursive chunker (paragraph → line → sentence → word) with
  token-budgeted output.
- Auto-tagger (3–10 free-form tags per source, single LLM call at ingest).
- Semantic-merge for inline-text `/learn` (avoid fragmenting sources
  whose content overlaps an existing one).
- Auto-relearn — every `fetch_knowledge` queues background re-fetch of
  the top-K hit sources, deduped + concurrency-capped.
- `fetch_knowledge`, `fetch_memo`, `save_memo` tools.
- Knowledge Seeds — pre-loaded curated URLs for popular platforms,
  surfaced in admin UI for one-click batch-learning.
- AgentSettings keys for chunk size, overlap, top-N, merge threshold.

**Out of scope:**
- Slash-command runtime (`/learn`, `/memo` prefix detection) — owned by
  `specs/commands.md`.
- Crawl / extract source pipelines — owned by `specs/commands.md`.
- LanceDB or any other vector store. The Backend abstraction means a
  future swap is contained, but it's not on the roadmap — sqlite-vec
  scales comfortably to multi-million chunks with native HNSW.
- Hierarchical organisation. Tags carry the categorisation use case;
  vector similarity carries retrieval relevance.

## Storage backend: sqlite-vec

[sqlite-vec](https://github.com/asg017/sqlite-vec) is a SQLite
extension (~1MB, MIT, actively maintained) that adds first-class
vector types and native KNN search. Loaded into our existing SQLite DB
via `SELECT load_extension('vec0')`; vectors live alongside relational
data.

Why this choice:
- **Embedded, in-process.** No new daemon, no separate file format, no
  Rustler NIF.
- **Native KNN.** `vec0` virtual tables expose `MATCH` syntax for
  cosine / L2 / dot-product top-K with optional metadata filters.
- **Scale.** Brute-force at small N; HNSW indexing landed late 2024
  and is a single CREATE INDEX away. Comfortable to multi-million
  rows.
- **Fits the homelab/personal-deploy posture** of this project.

The `DmhAi.VectorDB.Backend` behaviour exists for testability — a
`Memory` implementation backs unit tests so the suite doesn't need
sqlite-vec loaded.

## Module layout

```
lib/dmh_ai/
  vector_db/
    backend.ex          # behaviour
    sqlite_vec.ex       # production impl — vec0 virtual tables
    memory.ex           # test impl — ETS
    chunker.ex          # recursive splitter
    embedder.ex         # /v1/embeddings client
    tagger.ex           # auto-tagger (oracleModel call at ingest)
    sources.ex          # kb_sources accessor
    seeds.ex            # kb_seeds accessor
    pipeline.ex         # chunk → embed → tag → merge-or-insert
    relearn.ex          # background relearn supervisor + dedup
  tools/
    fetch_knowledge.ex
    fetch_memo.ex
    save_memo.ex
  handlers/
    admin_seeds.ex      # /admin/knowledge-seeds CRUD + run
```

## Storage layout

Three relational tables + one vec0 virtual table per scope.

### `kb_sources` — registry of every ingest

```sql
CREATE TABLE kb_sources (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  scope        TEXT NOT NULL CHECK (scope IN ('knowledge', 'memo')),
  user_id      TEXT,                     -- NULL for scope='knowledge'
  source_kind  TEXT NOT NULL,            -- 'text' | 'file' | 'url' | 'folder'
  source_ref   TEXT NOT NULL,            -- URL, path, or sha256 of inline text
  title        TEXT,
  raw_text     TEXT,                     -- last-known body; kept for relearn / re-embed
  centroid     BLOB,                     -- averaged embedding (float32 LE) for merge-similarity check
  tags         TEXT,                     -- JSON array of strings, max 10
  indexed_at   INTEGER NOT NULL,
  UNIQUE(scope, user_id, source_ref)
);
```

`centroid` is the per-source averaged embedding — used by the
inline-text merge-similarity check (see "Semantic merge"). Stored as
packed float32 LE (4 bytes × `kb_embedding_dim`).

### `kb_chunks_meta` — non-vector chunk metadata

```sql
CREATE TABLE kb_chunks_meta (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  scope        TEXT NOT NULL,
  user_id      TEXT,
  source_id    INTEGER NOT NULL REFERENCES kb_sources(id) ON DELETE CASCADE,
  chunk_idx    INTEGER NOT NULL,
  chunk_text   TEXT NOT NULL,
  indexed_at   INTEGER NOT NULL
);
CREATE INDEX idx_kb_chunks_meta_source ON kb_chunks_meta (source_id);
CREATE INDEX idx_kb_chunks_meta_scope  ON kb_chunks_meta (scope, user_id);
```

The vector lives in vec0; the rowid links the two tables.

### `kb_vec_knowledge`, `kb_vec_memo` — the vector indexes

```sql
CREATE VIRTUAL TABLE kb_vec_knowledge USING vec0(
  embedding float[1024]
);

CREATE VIRTUAL TABLE kb_vec_memo USING vec0(
  embedding float[1024]
);
```

`vec0` rows are addressed by the same `id` as `kb_chunks_meta` (1:1
correspondence; insert into both atomically). Search:

```sql
SELECT meta.id, meta.chunk_text, meta.source_id, vec.distance
FROM   kb_vec_knowledge vec
JOIN   kb_chunks_meta meta ON meta.id = vec.rowid
WHERE  vec.embedding MATCH :q AND k = 8
ORDER  BY vec.distance;
```

Memo search adds `WHERE meta.user_id = :uid` — strictly user-scoped at
the SQL level; tool implementation never accepts `user_id` from the
model.

### `kb_seeds` — admin pre-loaded URLs

```sql
CREATE TABLE kb_seeds (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  url           TEXT NOT NULL UNIQUE,
  label         TEXT,
  tags          TEXT,                    -- JSON array; pre-populated from priv/kb_seeds/preloaded.json
  last_run_at   INTEGER,
  last_status   TEXT,                    -- 'ok' | 'error'
  last_error    TEXT,
  created_at    INTEGER NOT NULL
);
```

On admin first visit to /admin/knowledge-seeds, the BE merges
`priv/kb_seeds/preloaded.json` rows into this table (insert-only, never
overwrite admin edits). "Run" invokes the same URL-crawl pipeline
`/learn <url>` uses — idempotent by construction (re-crawling
overwrites existing chunks for any source_ref already in `kb_sources`).

### `kb_relearn_jobs` — dedup table for background re-fetch

```sql
CREATE TABLE kb_relearn_jobs (
  source_ref   TEXT PRIMARY KEY,
  source_kind  TEXT NOT NULL,
  enqueued_at  INTEGER NOT NULL
);
```

`INSERT OR IGNORE` keyed on `source_ref` → concurrent fetches of the
same source enqueue once. Row is deleted on completion (success OR
failure). Bounded concurrency in the supervisor (`DmhAi.VectorDB.Relearn`).

## Chunking

Recursive splitter. Levels in order: paragraph (`\n\n`) → line (`\n`)
→ sentence (`. `) → word (whitespace). Last resort: hard-cut on token
boundaries with codepoint-safe trimming.

`greedy_pack` fills to `kb_chunk_tokens`, emits, then seeds the next
chunk with the trailing parts whose summed tokens fit in
`kb_chunk_overlap_tokens`. Forward-progress guarantee: when seed +
next part still overflows, drop seed and start fresh.

Token counting is the BPE-byte heuristic (`div(byte_size, 4)`) — fast,
cheap, accurate enough for chunking decisions. Real tokenisation can
swap in later without changing call sites.

| Setting | Default | Purpose |
|---|---|---|
| `kb_chunk_tokens` | 400 | Target chunk size. |
| `kb_chunk_overlap_tokens` | 60 | Overlap (15%) for cross-boundary context. |

## Embedding

Single function: `Embedder.embed_batch(texts) -> [embedding]`. Resolves
`AgentSettings.kb_embedding_model()` (default `miner::qwen3-embedding:0.6b`)
via `Pools.resolve/1`, POSTs OpenAI-shape `/embeddings`, batches at
`kb_embedding_batch_size`. Throttle-aware (re-resolves on 429 to pick
the next account).

Dimension assertion on every response: each vector's length must
equal `kb_embedding_dim` (1024). Mismatch hard-errors — the
embedding model on the upstream changed silently and would corrupt
the index.

## Auto-tagger

One LLM call per source at ingest. Uses the cheap `oracleModel`
(`ministral-3:14b-cloud` default) — adds latency in the order of
hundreds of milliseconds, runs in the background relative to the
user's chat acknowledgement.

```
Tagger.tag(text) -> ["bitrix24", "webhook", "oauth"]
```

Prompt: a one-shot instruction asking for 3–10 free-form lowercase
labels (platform names, technical concepts, document type), as a JSON
array. Cap enforced post-hoc — if the model returns 12, we keep the
first 10. Cap enforced in the prompt too as a hint.

Tags are per-source, not per-chunk. They describe the document's
subject, queryable in admin UI for filter / cleanup / scoped relearn.

`fetch_knowledge` does NOT expose `tags` to the model — keeps the tool
schema minimal. Tags are runtime infrastructure, not LLM-driven
filters. Future precision improvement may pass tags.

## Pipeline (chunk → embed → tag → merge-or-insert)

```
Pipeline.ingest(attrs, body) ->
  chunks    = Chunker.split(body)
  embeds    = Embedder.embed_batch(chunks)
  centroid  = average(embeds)
  tags      = Tagger.tag(body)

  # Inline-text only: try semantic merge against existing centroids
  source_ref =
    if attrs.source_kind == "text" do
      case nearest_centroid(scope, user_id, centroid, kb_text_merge_threshold) do
        {:ok, existing} ->
          tags = Enum.uniq(existing.tags ++ tags) |> Enum.take(10)
          existing.source_ref       # MERGE
        :no_match ->
          attrs.source_ref          # NEW (sha256 of body)
      end
    else
      attrs.source_ref              # url/file/folder: deterministic ref
    end

  # Replace any existing chunks for this source_ref
  delete_chunks(scope, user_id, source_ref)
  upsert_source(attrs ++ {centroid, tags, source_ref})
  insert_chunks(...)
```

For URL/file/folder sources, the merge step is skipped — `source_ref`
is the URL/path, deterministic. Re-ingesting the same URL/path
trivially overwrites.

`kb_text_merge_threshold` default = 0.92. High enough that distinct
topics don't accidentally merge; low enough that "same content with
edits / typos / additions" merges into one source. Configurable.

## Tools

All three have **deliberately minimal schemas** — single string
parameter, terse description — to keep per-turn token cost low.

### `fetch_knowledge`

```
fetch_knowledge(q: string) -> [{text, source, score}, ...]
```

Description: *"Look up technical knowledge previously taught via
/learn. Use for API specifics, internal domain facts, learned
techniques."*

Globally available — appears in every Assistant turn's catalog.

Execution: embed `q`, KNN top-N (`kb_top_n`, default 8), return
chunks with their `source_kind:source_ref` rendering.

**Side effect**: enqueue background relearn for each hit's source_ref
(see "Auto-relearn" below).

### `fetch_memo`

```
fetch_memo(q: string) -> [{text, source, score}, ...]
```

Description: *"Look up things you saved about this user via /memo.
Personal preferences, account references, project context."*

**Dynamically gated** — the runtime injects this tool into the catalog
**only** on turns whose user message starts with `/memo`. Zero token
cost on normal turns. Strictly user-scoped: `user_id` comes from
execution context, never from the model. Cross-user memo leakage is
impossible by construction.

### `save_memo`

```
save_memo(text: string) -> {ok: true}
```

Description: *"Save a personal fact the user has stated for later
recall. Use only when the user is making a STATEMENT (\"my X is Y\"),
never on questions."*

Same dynamic gating as `fetch_memo`. On call: chunks the text, embeds,
inserts under (`scope=memo, user_id=ctx.user_id`).

The model decides between `save_memo` and `fetch_memo` per turn based
on user intent. Ambiguous → ask one clarifying question and end the
chain (per the prompt fragment in `commands.md`).

## Auto-relearn

Every `fetch_knowledge` returns top-K hits, then **in parallel** the
runtime enqueues a relearn job for each unique hit `source_ref`:

1. `INSERT OR IGNORE INTO kb_relearn_jobs (source_ref, ...)` — concurrent
   users hitting the same source enqueue once.
2. `DmhAi.VectorDB.Relearn` (DynamicSupervisor) picks up jobs from the
   table; concurrency capped at `kb_relearn_concurrency` (default 4).
3. For each job: re-fetch the source (URL: re-crawl that single page;
   file: re-extract; folder-member: re-extract that file) and re-run
   `Pipeline.ingest`. Idempotent.
4. Row deleted on completion (success or failure — failures retry on
   the next user query that hits the same source).

**Skipped:** `source_kind == "text"` (inline text — no upstream to
re-fetch). Tags are union-merged on relearn (`existing ++ new |>
take(10)`).

**Granularity:** per individual page / file. A 200-page Confluence
crawl created 200 `kb_sources` rows; a hit on one of them triggers
relearn of THAT page only — never the whole crawl.

## Knowledge Seeds

Sugar over `/learn <url>` with a curated starter list. Path:

1. `priv/kb_seeds/preloaded.json` ships in the repo with curated URLs
   for: Bitrix24, Salesforce, Zoho, Odoo, Google Workspace, Microsoft
   Graph. Each entry: `{url, label, tags}`.
2. On admin first visit to `/admin/knowledge-seeds`, the BE merges the
   JSON into `kb_seeds` (insert-only — never overwrite admin edits).
3. Admin UI: list view, add/remove rows, "Run" per row, "Run all".
   Run = invoke `/learn <url>` pipeline with the row's tags pre-applied.

Idempotent by construction: re-running a seed re-crawls and overwrites
existing chunks for matching `source_ref`s. No "did this run before?"
state to manage.

Seeds always feed the global `:knowledge` scope (admin-only feature →
shared knowledge for all users).

## Settings

| Key | Default | Purpose |
|---|---|---|
| `kb_embedding_model` | `miner::qwen3-embedding:0.6b` | Pool::model for embedding. Changing requires reindex. |
| `kb_embedding_dim` | 1024 | Vector dimension. Locked once vec0 tables exist. |
| `kb_embedding_batch_size` | 32 | Texts per /embeddings request. |
| `kb_chunk_tokens` | 400 | Target chunk size. |
| `kb_chunk_overlap_tokens` | 60 | Cross-chunk overlap. |
| `kb_top_n` | 8 | Default top-N for fetch_*. |
| `kb_text_merge_threshold` | 0.92 | Centroid cosine threshold for inline-text merge. |
| `kb_relearn_concurrency` | 4 | Background relearn supervisor cap. |
| `kb_tagger_model` | (uses `oracleModel`) | Override if you want a dedicated tag model. |

## Failure modes

| Failure | Behaviour |
|---|---|
| Embedding HTTP 5xx | Exponential backoff with cap (3 retries). Final failure surfaces with the offending input identifier. |
| Embedding dim mismatch | Hard error — vec0 tables would be corrupted. Operator action required. |
| Tagger fails / returns malformed JSON | Insert with empty tags. Log warning. Ingest succeeds. |
| Merge: existing source has no centroid | Skip merge, treat as new source. (Can happen for legacy rows; centroid is populated on first relearn.) |
| Search: 0 hits | Tool returns `[]`. Model handles gracefully. |
| Relearn: source no longer reachable (404, file deleted) | Delete the source's chunks + sources row. Log info. |

## Settings UI surface

System Settings → "Knowledge Base":
- Stats: total chunks (global / per current user), embedding model, dim.
- Buttons: Drop user memos (per-user nuke), Drop global knowledge (admin only).
- Read-only display of chunk tuning settings.

A separate top-level admin nav item — "Knowledge Seeds" — owns the
seed CRUD + Run UI.

## Backend swap path

If sqlite-vec ever proves a scale ceiling (e.g. >10M chunks), the
`DmhAi.VectorDB.Backend` behaviour means a swap to LanceDB or any
other vector DB is contained: implement the four-method behaviour,
flip `:vector_db_backend` config. `kb_sources.raw_text` keeps a
re-buildable corpus, so the migration only pays the embedding-recompute
cost — no data loss.
