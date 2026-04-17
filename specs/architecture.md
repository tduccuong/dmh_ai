# DMH-AI Architecture

## Overview

DMH-AI is a self-hosted AI assistant. Users chat with it through a browser SPA. The backend classifies each message into a **job** (simple one-off answer, complex one-off worker task, or periodic worker task) and routes it accordingly. All long-running work is tracked in the `jobs` table; the runtime owns scheduling, polling, summarising, and completion — the agent code is stateless end-to-end.

---

## System Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                          Browser (SPA)                          │
│  HTML + Vanilla JS  ·  no build step  ·  served as static files │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTPS :8443 / HTTP :8080
                    ┌──────────▼──────────┐
                    │   Elixir / Plug     │  ← primary backend
                    │   Bandit HTTP/TLS   │
                    │   :8080 / :8443     │
                    └──┬──────────────┬───┘
                       │              │
          ┌────────────▼───┐   ┌──────▼──────────┐
          │  SQLite DB     │   │  Ollama          │
          │  chat.db       │   │  :11434 (local)  │
          │  /data/db/     │   │  or cloud proxy  │
          └────────────────┘   └─────────────────-┘
```

Docker Compose mounts `/data` as a named volume (`dmh-ai-data`).

---

## Backend Process Tree

```
Application
 ├── Repo                        (SQLite via Ecto + Exqlite)
 ├── SysLog                      (GenServer — structured trace log)
 ├── DomainBlocker               (scanner/abuse blocklist)
 ├── Finch                       (HTTP client pool — LLM + web-fetch)
 ├── Registry  (Dmhai.Agent.Registry) — UserAgent lookups
 ├── Dmhai.Agent.Supervisor      (DynamicSupervisor for UserAgents)
 ├── Task.Supervisor  (Dmhai.Agent.TaskSupervisor)   — inline tasks
 ├── Task.Supervisor  (Dmhai.Agent.WorkerSupervisor) — detached workers
 ├── Dmhai.Agent.JobRuntime      (GenServer — owns all jobs)
 ├── Bandit HTTP  :8080          (optional)
 └── Bandit HTTPS :8443          (optional; requires /app/ssl/cert.pem)
      └── Dmhai.Router (Plug.Router)
```

---

## Module Namespaces

```
Dmhai.Agent.*     — agent runtime: UserAgent, Worker, JobRuntime, Jobs,
                    WorkerStatus, ContextEngine, LLM, Police, MasterBuffer
                    (notification bus), AgentSettings, TokenTracker,
                    ProfileExtractor, WebSearch, SystemPrompt,
                    UserAgentMessages (shared session-message writer)

Dmhai.Tools.*     — worker-facing tools: Bash, ReadFile, WriteFile, ListDir,
                    WebFetch, WebSearch, Calculator, DatetimeTool,
                    DescribeImage, DescribeVideo, ParseDocument,
                    SpawnTask, Signal, Registry

Dmhai.Web.*       — web-fetch subsystem (see §Web Fetch):
                    CmpDetector, ConsentSeeder, ReaderExtractor,
                    Fallback, Fetcher

Dmhai.Util.*      — cross-concern helpers: Html (text extraction),
                    Url (parse/normalise/variants), Path (session-scoped path
                    resolution + traversal defence)

Dmhai.Constants   — single source of truth for filesystem paths
                    (assets_dir, session_root, session_data_dir,
                    session_origin_root, job_workspace_dir, sanitize)

Dmhai.I18n        — plain-dict translation module (en/vi/es/fr/ja)

Dmhai.Handlers.*  — HTTP request handlers
Dmhai.Plugs.*     — Plug pipelines
Dmhai.Schemas.*   — Ecto schemas
Dmhai.Adapters.*  — external integrations (Telegram etc.)
```

---

## Classification → Job Flow

Every user message routes through the Assistant classifier. The Assistant's sole job is to emit exactly one tool call. No direct replies.

```
Browser
   │
   │  POST /agent/chat
   ▼
UserAgent (GenServer, per user)
   │
   │  run_assistant  ──►  Assistant LLM.stream(tools: [
   │                         handoff_to_resolver,
   │                         handoff_to_worker,
   │                         set_periodic_for_job,
   │                         cancel_job,
   │                         read_job_status
   │                      ])
   │
   ▼
