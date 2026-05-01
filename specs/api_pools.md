# API Pools — model registry redesign

## Goal

Replace the current ad-hoc `<provider>::<local|cloud>::<model>` naming with a
pool-based registry: **`<pool>::<model>`**. A *pool* is a named bundle of
endpoint config (base URL, API format, account rotation strategy, account
list); a *model* is whatever string the upstream provider expects.

Why: the current scheme hard-codes two pools per provider (local + cloud) and
forces every code path that touches model names to special-case those literal
strings (`agent_settings.ex:147`, `llm.ex:62`, `llm.ex:69`, `llm.ex:102`,
`llm.ex:109`). Adding a third endpoint (e.g. an extra dedicated GPU box, a
managed runtime like Sagemaker, a different provider entirely) requires
threading a new tuple shape through the entire stack. Pools collapse all of
that into a single key lookup — adding an endpoint becomes a row insert, not
a code change.

## What's in / out

**In scope:**
- `pools` table + `DmhAi.LLM.Pools` module that owns reads + cache.
- `<pool>::<model>` canonical name format used in DB rows, settings JSON,
  test runner `@target_models`, FE model picker.
- Pool-scoped account rotation (replaces the global rotation in `llm.ex`).
- System Settings CRUD UI for pools.
- One-pass DB migration that rewrites every legacy `<provider>::<pool>::<model>`
  reference and drops the legacy `accounts` field from `admin_cloud_settings`.

**Out of scope:**
- New providers beyond what `req_llm` already supports.
- Runtime pool health checks / auto-failover between pools.
- Per-account quotas or budget tracking (existing `throttledUntil` logic
  carries over verbatim).

## Schema

```sql
CREATE TABLE pools (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  name             TEXT NOT NULL UNIQUE,    -- "miner", "ollama-cloud", "sagemaker"
  provider         TEXT NOT NULL,           -- "ollama" | "openai" | "anthropic" | …
  base_url         TEXT NOT NULL,           -- "http://192.168.178.49:11434" or
                                            -- "https://api.openai.com/v1"
  strategy         TEXT NOT NULL DEFAULT 'least_used',
                                            -- "least_used" | "round_robin" | "random"
  cooldown_seconds INTEGER NOT NULL DEFAULT 300,
  num_ctx          INTEGER,                 -- per-pool Ollama `options.num_ctx`
                                            -- override; NULL → don't inject
                                            -- (server default applies)
  accounts         TEXT NOT NULL DEFAULT '[]',
                                            -- JSON: [{name, api_key, throttled_until?, last_used_ts?}]
  created_ts       INTEGER NOT NULL,
  updated_ts       INTEGER NOT NULL
);
```

**Why a row table, not a JSON blob in `settings`:** pools are CRUDed
individually from the UI (add one, edit one, delete one). Encoding them as a
JSON array under one settings key forces every edit to round-trip the whole
array, races multi-tab edits, and bloats the audit story. A row table is the
correct model.

The `accounts` column stays JSON — accounts within a pool churn frequently
(new key minted, old key revoked, throttle stamps) and don't need their own
table.

## Canonical name

```
<pool>::<model>
```

- `<pool>` matches `pools.name` exactly (case-sensitive).
- `<model>` is opaque to DMH-AI — passed through to the upstream provider.
  May contain `:` (e.g. `qwen3-embedding:0.6b`), `-`, `.`, `/`.

Examples:
- `miner::qwen3-embedding:0.6b`
- `ollama-cloud::devstral-2:123b-cloud`
- `sagemaker::llama3.2:3b`

Parser: `String.split(name, "::", parts: 2)`. Any string lacking the
separator is invalid — no fallback to legacy formats.

## Resolution flow

```
request: model = "miner::qwen3-embedding:0.6b"
  ↓
Pools.resolve("miner::qwen3-embedding:0.6b")
  ↓ split on first "::"
  → pool_name = "miner", model = "qwen3-embedding:0.6b"
  ↓ Pools.fetch("miner")
  → %Pool{base_url, provider, strategy, accounts, ...}
  ↓ AccountRotation.pick(pool)
  → %Account{name, api_key}  (skips throttled, applies strategy)
  ↓
return %Resolved{
  base_url:     pool.base_url,
  provider:     pool.provider,      # drives adapter dispatch
  model:        "qwen3-embedding:0.6b",
  api_key:      account.api_key,
  account_name: account.name,       # for logging + throttle stamping
  pool_name:    "miner"             # for throttle stamping
}
```

