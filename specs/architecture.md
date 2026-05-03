# Architecture

DMH-AI is a self-hosted AI assistant. Browser SPA on the front, an
Elixir/Plug backend over SQLite. Each chat session runs in one of two
modes:

- **Confidant** — fast synchronous Q&A. One streaming LLM call per
  user message. No tasks, no tool loop.
- **Assistant** — conversational agent that maintains a per-session
  task list and works through it turn-by-turn over a tool-calling
  chain.

The two modes share infrastructure (LLM routing, web fetch, tool
sandbox, session_progress log, i18n) but never share pipeline code —
the mode branch is taken at the HTTP handler entry and never
re-merges.

## Topology

```
Browser SPA  ──HTTPS──▶  Elixir / Bandit  ──▶  SQLite (chat.db)
                              │
                              ├──▶  Ollama / cloud LLMs
                              ├──▶  SearXNG (internal)
                              └──▶  Sandbox container (run_script)
```

## Process tree

```
Application
 ├── Repo                    SQLite via Ecto + Exqlite
 ├── SysLog                  structured trace log
 ├── Finch                   HTTP client pool (LLM + web)
 ├── Registry                UserAgent lookups
 ├── DmhAi.Agent.Supervisor  DynamicSupervisor for UserAgents
 ├── Task.Supervisor         per-turn inline tasks
 ├── DmhAi.Agent.TaskRuntime periodic-task scheduler
 └── Bandit HTTP/HTTPS
      └── DmhAi.Router (Plug.Router)
```

## UserAgent

One GenServer per authenticated user, idle-timed-out after 30 min. It
holds almost no state — the truth lives in DB. The GenServer exists
to serialise per-user turns and hold per-session in-flight bookkeeping.

```
UserAgent state:
  current_task    nil | {ref, task_pid, reply_pid, session_id, mode}
  platform_state  %{telegram: ..., ...}
  memo_key        cached per-user master memo key
```

It accepts two distinct dispatch messages, one per mode. Each routes
to its own pipeline function (`run_confidant/3` / `run_assistant/3`)
that knows nothing about the other path.

## Scheduler — `TaskRuntime`

A single GenServer that arms timers for periodic-task pickups. On
fire, it sends `{:task_due, task_id}` to the owning session
GenServer (starting it lazily if idle-timed-out). It tracks no
in-flight work — pickups land in the session mailbox and wait their
turn.

## Police

A runtime gate that runs inside `execute_tools` per individual tool
call. Where the prompt asks the model for a behaviour and the model
forgets or cheats, Police rejects the call before it runs and feeds
back a tool-result the model can read and self-correct on. Examples:
task discipline (must `create_task` / `pickup_task` before execution
tools), pivot detection (Swift classifier verdict), no-duplicate /
no-consecutive guards, path safety, probe-budget caps.

Repeated violations of any single rule trip a 3-strike escalation —
the chain is killed with a "Internal AI model error" persisted reply
plus a critical SysLog line, so degraded models surface in
operator-visible signals.

## Storage

SQLite single file (`chat.db`). Vector search uses sqlite-vec (vec0
virtual tables) loaded into the same DB so vectors live alongside
relational rows. The schema is consolidated — wipe-and-reinit on
schema changes, no `ALTER TABLE` migration chain.

Per-session filesystem layout under `<assets>/<email>/<session_id>/`:

```
data/       user uploads (POST /assets writes here)
workspace/  scratch shared across all tasks in the session
```

## Polling-based delivery

There is no SSE / WebSocket. `/agent/chat` is fire-and-forget; the
turn runs in the background on a supervised Task and all output lands
in DB tables. The FE reconciles via a single polling endpoint per
active session — `GET /sessions/:id/poll` returns deltas of new
messages, new `session_progress` rows, the partial `stream_buffer`,
and the `chain_in_flight` flag the FE uses to distinguish
"intermediate text turn" from "chain ended".

All persisted timestamps are generated at the BE. The FE never stamps
`ts` on user messages, assistant messages, `session_progress` rows,
or task rows.

## LLM routing

All calls go through `DmhAi.Agent.LLM`. Models are addressed by
canonical `<pool>::<model>` strings; `Pools.resolve/1` looks up the
endpoint config and picks an account from the pool's rotation
strategy. Adapter dispatch (Ollama `/api/chat` vs OpenAI-compat `/v1`)
is provider-driven.

The system uses six tier-shaped settings — `confidantModel`,
`assistantModel`, `swiftModel` (short/fast classifications),
`oracleModel` (long/dense compaction & summarisation), `visionModel`,
`kbEmbeddingModel` — so operators can mix-and-match capability across
the call sites.

## Outbound HTTP

A shared Finch pool serves most outbound HTTP. LLM calls
specifically opt OUT of connection reuse (`Connection: close`) and
gzip compression — both are workarounds for observed silent
multi-minute hangs against Ollama Cloud's edge.

## Sandbox

`run_script` routes through a long-lived sandbox container via
`docker exec`. The runtime tracks long-running PIDs in
`RunningTools` (ETS), polls for completion, surfaces an in-flight
marker on `/poll`, and handles cancellation (TERM → 2 s grace →
KILL). Hang-guards at three layers (per-`docker exec` timeouts,
`max_runtime_ms` cap, hard ceiling on the poll loop) ensure the
chain cannot wedge indefinitely.

## Knowledge base

A single vector index (sqlite-vec) carries two scopes:

- `knowledge` — global, shared across users; populated via `/learn`.
- `memo` — per-user, cross-session; populated via `/memo` or the
  `save_memo` tool. Encrypted at rest under a per-user MMK wrapped by
  a deployment-wide master key file kept off the DB.

Three minimal tools — `fetch_knowledge`, `fetch_memo`, `save_memo` —
expose retrieval to the model. The memo tools are dynamically gated
into the catalog only on `/memo`-prefixed turns.

## External integrations (MCP)

DMH-AI is an MCP client. `connect_mcp(url)` runs spec-compliant
discovery (PRM → ASM) and OAuth 2.1 + PKCE, persists the wrap and
tools, and attaches the service to the current anchor task. The
attached service's tool catalog merges into the model's per-turn
catalog, namespaced as `<alias>.<tool>`. Detach is automatic on task
close.

## Boot rehydration

On startup, `TaskRuntime.rehydrate/0` reverts any stuck
periodic-`ongoing` tasks to `pending`, re-arms timers for pending
periodics, and pokes any whose pickup time has already passed. The
per-user `UserAgent` boot scan also self-dispatches a resume chain
for any session whose last message is an unanswered user message —
crash-survival without ctx snapshots.
