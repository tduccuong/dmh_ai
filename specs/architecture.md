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

After the supervisor tree starts, `application.ex` runs three sequential steps:
1. `Dmhai.StartupCheck.run/0` — checks docker socket, sandbox container running + exec,
   data-path writability (FATAL), and Ollama reachability + internet from sandbox (WARN).
   Raises on any FATAL failure so the process exits immediately with a clear error.
2. `Dmhai.DB.Init.run/0` — DB schema migrations.
3. `Dmhai.DomainBlocker.load_from_db/0` — loads abuse blocklist into ETS.

---

## Module Namespaces

```
Dmhai.Agent.*     — agent runtime: UserAgent, Worker, JobRuntime, Jobs,
                    WorkerStatus, ContextEngine, LLM, Police, MasterBuffer
                    (notification bus), AgentSettings, TokenTracker,
                    ProfileExtractor, WebSearch, SystemPrompt,
                    UserAgentMessages (shared session-message writer)

Dmhai.Tools.*     — worker-facing tools: RunScript, ReadFile, WriteFile,
                    WebFetch, WebSearch, Calculator,
                    ParseDocument, ExtractContent, SpawnTask,
                    Plan, JobSignal, StepSignal, Registry

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
                        poller_loop(job_id, worker_task,
                          last_cursor=job.last_reported_status_id || 0)
                      end)
```

**Cursor initialisation:** the poller starts at `job.last_reported_status_id` (defaulting to 0 when NULL via `row_to_map`). For periodic jobs this means each new cycle's poller skips all historical rows from prior cycles — preventing old final rows from being re-processed and re-reported.

**`advance_cursor` / `advance_summary_cursor`** use `IS NULL OR < ?` so the first update after insert (column defaults NULL) is never silently skipped.

```
```

---

## Worker (one-off semantics + PROTOCOL contract)

The worker NEVER knows about periodicity. Every invocation is one-off — for periodic jobs, the runtime re-spawns a fresh worker for each cycle.

```
Worker.run(task, ctx)
   │
   ├── stored messages[0] = placeholder (per-turn prompt injected each iteration)
   │
   └── loop(messages, tools, model, ctx)
         │
         ├── drain_subtask_results   (spawn_task async results)
         ├── maybe_compact_worker_messages (rolling-summary compaction)
         │     — on compactor LLM failure, OLD MESSAGES ARE KEPT (no silent context loss)
         │
         ├── compute effective_tools  (phase-gated + adaptive selection)
         │     plan phase:       [plan] only
         │     execution phase:  all tools except job_signal; media tools
         │                       gated on context signals (@tool_scan_window)
         │     post-steps phase: [job_signal] only
         │
         ├── build_turn_prompt  (per-turn, matches phase + effective_tools)
         │     plan phase:    tool catalogue + step format rules (plain strings, fewer is better)
         │     execution:     full plan as bullet list + "You are on step [N]"
         │                    + step_signal instructions
         │     post-steps:    "All steps complete, call job_signal(JOB_DONE)"
         │
         ├── LLM.call(model, effective_messages, effective_tools)
         │     ↓
         │  ┌──{:ok, {:tool_calls, calls}}──────────────────────────┐
         │  │                                                        │
         │  │  Police.check_tool_calls                               │
         │  │    — text mimicry, repeated identical, path safety     │
         │  │    — step_signal must not be batched with other tools  │
         │  │     ↓ rejected → nudge + retry (max 3 → JOB_BLOCKED)  │
         │  │                                                        │
         │  │  execute each tool                                     │
         │  │                                                        │
         │  │  step_signal results (non-terminal):                   │
         │  │    STEP_DONE {id}      → advance current_step          │
         │  │    STEP_BLOCKED {id,r} → inject retry msg or JOB_BLOCKED│
         │  │    PLAN_REVISE  → re-validate + restart step 1  │
         │  │                                                        │
         │  │  job_signal results (terminal):                        │
         │  │    JOB_DONE / JOB_BLOCKED → exit loop                 │
         │  │                                                        │
         │  └────────────────────────────────────────────────────────┘
         │
         └──{:ok, text} (no tool call) → PROTOCOL violation
               Police.check_text → nudge ("call step_signal or job_signal!")
               after 3 nudges → synthetic JOB_BLOCKED final row
```