`AccountRotation.mark_throttled(pool_name, account_name, until_ms)` updates
the JSON `accounts` array of the named pool — atomic via SQLite UPDATE on
the row.

## Wire-protocol adapters

`DmhAi.Agent.LLM` is wire-protocol-agnostic — every per-protocol concern
(endpoint URL, request body shape, outbound message normalisation,
response parsing, streaming line parser, post-stream consolidation)
is delegated to a `DmhAi.LLM.Adapter` behaviour. `DmhAi.Agent.LLM.adapter_for/1`
maps the resolved pool's `provider` field to one of:

| `provider`     | adapter                          | wire format        |
|----------------|----------------------------------|--------------------|
| `ollama`       | `DmhAi.LLM.Adapters.Ollama`      | `/api/chat` NDJSON |
| anything else  | `DmhAi.LLM.Adapters.OpenAI`      | `/v1` SSE          |

Adding a new wire protocol is a new adapter module + one clause in
`adapter_for/1`. Account rotation, retry-on-throttle, transport timing,
thinking-tag extraction, and Gemini message sanitisation stay central.

The adapter is responsible for taking the pool's `base_url` and producing
the right path. The Ollama adapter strips a trailing `/v1` from the
configured base URL before appending `/api/chat`, so existing pools
configured against `https://ollama.com/v1` (or `http://host:11434/v1`)
continue to work without operator action.

### Per-pool Ollama context window (`num_ctx`)

Ollama's `/api/chat` accepts an `options.num_ctx` field that controls
the KV-cache size when the server loads the model. The default
server-side value is **4096 tokens**, well below our system prompt
(~10K), so any local Ollama install with the stock default silently
truncates the head of every prompt — tool schemas vanish, language
hints vanish, model degrades sharply.

The `num_ctx` column on `pools` lets the operator set a per-pool
override. If set, it is injected into `options.num_ctx` on every
request through that pool. If `NULL`, nothing is injected and the
upstream server's own default applies.

| pool kind | recommended `num_ctx` |
|---|---|
| local Ollama (miner, sagemaker) | 16384 — 32768 depending on GPU VRAM |
| ollama-cloud | leave NULL (cloud loads models with their own large context already) |

For non-Ollama providers the value is ignored — only
`DmhAi.LLM.Adapters.Ollama` reads it. Operators should normally
leave it blank for OpenAI/Anthropic/Google pools.

There is **no global default fallback** in the runtime. A blank
`num_ctx` on a local pool means "use Ollama's 4K default", which
will misbehave on long prompts — operators are expected to set the
field explicitly when configuring a local pool.

### Argument format on the wire

OpenAI `/v1` rejects tool_call history when `function.arguments` is a
JSON object — it expects a JSON-encoded string. Ollama `/api/chat` is
the opposite: arguments must be a decoded object. Each adapter's
`normalize_messages/1` callback converts the runtime's stored shape
(always a decoded map, so tools and Police can read structured fields
without re-parsing) into whatever its wire protocol expects.

### Why provider, not api_format

`api_format` was the original dispatch key when every Ollama endpoint
went through the OpenAI-compat `/v1` shim. The shim does NOT honour the
`options.num_ctx` field — Ollama always loaded the model with the
default 4096-token context, silently truncating the system prompt on
every call. Switching to native `/api/chat` is the only fix; that means
dispatch must follow the *provider*, not the wire compat hint. The
`api_format` column is gone — provider alone determines the wire
protocol.

## Account rotation strategies

| Strategy | Pick rule |
|---|---|
| `least_used` | Lowest `last_used_ts` among non-throttled accounts. |
| `round_robin` | Counter persisted on the pool row (separate column `rr_cursor INTEGER DEFAULT 0`). Increment + wrap. |
| `random` | Uniform over non-throttled accounts. |

Throttled = `throttled_until` is set and `> now`. If every account is
throttled, return `{:error, :all_throttled, retry_after_ms}` — caller
surfaces to the user honestly (no silent fallback to a different pool).

## System Settings UI

New section in `/admin/settings`: **API Pools**.