Three classification outcomes:

  ┌───────────────────────┬───────────────────────┬────────────────────────┐
  │ SIMPLE ONE-OFF        │ COMPLEX ONE-OFF       │ PERIODIC               │
  │                       │                       │                        │
  │ handoff_to_resolver   │ handoff_to_worker     │ handoff_to_worker      │
  │ (job_title, language) │ (job_title, task,     │ (..., intvl_sec > 0)   │
  │                       │  ack, language,       │                        │
  │                       │  intvl_sec=0)         │                        │
  │                       │                       │                        │
  │ INSERT jobs row:      │ INSERT jobs row:      │ INSERT jobs row:       │
  │   job_type=one_off    │   job_type=one_off    │   job_type=periodic    │
  │   intvl_sec=0         │   intvl_sec=0         │   intvl_sec=N          │
  │                       │                       │                        │
  │ ▼                     │ ▼                     │ ▼                      │
  │ Confidant pipeline    │ JobRuntime.start_job  │ JobRuntime.start_job   │
  │ (forward_and_capture  │                       │                        │
  │  streams chunks to UI │                       │                        │
  │  AND updates jobs.    │                       │                        │
  │  job_result on :done) │                       │                        │
  └───────────────────────┴───────────────────────┴────────────────────────┘
```

The Assistant is required to supply `language` (ISO 639-1) on every handoff — detected from the user's message. This propagates to the worker system prompt, summariser prompt, and fixed-label lookups.

---

## Job Lifecycle

`Dmhai.Agent.JobRuntime` is a single named GenServer that owns every job. It holds an in-memory map of running jobs plus a map of pending periodic reschedule timers. All long-running work is tracked in the `jobs` table.

```
jobs.job_status lifecycle:

  pending  ──► running  ──► done       (signal(JOB_DONE))
                     │
                     ├──► blocked      (signal(BLOCKED) | synthetic)
                     │         │
                     │         └── if periodic: schedule next_run_at
                     │             ↓
                     └──► cancelled    (Assistant calls cancel_job)
                              │
                              └── periodic runs are NOT rescheduled
```

Per-job components started by `JobRuntime.start_job(job_id)`:

```
start_job(job_id)
    │
    ├── Jobs.mark_running(job_id, worker_id)
    │
    ├── worker_task = Task.Supervisor.async_nolink(WorkerSupervisor, fn ->
    │                   Worker.run(job.job_spec, %{
    │                     user_id, session_id, worker_id, job_id,
    │                     description: job.job_title,
    │                     language: job.language
    │                   })
    │                 end)
    │
    └── poller_task = Task.Supervisor.async_nolink(TaskSupervisor, fn ->
                        poller_loop(job_id, worker_task, last_cursor=0)
                      end)