### PROTOCOL contract (mandatory)

**Phase 1 — Planning** (`plan_approved = false`):
Model calls `plan(steps, rationale)`. Each step is an object `{"step": "...", "tools": ["tool1"]}`. Runtime validates (step count bounds, dangerous content, tool declarations). On approval, `ctx.plan_steps` and `ctx.current_step = 1` are set. Prompt enforces: strictly 1 step when answerable from training data or requiring ≤2 tool calls; multiple steps only when step N's output is the required input to step N+1. Police hard-rejects any multi-step plan where any step has `tools: []` — a step with no tool calls is only valid as a single-step plan.

**Phase 2 — Step execution** (`plan_approved = true`, steps remaining):
For each step, model uses available tools then calls one of:
```
step_signal(status: "STEP_DONE",            id: N)
step_signal(status: "STEP_BLOCKED",         id: N, reason: "...")
step_signal(status: "PLAN_REVISE",   new_plan: [...], reason: "...")
```
`step_signal` must be the only tool call in its turn (Police enforced).

On `STEP_BLOCKED`: runtime injects "Step [N] blocked: \<reason\>. Retry step [N]." and loops. After `plan_step_max_retries` exhausted → synthetic `JOB_BLOCKED` (reason taken from last STEP_BLOCKED, no LLM call).

On `PLAN_REVISE`: same Police validation as initial plan. If approved, `ctx.plan_steps` replaced, `ctx.current_step` reset to 1.

**Phase 3 — Post-steps** (all steps done):
Only `job_signal` is callable. Model calls:
```
job_signal(status: "JOB_DONE",    result: "final report for the user")
job_signal(status: "JOB_BLOCKED", reason: "verbatim error message")
```
`result` is **required** (non-empty, non-whitespace) on JOB_DONE — the worker must compile the deliverable before signalling. The runtime passes it directly to the user; no extra LLM call is made.

If the model calls `step_signal(STEP_DONE)` on the last step instead of `job_signal`, the runtime injects a nudge ("All steps complete — compile and call job_signal now") and loops once more. **There is no implicit JOB_DONE with empty result.**

Mid-execution replans (via `plan()` or `PLAN_REVISE`) always reset `plan_steps`, `current_step` to 1, and `step_retries`.

### Synthetic finals (runtime-enforced failure modes)

Situations where the runtime writes a `kind='final'` row on the worker's behalf (so jobs never hang):

| Cause | Final signal_status | Reason text |
|-------|---------------------|-------------|
| Worker hit iter cap without job_signal | JOB_BLOCKED | `max_iter_reached` (I18n) |
| Worker returned plain text after 3 nudges | JOB_BLOCKED | `worker_refused_signal` (I18n) |
| Police: 3 consecutive rejections OR any violation type reaches 3 total | JOB_BLOCKED | `policy_violation` (I18n) |
| Step retries exhausted | JOB_BLOCKED | last STEP_BLOCKED reason (no LLM call) |
| LLM returned empty | JOB_BLOCKED | `llm_empty_response` (I18n) |
| LLM errored | JOB_BLOCKED | `llm_error` (I18n) |
| Worker OS process died without signal | JOB_BLOCKED | `worker_exited_no_signal` (I18n) |
| Job cancelled by user | JOB_BLOCKED | `job_cancelled_by_user` (I18n) |
| Orphaned 'running' on app restart | JOB_BLOCKED | `worker_orphaned` (I18n) |
| Exec error streak persists after nudge | JOB_RESTART → spawn new worker (same job_id) | runtime-generated |
| JOB_RESTART exceeds `maxWorkerRestarts` | JOB_BLOCKED | runtime-generated |

**Exec error recovery flow:**