- Table view: name, provider, base_url, account count.
- Per-row actions: edit, delete (delete blocked if any active model setting
  references this pool — UI shows the offending settings keys).
- Add pool: form with name, provider, base_url, strategy, cooldown_seconds,
  then an editable account list (add/remove rows).
- API key column rendered masked; show on hover or "reveal" toggle. Never
  log keys in the FE console or BE access log.

Endpoints:

```
GET    /admin/pools           → list rows (api_keys masked)
POST   /admin/pools           → create
PUT    /admin/pools/:id       → update
DELETE /admin/pools/:id       → delete (409 if referenced)
```

Auth: existing admin guard on `/admin/*` routes applies.

## Defaults seed

On first boot, if `pools` is empty, seed from an operator-managed
`pools.json` if present (lookup order in `DmhAi.DB.Init.load_pool_seeds/0`:
`$DMHAI_POOL_SEED` → `/data/pools.json` → `temp/pools.json`). When no file
is found, only one placeholder pool is inserted:

| name | provider | base_url | accounts |
|---|---|---|---|
| `ollama-cloud` | ollama | `https://ollama.com/v1` | `[]` |

`ollama-cloud` ships with zero accounts so the admin UI has a row to fill
in; no other pool is seeded by default to avoid leaking operator-specific
network topology into a fresh install.

The `/v1` suffix on Ollama base URLs is harmless — the Ollama adapter
strips it before appending `/api/chat`. Operators may write either form.

Accounts come from the JSON file when present. The seed runs once;
subsequent edits via the UI are authoritative.

## Migration

One-pass on the next boot:

1. **Rename** every model string of the form `<provider>::<old_pool>::<model>`:
   - `ollama::cloud::<m>` → `ollama-cloud::<m>`
   - `ollama::local::<m>` → `miner::<m>` (assumes the local Ollama box is the
     existing miner; if local points at a sagemaker host, manual fix)
   - Touch sites: `settings` table values for keys `confidantModel`,
     `assistantModel`, `assistantWorkerModel`, `oracleModel`,
     `extractContentModel`, `webFetchModel`, anything else in
     `agent_settings.ex` `@defaults` (lines 15–25).
2. **Drop** `accounts` field from `admin_cloud_settings` JSON — the data
   moved into `pools.accounts` per pool.
3. **Drop** legacy code paths: `to_routed/1` in `agent_settings.ex:143–150`,
   the `String.ends_with?(model, "-cloud")` check, the three-part split
   matches in `llm.ex`. Per the no-deprecation rule: delete cleanly.

No backward compatibility shim. Anything still using the old format after
migration boot is a bug.

## Touch points

The rename + parser change ripples through:

- `lib/dmh_ai/agent/agent_settings.ex` — drop `to_routed/1`, return raw
  model strings; defaults map updated to `<pool>::<model>` form.
- `lib/dmh_ai/agent/llm.ex:61–110` — replace three-part split with
  `Pools.resolve/1`; remove provider/pool branching; endpoint config comes
  from the resolved pool.
- `lib/dmh_ai/agent/llm.ex:64,104,779,813–822` — account picking/partitioning
  moves into `DmhAi.LLM.AccountRotation` (new module), keyed on pool_name.
- `test/llm/run_scenarios.exs:33–39` — `@target_models` rewritten to
  `<pool>::<model>` form.
- `js/admin-settings.js` (new section: API Pools CRUD).
- `js/manager-app.js` model picker — strings already opaque; no behavioural
  change beyond the displayed format.

## Module layout

```
lib/dmh_ai/
  llm/
    pools.ex             # pools table CRUD + cache + resolve/1
    account_rotation.ex  # pick/mark_throttled, strategy implementations
    adapter.ex           # @callback chat_endpoint_url/build_body/extract_message/
                         #            handle_stream_line/finalize_stream
    adapters/
      openai.ex          # /v1/chat/completions, SSE, fragmented tool_calls
      ollama.ex          # /api/chat, NDJSON, complete tool_calls per line,
                         # native options block (num_ctx, num_predict, …)
  handlers/
    admin_pools.ex       # /admin/pools REST endpoints
```

`Pools.resolve/1` is the only public entry from `LLM` callers — they never
read `pools.accounts` directly. Keeps the rotation logic in one place and
lets us swap strategies without touching call sites.