```

---

## Worker (one-off semantics + PROTOCOL contract)

The worker NEVER knows about periodicity. Every invocation is one-off — for periodic jobs, the runtime re-spawns a fresh worker for each cycle.

```
Worker.run(task, ctx)
   │
   ├── system prompt = build_system_prompt(ctx.language)
   │     (language interpolated — model told explicitly, not inferred)
   │
   └── loop(messages, tools, model, ctx)
         │
         ├── drain_subtask_results   (spawn_task async results)
         ├── maybe_compact_worker_messages (rolling-summary compaction)
         │     — on compactor LLM failure, OLD MESSAGES ARE KEPT so no
         │       silent context loss (fix #6).
         │
         ├── LLM.call(model, messages, tools)
         │     ↓
         │  ┌──{:ok, {:tool_calls, calls}}──┐
         │  │                               │
         │  │  Police.check_tool_calls       │   {rejected} → nudge + retry
         │  │     ↓                          │   (max 3 → synthetic BLOCKED)
         │  │  WorkerStatus.append(tool_call)│
         │  │  execute each tool              │
         │  │  WorkerStatus.append(tool_result)│
         │  │                                │
         │  │  if 'signal' tool succeeded:    │
         │  │     Signal.execute writes        │
         │  │     kind='final' row             │
         │  │     → exit loop                  │
         │  │                                 │
         │  │  else loop(…new_messages)       │
         │  └──────────────────────────────┘
         │
         └──{:ok, text} (no tool call) → PROTOCOL violation
               Police.check_text → nudge ("call signal!")
               after 3 nudges → synthetic BLOCKED final row
```

### PROTOCOL contract (mandatory)

Every job MUST end with a `signal` call:

```
signal(status: "JOB_DONE", result: <markdown answer>)
  — or —
signal(status: "BLOCKED", reason: <verbatim error>)
```

The `Signal` tool validates args, writes `kind='final'` to `worker_status`, and returns `{:ok, _}`. The worker loop detects the successful signal and exits with `{:ok, {:signal, STATUS, PAYLOAD}}`.

### Synthetic finals (runtime-enforced failure modes)

Situations where the runtime writes a `kind='final'` row on the worker's behalf (so jobs never hang):

| Cause | Final signal_status | Reason text (via I18n) |
|-------|---------------------|------------------------|
| Worker hit iter cap without signal | BLOCKED | `max_iter_reached` |
| Worker returned plain text after 3 nudges | BLOCKED | `worker_refused_signal` |
| Police: 3 consecutive rejections | BLOCKED | `policy_violation` |
| LLM returned empty | BLOCKED | `llm_empty_response` |
| LLM errored | BLOCKED | `llm_error` |
| Worker OS process died without signal | BLOCKED | `worker_exited_no_signal` |
| Job cancelled by user | BLOCKED | `job_cancelled_by_user` |
| Orphaned 'running' on app restart | BLOCKED | `worker_orphaned` |

---

## Poller + Progress Summariser

The per-job poller Task runs inside `TaskSupervisor` and tails `worker_status` on a polling interval `max(K, intvl_sec/M)`.

```
poller_loop(job_id, worker_task, last_cursor):
    loop:
      job = Jobs.get(job_id)
      case job.job_status:
        "cancelled" →
          safe_shutdown_worker(worker_task)
          WorkerStatus.append(kind='final', signal=BLOCKED,
                              content=I18n.t("job_cancelled_by_user", job.language))
          {:poller_done, job_id, {:cancelled, _}}

        _ →
          new_rows = WorkerStatus.fetch_since(job_id, last_cursor)
          Jobs.advance_cursor(job_id, max(id))

          maybe_announce_progress(job)   ← unsolicited mid-job summary
                                            (see below)

          case {final_row(new_rows), worker_dead?(worker_task)}:
            {final, _}         → finalize_job(job, final); {:poller_done, ...}
            {nil, true}        → (peek again; else synth BLOCKED)
            _                  → sleep(interval_ms); loop
```

### Mid-job progress summariser (delta-only)

Fires when two thresholds are crossed:

1. New non-summary rows since `last_summarized_status_id` ≥ `jobProgressSummaryEveryNRows` (default 6).
2. Seconds since `last_summarized_at` ≥ `jobProgressSummaryMinIntervalSec` (default 30).

Also fires **synchronously** when the user asks "how's job X going?" — the Assistant routes that to `read_job_status`, which calls `JobRuntime.summarize_and_announce(job_id, force: true)`.

```
summarize_and_announce(job_id, force: bool):
    ETS mutex per-job (@summarizer_locks):
      if lock is held by another process:
        force=true  → {:skipped, I18n.t("summary_already_being_prepared", lang)}
        force=false → :ok (no-op)

    with mutex held:
      rows = WorkerStatus.fetch_since(cursor)  -- excludes progress_summary rows
      if rows == [] and not force: :ok
      if rows == [] and force:
         write I18n.t("no_new_activity", lang, %{title: ...})

      else:
         LLM.call(summarizer_model, prompt:
            "Short (1-3 sentences) update, describe ONLY this slice. " <>
            "Write in language '#{lang}'.")

         WorkerStatus.append(kind='progress_summary', content=<summary>)
         UserAgentMessages.append(session, %{role: assistant,
                                             kind: 'progress', job_id, content})
         MasterBuffer.append_notification(session, I18n.t("notify_progress", …))
         Jobs.advance_summary_cursor(job_id, max_id)
```

Delta-only: prior progress_summary rows are **excluded** from the summariser's input to prevent recursive summary drift.

---

## Completion Flow

```
Worker calls signal(JOB_DONE, result=markdown_answer)
    │
    ▼
Signal.execute writes WorkerStatus row:
    kind='final', signal_status='JOB_DONE', content=<result>
    │
    ▼
Poller sees final row in next poll:
    Jobs.mark_done(job_id, result)
    emit_final_message(job, JOB_DONE, result):
      body = "**<job_title>**\n\n<result>"           ← LLM-produced, already in user's lang
      UserAgentMessages.append(session, body)        ← to sessions.messages
      MasterBuffer.append_notification(I18n.t("notify_done", lang, title: ...))
      MsgGateway.notify(user_id, notify_text)        ← external push
    │
    ▼
Frontend polls GET /notifications?since=<ts>
    sees the new master_buffer row → reloads /sessions/:id → renders

If job.job_type == "periodic" and status ≠ "cancelled":
    Jobs.schedule_next_run(job_id, now + intvl_sec * 1000)
    Process.send_after(self(), {:run_scheduled, job_id}, intvl_sec * 1000)
    → fresh spawn via start_job on timer fire (no memory of prior cycles)
```

BLOCKED completion uses the same path; the body uses a red-span HTML
prefix + `I18n.t("blocked_label", lang, reason: ...)`.

---

## Boot Rehydration

On `JobRuntime.init`, after a 500ms delay (allows supervisor tree to stabilise):

```
do_rehydrate:
  orphans = Jobs.fetch_orphaned()    -- rows with status='running' but no in-memory worker
  for each orphan:
     emit synthetic BLOCKED final + session message (I18n'd)
     Jobs.mark_blocked(...)

  due = Jobs.fetch_due_periodic()    -- periodic + next_run_at <= now
  for each due: start_job(job_id)
```

Disabled in `:test` env via `:dmhai, :enable_job_rehydrate, false`.

---

## UserAgent (slim)

One GenServer per authenticated user, idle-timed-out after 30 min. Post-refactor it holds very little state — JobRuntime owns all job/worker tracking.

```
UserAgent state:
  current_task:    nil | {ref, reply_pid}  ← one inline dispatched command
  platform_state:  %{telegram: %{...}, ...}
```

It dispatches inline commands (Assistant classification + Confidant pipeline) under `TaskSupervisor`. It is *not* in the worker lifecycle path any more — JobRuntime talks to the workers directly.

---

## Confidant / Resolver Pipeline

Invoked by `handle_handoff_to_resolver`. Runs the same legacy streaming pipeline (web search → LLM stream) but wrapped so the final text is captured into `jobs.job_result` alongside streaming to the UI.

```
handle_handoff_to_resolver(calls, command, state, session_data, combined_buffer):
    title = from Assistant arg
    language = from Assistant arg (normalised to ISO 639-1)

    INSERT jobs { job_type=one_off, status='running', language, ... }

    Task.start(fn ->
      forwarder = spawn forward_and_capture(original_reply_pid, job_id)
      run_confidant(command | reply_pid = forwarder, state, session_data, buffer)
    end)

forward_and_capture loop:
    receive :chunk → forward + accumulate
    receive :done  → forward + Jobs.mark_done(job_id, full_text)
    receive :error → forward + Jobs.mark_blocked(job_id, reason)
```

---

## Worker Tool Set

Registered in `Dmhai.Tools.Registry`:

| Tool | Purpose |
|------|---------|
| `bash` | Shell command (sync). `cwd = ctx.workspace_dir` |
| `read_file` / `write_file` / `list_dir` | File ops under `<session_root>/`. Paths resolve via `Dmhai.Util.Path.resolve/2` |
| `web_search` | Live search through SearXNG |
| `web_fetch` | CMP-aware URL fetch (see §Web Fetch) |
| `calculator` | Safe math eval |
| `datetime` | Current date/time |
| `describe_image` / `describe_video` / `parse_document` | Media/doc understanding (paths via SafePath) |
| `spawn_task` | Async bash with optional delay; result arrives as `{:subtask_result, output}` in a later iteration |
| `signal` | **Terminal contract**. Every job MUST end with this. |

Deleted in the refactor: `declare_periodic`, `midjob_notify` (replaced by the runtime's scheduler + summariser).

---

## Filesystem Layout (user assets)

All paths are derived from `Dmhai.Constants` — the single source of truth. Emails are used as-is; session ids and job ids are sanitised via `Constants.sanitize/1` (alphanumerics + dash + underscore only).

```
/data/user_assets/<email>/<session_id>/
  ├── data/                           ← user uploads (POST /assets writes here;
  │                                      GET /assets serves from here)
  ├── assistant/jobs/<job_id>/        ← scratch for jobs originating in
  │                                      Assistant-mode sessions
  │                                      (web fetches, temp files, bash output)
  └── confidant/jobs/<job_id>/        ← scratch for jobs originating in
                                         Confidant-mode sessions (empty skeleton
                                         by default — Confidant-mode direct
                                         streaming does not create jobs today)
```

**`origin` vs `pipeline` (two orthogonal job attributes on the jobs row):**

- `origin` ∈ {`assistant`, `confidant`}: the session's `mode` when the job was created. **Drives filesystem subdir.** An Assistant-mode session dispatching a resolver job gets `.../assistant/jobs/<id>/`, *not* confidant.
- `pipeline` ∈ {`assistant`, `confidant`}: the execution path. `handoff_to_resolver` → `confidant`; `handoff_to_worker` → `assistant`. **Drives runtime behaviour** (which LLM path runs the job).

### `Dmhai.Constants` helpers

```elixir
Constants.assets_dir()                             # "/data/user_assets"
Constants.sanitize("foo/bar")                      # "foo_bar"
Constants.session_root(email, sid)                 # <assets>/<email>/<sid>
Constants.session_data_dir(email, sid)             # <session_root>/data
Constants.session_origin_root(email, sid, origin)  # <session_root>/<origin>/jobs
Constants.job_workspace_dir(email, sid, origin, job_id)  # <origin_root>/<job_id>
```

### Worker ctx carries the relevant paths

`JobRuntime.spawn_worker_task` computes and mkdirs paths before launching the worker, then threads them in ctx:

```elixir
ctx = %{
  user_id:       job.user_id,
  user_email:    <looked-up>,
  session_id:    job.session_id,
  worker_id:     ...,
  job_id:        job.job_id,
  description:   job.job_title,
  language:      job.language,
  origin:        job.origin,                 # "assistant" | "confidant"
  pipeline:      job.pipeline,               # "assistant" | "confidant"
  session_root:  <.../<email>/<sid>>,
  data_dir:      <session_root>/data,
  workspace_dir: <session_root>/<origin>/jobs/<job_id>
}
```

### Tool path resolution — `Dmhai.Util.Path.resolve/2`

Rules applied to any user-supplied path inside a tool call:

| Input path prefix | Resolves under |
|-------------------|----------------|
| `data/` or `/data/` | `ctx.data_dir` |
| `workspace/` or `/workspace/` | `ctx.workspace_dir` |
| `/absolute/...` | as-is, then validated to be inside `session_root` |
| relative (bare) | anchored to `ctx.workspace_dir` (fallback: `session_root`) |

Any path that escapes `session_root` after `Path.expand` → `{:error, "Access denied: path escapes the session root"}`. Defeats `../` traversal.

### Police path-safety rule

`Dmhai.Agent.Police.check_tool_calls/3` (ctx arg is new) adds a **path violation** check alongside text mimicry + repeated identical calls:

1. **Explicit-path tools** (`read_file`, `write_file`, `list_dir`, `describe_image`, `describe_video`, `parse_document`): the `path` arg is resolved via `Util.Path.resolve/2`; rejection if it escapes `session_root`.
2. **Shell tools** (`bash`, `spawn_task`): the `command` arg is scanned for `rm` / `rmdir` / `unlink` / `del`; the operand(s) must stay inside `ctx.workspace_dir`. Heuristic — not airtight (`eval` / variable expansion can evade), catches common cases.

If ctx doesn't carry `session_root` (non-worker callers), path checks are skipped.

---

## Web Fetch (CMP-aware)

`Dmhai.Tools.WebFetch` is a thin wrapper over `Dmhai.Web.Fetcher`. The subsystem is split into focused modules:

```
Web.Fetcher          ← orchestrator
  │
  ├── ConsentSeeder   ← Cookie header (dismissed flags) + UA + DNT + GPC
  ├── CmpDetector     ← detect OneTrust, Sourcepoint, Didomi, Quantcast,
  │                     Cookiebot, Usercentrics, TrustArc, Google CMP,
  │                     raw TCF v2, generic cookie-wall classes;
  │                     ALSO detects bot challenges (Datadome, Cloudflare,
  │                     Akamai Bot Manager, PerimeterX, hCaptcha)
  ├── ReaderExtractor ← Readability-style: <article>/<main>/[role=main]/
  │                     [itemprop=articleBody] then density scoring
  └── Fallback        ← AMP variants (/amp/, /amp, .amp, ?output=amp,
                        m.*, amp.*) + archive.today/Wayback
```

Fetch flow:

```
Fetcher.fetch(url)
    │
    ├── HTTP GET with ConsentSeeder.request_headers
    ├── CmpDetector.detect(body)
    │    │
    │    ├── :clean  → ReaderExtractor.extract / fallback to Util.Html.html_to_text
    │    │            → {:ok, %{url, final_url, title, content, source: :direct,
    │    │                      cmp: nil, tried: [url]}}
    │    │
    │    └── {:cmp, vendor} → walk Fallback.all_variants(url):
    │             first clean response → {:ok, %{…, source: :amp_or_mirror
    │                                              | :archive_today | :wayback,
    │                                              cmp: vendor}}
    │             all fail → {:error, {:cmp_wall, url, cmp: vendor, tried: [...]}}
    │
    └── test seam: `http_fn: fn url, headers -> {:ok, %{status, body, final_url}} end`
                   defaults to Req.get
```

Empirical hit rate (from real-site tests): BBC / NYT / Guardian / Wikipedia direct; Reuters / Le Monde hit unbypassable walls and surface structured errors so the worker can fall back to `web_search` snippets.

---

## Context Engine (Master / Confidant)

Builds the message list for every Master LLM call. Handles session-level compaction.

```
build_messages(session_data, opts):
    system prompt (persona + profile + media descriptions)
    [summary prefix]       ← if compacted: user/asst pair with "[Summary]"
    recent history          (messages after cutoff)
    [relevant snippets]     (top-4 keyword-matched old messages)
    [buffer context]        (Assistant only: active job list)
    current user message    (+ images + files + web_context)

Compaction triggers: recent_turns > 90 OR recent_chars > 45% budget.
compact! calls LLM, writes {"summary", "summary_up_to_index"} to sessions.context.
Old messages stay in DB (used for keyword snippet retrieval).

Compactor model: AgentSettings.compactor_model() (NOT hardcoded).
```

## Worker Context Compaction (rolling summary)

Workers maintain their own message list. When it grows beyond `1 + N + M + 5` (defaults N=8, M=6), old messages are folded into a rolling summary stored in `ctx.rolling_summary`.

**Key guarantee (fix #6):** if the compactor LLM fails to produce a valid summary, the spillover messages are **retained** rather than silently dropped — no context loss. Next iteration retries.

```
maybe_compact_worker_messages:
    if total_msgs ≤ 1 + N + M + 5  → no-op

    split: [system] ++ old ++ middle ++ recent
    case update_rolling_summary(old, ctx.rolling_summary):
      {:ok, new} → messages = [system] ++ stub(middle) ++ recent
                   ctx      = %{ctx | rolling_summary: new}
      :failed    → leave messages intact (no loss)

inject_rolling_summary (transient, not stored):
    [system] ++ [user "[Prior work summary]\n…"]
             ++ [asst "Understood, continuing from prior work."]
             ++ rest_of_messages
```

---

## Internationalisation

**LLM-generated content** (worker output, progress summaries, job titles, acks, signal payloads) is produced in the user's language via explicit prompt injection. The Assistant detects and supplies `language` (ISO 639-1) on every handoff; it is stored on the jobs row and threaded into:

- Worker system prompt (`Worker.build_system_prompt(language)`).
- Summariser prompt (explicit "write in `<lang>`" instruction).
- Confidant pipeline (existing language-rule in prompt).

**Runtime-generated labels** use the `Dmhai.I18n` module — a plain-dict lookup with interpolation:

```
I18n.t("blocked_label", job.language, %{reason: "..."})
  → "Bị chặn: ..."   (vi)
  → "Bloqueado: ..." (es)
  → "Blocked: ..."   (en fallback)
```

Shipped locales: `en`, `vi`, `es`, `fr`, `ja`. Fallback chain: `lang → en → raw key`. For unsupported user languages, fixed labels fall back to English while LLM-generated content is still in the user's language (graceful degradation).

---

## Police (worker behaviour enforcement)

Guards against bad model behaviour inside the worker loop:

1. **Text mimicry** — model writes `[used: bash(...)]` as plain text instead of calling the tool. Rejected with a nudge.
2. **Repeated identical tool calls** — same name + args as a prior iteration, excluding `@repeatable_tools` (`spawn_task`, `datetime`). Indicates infinite loop. Rejected.

On rejection, injects `"REJECTED: You VIOLATED the rules..."` user message and loops. After 3 consecutive rejections, emits a synthetic BLOCKED final.

Known limitation (open task #7): `consecutive_rejections` is `ctx`-only and resets on any successful tool call, so a model that drifts + recovers + drifts indefinitely doesn't trip the cap.

---

## Database Schema

```
sessions
  id TEXT PK          ← timestamp-based (Date.now().toString())
  user_id TEXT
  name TEXT
  model TEXT          ← legacy (admin settings drive actual model choice)
  messages TEXT       ← JSON array of {role, content, thinking?, ts, images?, kind?, job_id?}
  context TEXT        ← JSON {"summary": ..., "summary_up_to_index": N}
  mode TEXT           ← 'confidant' | 'assistant'
  created_at / updated_at

users
  id, email UNIQUE, name, password_hash, role, profile, password_changed,
  deleted, created_at

auth_tokens
  token PK, user_id, created_at

jobs                  ← system of record for all long-running work
  job_id TEXT PK
  user_id / session_id
  job_type TEXT       ← 'one_off' | 'periodic'
  intvl_sec INT       ← 0 for one_off
  job_title TEXT      ← 2-6 words, in user's language
  job_spec TEXT       ← full task brief, in user's language
  job_status TEXT     ← 'pending' | 'running' | 'done' | 'blocked' | 'cancelled'
  job_result TEXT     ← final Markdown answer (or BLOCKED reason)
  language TEXT       ← ISO 639-1 (default 'en')
  pipeline TEXT       ← 'assistant' | 'confidant' — execution path (worker vs resolver)
  origin TEXT         ← 'assistant' | 'confidant' — session mode at job creation.
                        Drives filesystem subdir (<session_root>/<origin>/jobs/<job_id>)
  created_at / updated_at
  last_run_started_at / last_run_completed_at
  next_run_at                 ← for periodic scheduling
  last_reported_status_id     ← poller progress cursor
  last_summarized_status_id   ← summariser cursor (delta-only)
  last_summarized_at          ← rate-limit anchor
  current_worker_id           ← active worker id (cleared on terminal)

worker_status         ← per-iteration progress rows
  id INTEGER PK AUTOINCREMENT
  job_id / worker_id
  kind TEXT           ← 'thinking' | 'tool_call' | 'tool_result' | 'progress_summary' | 'final' | 'error'
  content TEXT        ← truncated to 4k chars
  signal_status TEXT  ← 'JOB_DONE' | 'BLOCKED' (only for kind='final')
  ts INTEGER

master_buffer         ← notification bus (sentinel rows for frontend polling)
  id INTEGER PK AUTOINCREMENT
  session_id / user_id
  content TEXT        ← unused post-refactor (always empty)
  summary TEXT        ← short notification text ("✓ Daily report", "🔴 X — blocked")
  consumed INTEGER    ← always 1; legacy column
  worker_id TEXT      ← legacy, unused post-refactor
  created_at

session_token_stats   — per-session master rx/tx token counters
worker_token_stats    — per-worker rx/tx token counters (PK session+worker)
image_descriptions    — (session_id, file_id, name, description, created_at)
video_descriptions    — same shape
user_fact_counts      — profile extractor keyword tracker
settings              — admin settings KV store
blocked_domains       — scanner/abuse domain blocklist
```

The `worker_state` table was dropped in the refactor (`DROP TABLE IF EXISTS worker_state` migration). The `master_buffer.worker_id` column is left dormant for compatibility.

---

## Assistant Tool Schemas

| Tool | Required args | Purpose |
|------|--------------|---------|
| `handoff_to_resolver` | `job_title`, `language` | Route simple one-off to Confidant pipeline |
| `handoff_to_worker` | `job_title`, `task`, `ack`, `language` (+ optional `intvl_sec`) | Spawn worker for one-off or periodic task |
| `set_periodic_for_job` | `job_id`, `intvl_sec`, `ack` | Convert a running job to periodic (or change its interval) |
| `cancel_job` | `job_id`, `ack` | Cancel running/scheduled job |
| `read_job_status` | `job_id` | Show terminal result directly OR fire summariser for running jobs |

---

## LLM Routing

All calls go through `Dmhai.Agent.LLM`. Model strings: `<provider>::<pool>::<model>`:

```
"ollama::local::llama3.2:3b"
"ollama::cloud::gemini-3-flash-preview:cloud"
"openai::default::gpt-4o"
"anthropic::default::claude-3-5-sonnet"
```

Models ending in `:cloud` / `-cloud` auto-route to cloud pool. Cloud keys managed in admin settings as a per-provider pool; `LLM` picks one per call, shuffles active keys first, then throttled ones. 5xx responses are retried 3× with 2s backoff on the same account before rotating.

### Model assignments (admin-configurable)

| Role | Default |
|------|---------|
| Confidant Master | `gemini-3-flash-preview:cloud` |
| Assistant Master | `ministral-3:14b-cloud` |
| Worker Agent | `qwen3-coder-next:cloud` |
| Context Compactor | `gemini-3-flash-preview:cloud` |
| Progress Summariser | `gemini-3-flash-preview:cloud` |
| Web Search Detector | `ministral-3:14b-cloud` |
| Image Describer | `gemini-3-flash-preview:cloud` |
| Video Describer | `gemini-3-flash-preview:cloud` |
| Profile Extractor | `gemini-3-flash-preview:cloud` |

### Other settings (admin-configurable)

| Key | Default | Purpose |
|-----|---------|---------|
| `workerMaxIter` | 20 | Hard cap on worker iterations |
| `workerContextN` / `workerContextM` | 8 / 6 | Rolling-summary stub tier + recent tier |
| `maxToolResultChars` | 8000 | Truncation threshold for tool results fed back to worker |
| `spawnTaskTimeoutSecs` | 30 | Bash command timeout inside spawn_task |
| `masterCompactTurnThreshold` | 90 | Master compaction turn count trigger |
| `masterCompactFraction` | 0.45 | Master compaction char-budget fraction |
| `jobPollMinIntervalSec` | 5 | K — poller interval floor |
| `jobPollSamplesPerCycle` | 10 | M — target samples per periodic cycle |
| `jobOrphanTimeoutSec` | 300 | Orphan detection window |
| `jobProgressSummaryEveryNRows` | 6 | Summariser row-count trigger |
| `jobProgressSummaryMinIntervalSec` | 30 | Summariser rate limit |

---

## Frontend Architecture

Plain JS, no framework / bundler.

```
index.html
 ├── core.js          — i18n (en/vi/de/es/fr), apiFetch, syslog
 ├── constants.js
 ├── stopwords.js
 ├── api.js           — SessionStore, Image/VideoDescriptionStore
 ├── profile.js       — Settings, UserProfile, UserFactTracker
 ├── ui.js            — Modal, Lightbox, SettingsModal
 ├── manager-app.js   — session list, mode switcher, session CRUD, token-stats modal
 ├── manager-chat.js  — renderChat, renderSessions
 ├── manager-search.js— sendMessage streaming logic
 └── main.js          — bootstrap, event wiring, notification polling
```

### Session modes

Each session has `mode = 'confidant' | 'assistant'` (legacy column). The sidebar filters by mode. In Assistant mode the chat now shows job-progress turns (assistant messages with `kind: "progress"` and a `job_id` field) alongside regular replies.

### Notification polling

```
setInterval:
  GET /notifications?since=<last_ts>
  → [{id, session_id, summary, created_at}, …]
  → toast / reload session
  interval: configurable in user settings
```

The backend returns rows from `master_buffer` with non-null `summary`. Post-refactor these are all sentinel rows written by `JobRuntime.emit_final_message` and `append_progress_to_session`.

---

## Request Lifecycle

```
HTTP request
    │
    ├── BlockScanners plug    — drop known scanner UAs
    ├── SecurityHeaders plug  — CSP, HSTS
    ├── Plug.Static           — /app/static
    ├── RateLimit plug        — per-IP sliding window
    │
    └── Router
          ├── public     — /auth/login, /api/* (Ollama proxy), /search
          └── auth      — AuthPlug.get_auth_user (cookie token → users)
                          ↓
                       Handler
```

Auth: `POST /auth/login` → bcrypt → httpOnly cookie. `/auth/me` for session restore. Admin role gates `/admin/*` routes.

---

## Media Pipeline

Images/videos pre-processed client-side:

```
Image: resize to 1568px, 100px thumb, upload original → background describe
Video: frame count from backend setting (8 cloud / 16 local × quality mult);
       client extracts evenly-spaced JPEG frames + uploads full video;
       background describe via video_descriptions table
```

---

## Deployment

```
docker-compose up
    │
    ├── dmh-ai container
    │     FROM elixir:1.18-alpine
    │     apk add: ffmpeg imagemagick poppler-utils pandoc  ← for media/doc tools
    │     mix release → /app
    │     Bandit :8080 (HTTP), :8443 (HTTPS self-signed)
    │
    └── searxng container (internal, not exposed)
```

Volume `/data`:
- `/data/db/chat.db` — SQLite
- `/data/user_assets/<email>/<session_id>/data/` — user uploads (see §Filesystem Layout)
- `/data/user_assets/<email>/<session_id>/<origin>/jobs/<job_id>/` — job scratch
- `/data/system_logs/system.log` — SysLog traces

---

## Testing

Test files are `test/itgr_*.exs`. Harness in `test/test_helper.exs` provides:

- `T.stub_llm_call/1` + `T.stub_llm_stream/1` — replace LLM calls with deterministic stubs.
- `T.tool_call/3` — build a normalised tool-call map matching `LLM.normalize_tool_calls` output.
- `T.session_data/1` — build a session fixture.

Coverage (112 tests total at last count):

| Area | File |
|------|------|
| Worker loop (signal, protocol violations, compaction) | `itgr_worker_loop.exs` |
| Job runtime (Jobs/WorkerStatus/Signal/JobRuntime end-to-end + mutex) | `itgr_job_runtime.exs` |
| Context/compaction (master + worker) | `itgr_compaction.exs` |
| Confidant pipeline | `itgr_confidant_flow.exs` |
| Context engine message building | `itgr_context_engine.exs` |
| Tool capability (real LLM, network-gated) | `itgr_tool_capability.exs` |
| i18n (translation coverage, language propagation) | `itgr_i18n.exs` |
| Web fetch (CMP detection, reader, fallback, real sites under `:network` tag) | `itgr_web_fetch.exs` |

Test env (`config/test.exs`):
- `enable_job_rehydrate: false` — disables boot rehydration during tests.
- `job_poll_override_ms: 100` — tight poll cadence so JobRuntime tests finish in seconds.
- HTTP/HTTPS listeners off.

Run filters:
- Default: `mix test` skips `:network`-tagged tests.
- Full: `mix test --include network` hits real sites (BBC, Reuters, Guardian, NYT, Le Monde, Wikipedia).