```
exec tools all fail N times (execErrorStreakNudge, default 3)
    → inject nudge: "re-evaluate your approach"
    → reset exec_error_streak to 0, set exec_nudge_sent=true, loop

exec tools all fail N times AGAIN (nudge_sent=true)
    → emit JOB_RESTART final row
    → JobRuntime.handle_poller_outcome: restart_count < maxWorkerRestarts
        → spawn new worker (same job_id, fresh ctx)
        → increment restart_count in in-memory record
    → restart_count >= maxWorkerRestarts → JOB_BLOCKED
```

**Plan tool availability:** `plan` is only offered in the plan phase (when `plan_approved=false`). `select_tools` always excludes it from the execution phase tool set to prevent gratuitous mid-execution replanning. Use `step_signal(PLAN_REVISE)` to trigger a plan revision if the approach must change mid-execution.

---

## Poller + Progress Summariser

The per-job poller Task runs inside `TaskSupervisor` and tails `worker_status` on a polling interval `max(K, intvl_sec/M)`.

Cancel (`do_cancel_job`) kills **both** the worker task (via `WorkerSupervisor`) and the poller task (via `TaskSupervisor`). Killing only the worker left the poller running and could trigger a reschedule race.

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

Skipped entirely for periodic jobs whose `intvl_sec < jobProgressSummaryMinCycleSec` (default 1800 s) — short-cycle jobs finish too quickly for interim reports to be useful.

For all other jobs, fires when **both** thresholds are crossed (N AND T):

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
Worker calls job_signal(JOB_DONE, result: "final report…")
    │
    ▼
JobSignal.execute writes WorkerStatus row:
    kind='final', signal_status='JOB_DONE'
    │
    ▼
Poller sees final row in next poll:
    Jobs.mark_done(job_id)
    emit_final_message(job, JOB_DONE, final_row.content):
      body = "**<job_title>**\n\n<result>"   ← result compiled by the worker
      UserAgentMessages.append(session, body)
      MasterBuffer.append_notification(I18n.t("notify_done", lang, title: ...))
      MsgGateway.notify(user_id, notify_text)
    │
    ▼
Frontend polls GET /notifications?since=<ts>
    sees the new master_buffer row → reloads /sessions/:id → renders

If job.job_type == "periodic" and status ≠ "cancelled":
    Jobs.schedule_next_run(job_id, now + intvl_sec * 1000)
    Process.send_after(self(), {:run_scheduled, job_id}, intvl_sec * 1000)
    → fresh spawn via start_job on timer fire (no memory of prior cycles)
```

**JOB_BLOCKED completion:** same path; `final_row.content` is the reason string from `job_signal(JOB_BLOCKED, reason: "...")` — passed directly to `emit_final_message`. No extra LLM call.

**JOB_BLOCKED forces a progress summary first:** runtime calls `do_summarize_and_announce(job_id, force: true)` before emitting the failure banner.

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

Registered in `Dmhai.Tools.Registry` (12 tools):

| Tool | Phase available | Purpose |
|------|----------------|---------|
| `plan` | Plan phase only | Submit a step-by-step plan (1–10 steps). Runtime validates and approves. |
| `step_signal` | Execution phase only | Per-step checkpoint: `STEP_DONE`, `STEP_BLOCKED`, or `PLAN_REVISE`. Must be called alone (not batched). |
| `job_signal` | Post-steps phase only | Terminal job signal: `JOB_DONE` (requires `result`) or `JOB_BLOCKED` (requires `reason`). Ends the worker loop. |
| `run_script` | Execution | Write and run a complete Linux shell script in one call. Use for HTTP requests (curl/wget), system queries, file ops, scripting. `cwd = ctx.workspace_dir` |
| `read_file` / `write_file` | Execution | File ops under `<session_root>/`. Paths resolve via `Dmhai.Util.Path.resolve/2` |
| `web_search` | Execution | Live search through SearXNG. **EXPENSIVE** — only for live data. |
| `web_fetch` | Execution | CMP-aware URL fetch (see §Web Fetch) |
| `calculator` | Execution | Safe math eval (arithmetic, trig, log, complex; constants: pi, e) |
| `parse_document` | Execution (context-gated) | Parse document files (.pdf, .docx, etc.). Only included when task/messages contain document signals. |
| `extract_content` | Execution (context-gated) | Unified extractor. Accepts a `path` (file on disk) or `data` (base64). Routes by extension: images → ImageMagick + LLM; video → ffmpeg frames + LLM; documents → pdftotext/pandoc/direct read. Returns two sections: `## Description` + `## Verbatim Content`. Only included when task/messages contain media/attachment signals. |
| `spawn_task` | Execution | Async bash; result arrives as `{:subtask_result, output}` in a later iteration |

**Phase gating** is enforced via `effective_tools` computed each turn — the model physically cannot call tools outside the current phase.

**Removed tools:** `signal` (replaced by `step_signal` + `job_signal`), `list_dir` (run_script ls covers it), `datetime` (static UTC in prompt header), `describe_image` / `describe_video` (unified into `extract_content`).

Deleted in prior refactors: `declare_periodic`, `midjob_notify` (replaced by runtime scheduler + summariser).

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

1. **Explicit-path read tools** (`read_file`, `parse_document`, `extract_content`): allowed if the resolved path does **not** start with `/data/` (system paths inside the sandbox) or if it falls within `session_root` under `/data/`. Rejected if it targets another user's or session's tree under `/data/`.
2. **Explicit-path write tools** (`write_file`): must stay within `workspace_dir` (`/data/user_assets/<email>/<session_id>/assistant/jobs/<job_id>/`).
3. **Shell tools** (`run_script`): absolute paths in the command are scanned; those under `/data/` must be within `session_root`. Deletion targets (`rm` / `rmdir` / `unlink`) must be within `workspace_dir`.

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

inject_rolling_summary + build_turn_prompt (both transient, not stored):
    [system ← per-turn prompt (phase + step context)]
    ++ [user "[Prior work summary]\n…"]   ← only when rolling_summary is set
    ++ [asst "Understood, continuing from prior work."]
    ++ rest_of_messages
```

---

## Internationalisation

**LLM-generated content** (worker output, progress summaries, job titles, acks) is produced in the user's language via explicit prompt injection. The Assistant detects and supplies `language` (ISO 639-1) on every handoff; it is stored on the jobs row and threaded into:

- Worker per-turn prompt (`build_turn_prompt` injects language rule each iteration).
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

1. **Text mimicry** — model writes `[used: run_script(...)]` as plain text instead of calling the tool. Rejected with a nudge.
2. **Repeated identical tool calls** — same name + args as a prior iteration, excluding `@repeatable_tools` (`spawn_task`). `step_signal` STEP_BLOCKED and PLAN_REVISE are also exempt (retry semantics), but STEP_DONE repeats are caught as loop bugs.
3. **Path safety** — reads allowed anywhere outside `/data/` (sandbox system paths) or within own `session_root`; writes confined to `workspace_dir`; shell deletions confined to `workspace_dir`.
4. **Plan step tools** — in a multi-step plan every step must declare at least one execution tool (`tools: [...]`). A step with `tools: []` is only valid in a single-step plan (pure knowledge answer). Hard-rejected with a specific instruction to collapse to 1 step.
5. **Signal batching** — both `step_signal` and `job_signal` must each be the only tool call in their turn. Batching either with other tools is rejected.
6. **job_done_missing_result** — `job_signal(JOB_DONE)` must carry a non-empty, non-whitespace `result` field.

On rejection, injects `"REJECTED (<reason>): Fix this specific violation before continuing."` — the specific reason is always included so the model knows exactly what to fix.

**Two independent kill switches** in `handle_rejection`:

1. `consecutive_rejections` (in ctx) — fires after 3 *consecutive* violations with no successful non-plan tool call in between. Plan-only calls do **not** reset this counter (replanning after a violation is not progress).
2. `violation_counts` (per-type map, never resets) — tracks total violations per Police category (`text_mimicry`, `repeated_identical_tool_calls`, `path_violation`, `step_signal_batched`, `job_signal_batched`, `job_done_missing_result`, etc.). When any single category reaches 3 total violations, forces synthetic JOB_BLOCKED immediately.

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
| `planMinSteps` / `planMaxSteps` | 1 / 10 | Plan step count bounds (Police.check_plan); 1 step is valid for simple jobs |
| `planStepMaxRetries` | 3 | Max STEP_BLOCKED retries before forcing JOB_BLOCKED |
| `masterCompactTurnThreshold` | 90 | Master compaction turn count trigger |
| `masterCompactFraction` | 0.45 | Master compaction char-budget fraction |
| `jobPollMinIntervalSec` | 5 | K — poller interval floor |
| `jobPollSamplesPerCycle` | 10 | M — target samples per periodic cycle |
| `jobOrphanTimeoutSec` | 300 | Orphan detection window |
| `execErrorStreakNudge` | 3 | Consecutive exec-tool failures before nudging the model |
| `maxWorkerRestarts` | 2 | Max automatic worker restarts per job before permanent block |
| `jobProgressSummaryEveryNRows` | 6 | Summariser row-count trigger (N gate) |
| `jobProgressSummaryMinIntervalSec` | 30 | Minimum seconds between summaries (T gate in N AND T algorithm) |
| `jobProgressSummaryMinCycleSec` | 1800 | Periodic jobs with intvl_sec below this skip interim summaries entirely |

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

### Confidant path (inline session attachments)

Client pre-processes before the `/agent/chat` call:

```
Image: resize to 1568px, 100px thumb, upload original to /assets → background describe
       base64-encoded inline in the chat request (images[])
Video: frame count from backend setting (8 cloud / 16 local × quality mult);
       client extracts evenly-spaced JPEG frames + uploads full video;
       base64 frames sent inline; background describe via video_descriptions table
```

### Assistant path (job attachments)

Client does **not** pre-digest media for the worker — the worker calls tools instead.
Three parallel operations happen before the `/agent/chat` call fires:

```
FE: GET /reserve-job-id
        ← {job_id}  (12-char base64url, pre-allocated)

then in parallel:
  (1) POST /assets                ← save originals at data/ for permanent user access
  (2) POST /upload-job-attachment ← save scaled copies at workspace/<name>
        fields: file (binary), sessionId, jobId
        writes to: job_workspace_dir(email, session_id, "assistant", job_id)/<safe_name>
  (3) POST /agent/chat            ← fires with jobId + attachmentNames in body

UserAgent.handle_handoff_to_worker:
  if command.job_id + command.attachment_names present:
    wait_for_attachments(workspace, names)  ← polls up to 30s
    build_attachment_section(names)
      → "[Attached files — use extract_content on these paths as needed]\n- workspace/<name>\n..."
    appended to job_spec so the worker knows what files are available
  else:
    describe_command_media(...)  ← Confidant-style inline description (fallback)
```

The `extract_content` tool is the worker's primary entry point for understanding
attachment content. For the Confidant fallback path (`describe_command_media`),
it is called with base64 `data` instead of a `path`; only the `## Description`
section is injected into the session context (Verbatim Content is discarded).
For video, all frames are sent in a single LLM call (not one call per frame).

---

## Deployment

```
docker-compose up
    │
    ├── dmh_ai-master container (image: dmh-ai)
    │     FROM elixir:1.18-alpine
    │     apk add: ffmpeg imagemagick poppler-utils pandoc docker-cli
    │     mix release → /app
    │     Bandit :8080 (HTTP), :8443 (HTTPS self-signed)
    │
    ├── dmh_ai-assistant-sandbox container (image: dmh-ai-sandbox)
    │     FROM alpine:3 + bash curl wget python3 jq git nodejs npm
    │     Stays running permanently; run_script tool routes commands here via docker exec
    │
    └── dmh_ai-searxng container (internal, not exposed)
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

Coverage (16 worker-loop + 21 job-runtime + others, ~120 total):

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
