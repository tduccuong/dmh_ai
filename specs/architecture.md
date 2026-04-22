# DMH-AI Architecture

> **⚠ In-flight rearchitecture (2026-04-21, #101):** Assistant mode is
> collapsing into a **single conversational session loop**. The prior
> two-stage pipeline (Classifier LLM → Assistant Loop LLM with
> PLAN → EXEC → SIGNAL protocol) is being replaced by one LLM per session
> that sees the conversation + a `[Task list]` context block and decides
> turn-by-turn what to do — just like a modern chat agent. This removes
> the plan/exec/signal protocol, the Police signal rules, the
> `Dmhai.Agent.AssistantLoop` module, the `plan` / `step_signal` /
> `task_signal` tools, and the fork-on-adjust scaffolding
> (`predecessor_task_id` / `superseded_by_task_id` / `'superseded'` status).
>
> **Key model in the target architecture:**
>   - Tasks are lightweight rows in `tasks` table: `task_type` (one_off |
>     periodic), `intvl_sec`, `task_title`, `task_spec` (description),
>     `task_status` (pending | ongoing | paused | done | cancelled),
>     `task_result`, `time_to_pickup`, `language`.
>   - The assistant uses `create_task` / `update_task` tools to manage the
>     list, and the full tool catalogue (`web_fetch`, `run_script`, etc.) to
>     execute work.
>   - `Tasks.mark_done/2` auto-reschedules periodics: `task_type="periodic"`
>     → `status="pending"`, `time_to_pickup=now+intvl_sec`.
>   - Scheduling is best-effort: a tiny `TaskRuntime` arms timers for
>     `time_to_pickup` and, on fire, sends `{:task_due, task_id}` to the
>     session GenServer (starting it if idle-timed-out). If the session is
>     busy with another turn, the pickup waits its turn in the mailbox.
>   - No parallel tasks per session: one ordered stream. User wants
>     independence → new chat session (multiple sessions per user run in
>     parallel at the user-agent level).
>   - No fork-on-adjust: if the user redirects a running task, the
>     assistant naturally updates the task description or status via
>     `update_task` in its next turn.
>
> **What survives intact from prior phases:**
>   - `job` → `task` rename (Phase 1)
>   - Per-session workspace layout (`<session>/data/` + `<session>/workspace/`, #91)
>   - Strict Confidant / Assistant path separation at HTTP handler entry
>     (#92a) — Confidant is unchanged; Assistant's internal pipeline is what
>     #101 simplifies
>   - Attachment-path injection via 📎 prefix on user messages (#92a)
>   - `session_progress` table + `/sessions/:id/progress` endpoint (#90) —
>     still the FE's activity-log source
>   - Event-driven lifecycle (#96): no poller; task completion is an
>     in-session LLM tool call, not a process-level signal

## Overview

DMH-AI is a self-hosted AI assistant. Users chat with it through a browser
SPA. Each session runs one of two modes:

- **Confidant** — fast synchronous Q&A. One streaming LLM call per user
  message. No tasks, no scheduler, no background work. The friendly
  close-companion surface.
- **Assistant** — conversational agent that maintains a **task list** for
  the session and works through it turn-by-turn. One LLM per session
  handles dispatch, classification, and execution as a single
  conversation. Tasks can be `one_off` (done once) or `periodic` (the
  runtime reschedules each cycle). All tasks belonging to a session run
  sequentially in that session — no per-session parallelism.

Shared utilities (LLM routing, web fetch, tool sandbox, path resolution,
session_progress log, i18n) are common to both modes; the pipelines don't
cross above that level.

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
 ├── Task.Supervisor  (Dmhai.Agent.TaskSupervisor)          — inline session turns
 ├── Dmhai.Agent.TaskRuntime      (GenServer — periodic scheduler only)
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
Dmhai.Agent.*     — agent runtime: UserAgent, TaskRuntime (periodic
                    scheduler), Tasks, SessionProgress, ContextEngine, LLM,
                    Police (path-safety only), AgentSettings, TokenTracker,
                    ProfileExtractor, WebSearch, SystemPrompt,
                    UserAgentMessages (shared session-message writer)

Dmhai.Tools.*     — assistant-callable tools: RunScript, ReadFile, WriteFile,
                    WebFetch, WebSearch, Calculator,
                    ParseDocument, ExtractContent, SpawnTask,
                    CreateTask, UpdateTask, Registry

Dmhai.Web.*       — web-fetch subsystem (see §Web Fetch):
                    CmpDetector, ConsentSeeder, ReaderExtractor,
                    Fallback, Fetcher

Dmhai.Util.*      — cross-concern helpers: Html (text extraction),
                    Url (parse/normalise/variants), Path (session-scoped path
                    resolution + traversal defence)

Dmhai.Constants   — single source of truth for filesystem paths
                    (assets_dir, session_root, session_data_dir,
                    session_workspace_dir, sanitize)

Dmhai.I18n        — plain-dict translation module (en/vi/es/fr/ja)

Dmhai.Handlers.*  — HTTP request handlers
Dmhai.Plugs.*     — Plug pipelines
Dmhai.Schemas.*   — Ecto schemas
Dmhai.Adapters.*  — external integrations (Telegram etc.)
```

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

### Confidant vs. Assistant — strict path separation

The mode branch is taken **at the earliest possible point** — inside the HTTP
handler, immediately after the session is located in DB. After the branch,
**no function is reached by both paths**. Shared code is tool-level only
(LLM, ContextEngine's mode-specific builders, SystemPrompt's mode-specific
generators, SessionProgress, Tasks, UserAgentMessages, TokenTracker). No
"dispatcher that checks mode internally" exists.

```
POST /agent/chat
    │
    ├── look up session.mode (single SELECT)
    │
    ├── mode == "confidant"
    │     → handle_confidant_chat(conn, user, body, session_id)
    │     → Http.dispatch_confidant(...) → {:dispatch_confidant, %ConfidantCommand{}}
    │     → UserAgent.handle_call({:dispatch_confidant, cmd})
    │     → run_confidant(cmd, state, session_data)
    │
    └── mode == "assistant"
          → handle_assistant_chat(conn, user, body, session_id)
          → Http.dispatch_assistant(...) → {:dispatch_assistant, %AssistantCommand{}}
          → UserAgent.handle_call({:dispatch_assistant, cmd})
          → run_assistant(cmd, state, session_data)
```

Command structs are split by mode — `AssistantCommand` carries text +
attachment names (the session loop is text-only; attachments live in the
stored user message as `📎 workspace/…` lines). `ConfidantCommand` carries
inline `images` / `has_video` for direct vision answering. This prevents a
body field from accidentally flowing into the wrong pipeline.

---

## UserAgent

One GenServer per authenticated user, idle-timed-out after 30 min. In the
conversational-session architecture it holds very little state — the
`tasks` + `session_progress` + `sessions.messages` tables are the truth.
The GenServer exists mainly to serialise per-user turns and hold
platform-specific metadata (Telegram chat_id, etc.).

```
UserAgent state:
  current_task:    nil | {ref, reply_pid}  ← one inline dispatched command
  platform_state:  %{telegram: %{...}, ...}
```

It accepts two **distinct** dispatch messages — one per mode — and routes
each to its own pipeline function. There is **no shared dispatcher** that
inspects the command to decide which pipeline to call.

```
handle_call({:dispatch_assistant, %AssistantCommand{} = cmd}, …)
  → Task.Supervisor.async_nolink(TaskSupervisor, fn ->
      run_assistant(cmd, state, session_data)
    end)

handle_call({:dispatch_confidant, %ConfidantCommand{} = cmd}, …)
  → Task.Supervisor.async_nolink(TaskSupervisor, fn ->
      run_confidant(cmd, state, session_data)
    end)

handle_call({:dispatch, :interrupt}, …)
  → cancel_current_task(state)        ← the only message that serves both
```

`run_assistant/3` and `run_confidant/3` do not call into each other and do
not share any helper that knows about the other path. Interrupt is the sole
cross-path message because cancellation is mode-agnostic.

In Assistant mode (#101 target), the dispatched task runs the **session
loop** (see §Assistant Mode) — a single conversational LLM turn with
tool-call roundtrips. The session loop is short-lived per turn: it starts
when a user message or `{:task_due, task_id}` arrives, runs the model
until it emits text, and exits. State lives in DB (`tasks`,
`session_progress`, `sessions.messages`), not in the GenServer.

---

## Timestamps and ownership

All persisted timestamps are generated at the backend (see CLAUDE.md
rule #9). The FE never stamps `ts` on user messages, assistant messages,
`session_progress` rows, or task rows, and never PUTs message-shaped state
back to the BE.

Concretely for a user turn:

1. FE POSTs `/agent/chat` with `{sessionId, content, attachmentNames?, files?}`.
   No `ts`, no local message push to `/sessions/:id` PUT.
2. BE, inside `handle_assistant_chat` / `handle_confidant_chat`, appends the
   user message to `session.messages` with `ts = System.os_time(:ms)` BEFORE
   dispatching to the pipeline, then returns `{user_ts}` immediately as
   JSON. The pipeline runs asynchronously in the background.
3. Pipeline runs. Every `session_progress` row gets `ts = System.os_time(:ms)`
   at INSERT. Final-text tokens are written to `sessions.stream_buffer`
   as they arrive from the LLM (throttled; see below). When the final
   text round completes, the accumulated text is appended to
   `session.messages` with its own BE `ts` and `stream_buffer` is cleared.

The FE holds a local mirror of `session.messages` for display. It
optimistically appends a user-message object at send time for instant
rendering — that object carries NO `ts`. The POST response `{user_ts}`
is used to patch the optimistic entry with the canonical BE timestamp.
Everything after that — progress rows, streaming text, final assistant
message — flows through polling.

## Polling-based delivery

There is no server-sent event stream. `/agent/chat` is fire-and-forget;
the turn runs in the background on the UserAgent's supervised Task and
all output lands in DB tables.

The FE reconciles via a single polling endpoint per active session:

```
GET /sessions/:id/poll?msg_since=<ts>&prog_since=<id>
→ {
    "messages":       [... messages with ts > msg_since, newest-last ...],
    "progress":       [... session_progress rows with id > prog_since ...],
    "stream_buffer":  "<partial accumulated text>" | null,
    "is_working":     true | false
  }
```

- `messages` delta: new user / assistant messages persisted since the
  last tick. Usually one at a time.
- `progress` delta: `session_progress` rows (kind=tool pending/done, or
  kind=thinking, or kind=summary) since the last tick. Cheap — indexed
  on `(session_id, id)`.
- `stream_buffer`: partial text of the in-flight final-answer round.
  Updated on the BE in-place as tokens arrive from the LLM, capped to a
  hard update cadence (default 250 ms between writes — see
  `@stream_buffer_flush_ms`). `null` when no generation is active.
- `is_working`: `true` when the UserAgent's `current_task` is set or
  `stream_buffer` is non-null. Drives the FE polling cadence.

**FE cadence** (`manager-*` scripts):

- Active session + `is_working=true`: **500 ms** poll.
- Active session + `is_working=false`: **5 s** poll.
- `document.hidden` / session switch: poll paused entirely.
- Session switch: one `GET /sessions/:id` snapshot to rebuild local
  state, then resume polling on the new session id.

**FE rendering**:

- New `messages` delta is merged into `currentSession.messages` by ts
  (optimistic user entries patched in place).
- New `progress` delta is merged into `currentSession.progress` by id
  (upsert — done-flips overwrite the prior pending row).
- `stream_buffer` is rendered in the streaming placeholder (the same
  DOM node that used to display the live-streamed token text). When
  the final message appears in the `messages` delta, the placeholder is
  replaced with the permanent message and the buffer goes to `null`.

**Latency** (500 ms poll):
- Tool spinner / tick: visible within 500 ms of tool start / finish.
- Final-text reveal: updated every 500 ms in chunks as the LLM produces
  tokens — text grows visibly rather than appearing in one bam. Not
  token-perfect, but well above the "visibly moving" perceptual
  threshold.
- First byte (user optimistic render → first tool line): ~same as
  today, gated by BE turn dispatch speed.

---

---

# Confidant Mode

In Confidant mode, every message is handled with a single LLM streaming call.
There are no tasks, no tool calls, no Assistant Loop — just a one-shot
answer. Delivery uses the same polling mechanism as Assistant mode: the
LLM's streamed tokens are buffered into `sessions.stream_buffer`, the FE
polls to render progressive text, and the final answer lands in
`session.messages` when generation completes.

**Separation guarantee**: this path shares **no function** with the Assistant
path. Its command type is `%ConfidantCommand{}`, its dispatcher is
`{:dispatch_confidant, cmd}`, its pipeline function is `run_confidant/3`, and
its context builder is `ContextEngine.build_confidant_messages/2`. Tool-level
helpers (LLM, UserAgentMessages, Tasks only for read-only queries) are
stateless utilities, not shared pipeline code.

---

## Confidant Pipeline Flow

```
POST /agent/chat    (mode === "confidant" branch)
    │
    ▼
handle_confidant_chat(conn, user, body, session_id)
    │
    ├── parse body: content, images[], imageNames[], files[], hasVideo
    │   (Confidant fields only — attachmentNames ignored even if present)
    │
    ├── build %ConfidantCommand{content, session_id, reply_pid,
    │                            images, image_names, files, has_video, metadata}
    │
    └── Http.dispatch_confidant(user_id, cmd)
          → GenServer.call(UserAgent, {:dispatch_confidant, cmd})
                │
                ▼
          UserAgent.run_confidant(cmd, state, session_data)
                │
                ├── [1] Web search detection (optional)
                │         WebSearch.detect_intent(message) → bool
                │         if true: WebSearch.search(keywords) → raw results
                │                  LLM.call(summarizer_model) → web_context
                │
                ├── [2] Media resolution (Confidant-only)
                │         load image/video descriptions from DB
                │         if any missing: describe inline via LLM call per missing file
                │
                ├── [3] Context assembly → ContextEngine.build_confidant_messages/2
                │         (see §Context Assembly below)
                │
                └── [4] LLM.stream(confidant_model, messages)
                          → tokens → sessions.stream_buffer (throttled writes)
                          → final text appended to session.messages on completion
                          (inline images[] are passed to the LLM for direct
                           vision answering — unlike the Assistant path)
```

### Context Assembly

`ContextEngine.build_confidant_messages/2` assembles the final message list in this order:

```
[0]     system: SystemPrompt.generate_confidant(opts)
                  ├── Confidant base persona (friend-style; structured for technical topics)
                  ├── Today's date
                  ├── User profile   (injected silently, never quoted)
                  ├── Image descriptions (from DB or inline describe result)
                  ├── Video hint section (only if has_video = true)
                  └── Language directive (only if language detected)

[1..N]  Compaction prefix (only when session.context.summary is present)
          {role: "user",      content: "[Summary of our conversation so far]\n<summary>"}
          {role: "assistant", content: "Understood, I have the full context of our conversation."}

[N+1..M] Recent messages (as-is from sessions.messages JSON)
           All messages with index > context.summary_up_to_index

[M+1..P] Relevant snippets (optional, top-4)
           Old message pairs (before summary cutoff) scored by keyword hit-ratio ≥ 0.25
           Injected inline as user/assistant pairs for long-term context retrieval

[P+1]   Current user message
           if web_context:
             "User request: <original text>\nWeb search results: <synthesized>\n
              Using the sources above, answer the user's request."
             (replaces the raw message — web context wraps it)
           if images: base64 images attached inline (resized to max 768px JPEG by client)
           if files:  file content appended to message
```

**Compaction** triggers when `recent_turns > masterCompactTurnThreshold (90)` OR
`recent_chars > masterCompactFraction (45%) of context budget`. `compact!` calls the
compactor LLM (`AgentSettings.compactor_model()`, NOT hardcoded) and writes
`{"summary", "summary_up_to_index"}` to `sessions.context`. Old messages are retained in
the DB and remain available for keyword retrieval.

### Media Pipeline

Client pre-processes before the `/agent/chat` call:

```
Image: resize to IMAGE_VISION_MAX_PX (768px), upload original to /assets (background)
       → background describe via image_descriptions table
       base64-encoded resized image sent inline in the chat request (images[])

Video: upload original to /assets (background, ≤ 300 MB)
       client extracts evenly-spaced JPEG frames (VIDEO_FRAME_MAX_WIDTH = 640px)
       → background describe via video_descriptions table
       base64 frames sent inline in the chat request (images[], hasVideo=true)
```

Send button is gated until image resize and video frame extraction complete.

---

# Assistant Mode

In Assistant mode, every user message (and every periodic-task pickup
poke) is handled by a **single conversational LLM turn** for the session.
The same model sees the conversation history, the current task list, and
the new input, then decides what to do — call tools, update tasks, reply
with text — on a per-turn basis. There is no separate classifier stage and
no plan/exec/signal protocol.

---

## Session loop

```
incoming:
  {:user_msg, %AssistantCommand{content, attachment_names, files}}
  OR
  {:task_due, task_id}        ← fired by scheduler; no user text

  ▼
UserAgent.run_assistant(cmd, state, session_data)
  │
  ├── build context (§Context assembly)
  │     system prompt + history + [Active tasks] block + current input
  │
  └── conversational turn loop:
        LLM.call(model, messages, tools, ...) →
          ┌─ {:tool_calls, calls} ─┐
          │   execute each call, append tool result, loop
          └─ {:text, text} ─┘
               append assistant message to session, stream to user, DONE

  Safety cap: max_assistant_tool_rounds per turn (default 50) — if hit,
  abort with a "let's continue next turn" message.
```

The turn is strictly sequential: the model emits a tool-call round,
tool(s) run, results come back, the model emits the next round (or text).
Text output ends the turn — no "must end with signal" rule.

If a second user message arrives while a turn is in flight, it queues in
the session's mailbox and is handled on the next turn (the message
surfaces in the updated `session.messages` context).

---

## Context assembly

`ContextEngine.build_assistant_messages/2`:

```
[0]     system: SystemPrompt.generate_assistant(opts)
                  ├── persona, tool-use rules, output-quality rules
                  ├── today's date
                  └── user profile (silently injected)

        The assistant model is fully multilingual — it detects the user's
        language from the current message and replies in the same language
        without any separate detection step. Language is also NOT a field
        passed into the system prompt.

[1..N]  Compaction prefix (only when session.context.summary is present)

[N+1..M] Recent messages (history)

[M+1..P] Relevant snippets (keyword retrieval from pre-compaction history)

[P+1]   Task-list block — injected right before the current input.
          Hierarchical Markdown with an explicit `base_level` (default 2):
          `base_level` → top `Task list` heading
          `base_level + 1` → type sub-sections (`periodic` / `one_off` / `done`)
          `base_level + 2` → one heading per active task

          Example (base_level = 2):

              ## Task list

              ### periodic

              #### `01HQ4Z…abc` — Monitor physics papers
              **Description:** Watch arxiv daily for new quantum-computing papers.
              **Status:** pending
              **Pick up time:** 2026-04-21 18:00 UTC
              **Attachments:**
              - workspace/keywords.txt

              ### one_off

              #### `01HQ4Z…def` — Book flight tickets
              **Description:** Book round-trip LAX↔Tokyo, Feb 15–28.
              **Status:** ongoing
              **Attachments:**
              - workspace/passport_scan.jpg

              ### done

              - `01HQ4Z…ghi` — Research physics
              - `01HQ4Z…jkl` — Order new bike

          Rules:
          - Type sub-sections appear ONLY when they contain at least one task.
          - Non-terminal tasks (pending / ongoing / paused) render the full
            block (description, status, pickup, attachments). `task_id` is
            rendered inside the title heading as `` `<id>` — <title> `` so the
            model always sees the ID adjacent to the title and never needs
            to invent one.
          - Done / cancelled tasks render flat under `### done` using the
            SAME id-prefix format: `- \`<task_id>\` — <task_title>`.
            Keeps the list manageable as sessions age — the model can call
            `fetch_task(task_id)` for details (e.g. to redo a task).
          - Attachments are extracted at render time from lines matching
            `^📎\s+(.+)$` in `task_spec`; the 📎 is stripped when rendering.
            If no matching lines → the **Attachments:** row is omitted.
          - Heading depth is enforced: `base_level + 2` must not exceed 6
            (Markdown ceiling); the generator raises if it would.

          This block mutates between turns (status transitions + task
          updates), so it's placed at a stable bottom position — older
          history stays KV-cache-warm.

[P+2]   Current input
          - User message: verbatim content, possibly ending with
            "📎 workspace/<name>" lines (injected at /agent/chat entry).
          - OR synthetic: "[Periodic task due: <task_title>]"
            for a {:task_due} turn.
```

---

## Task lifecycle

```
task_status transitions:

  (no state)─► ongoing  ──► done       (Tasks.mark_done)
                   │          │
                   │          └─ if task_type == "periodic":
                   │               Tasks.mark_done auto-
                   │               reschedules:
                   │                 status=pending,
                   │                 time_to_pickup=now+intvl_sec
                   │                 TaskRuntime.schedule_pickup
                   │
                   ├──► paused    (update_task(status: "paused"))
                   │
                   ├──► cancelled (update_task(status: "cancelled"))
                   │
                   └──► (stays ongoing; the assistant may go idle
                         waiting for next user turn)

  pending ◄── (periodic auto-reschedule OR
               update_task(status: "pending") to redo a done task)
      │
      └── when scheduled pickup fires (time_to_pickup reached),
          UserAgent injects a {:task_due} turn; the next session
          turn transitions the task to ongoing again.
```

Key properties:

- **`create_task` inserts with `task_status='ongoing'`, not `pending`.** The
  model created the task because it is about to execute it in this same
  turn — there is no pending phase for freshly-created tasks. `pending` is
  reserved for periodic tasks awaiting their next cycle and for done tasks
  explicitly resurrected via `update_task(status: "pending")`.
- **`Tasks.mark_done/2` is the single source of rescheduling for periodic
  tasks.** The assistant doesn't call a separate reschedule tool — it just
  updates status to "done", and the mark_done implementation branches on
  `task_type`.
- **Best-effort scheduling.** If `time_to_pickup` arrives while the session
  is mid-turn on another task, the pickup waits in the mailbox until the
  current turn completes. On the next turn the assistant sees a pending
  periodic in its task list with pickup in the past and acts on it.
- **Auto-chain after each turn.** When a turn completes (user-initiated
  OR task-due initiated), the UserAgent calls `Tasks.fetch_next_due/1` for
  that session. The query returns the single pending task with the
  lowest `time_to_pickup ≤ now`. If a row comes back the agent self-sends
  `{:task_due, task_id}` and starts a silent turn for it — no user is
  waiting so progress frames flow to a throwaway pid while
  `session_progress` rows and the final assistant message still persist.
  FE picks them up via polling. The chain stops when `fetch_next_due`
  returns `nil` (queue empty, or only future-scheduled pickups remain).
- **No "superseded" / fork.** User redirects mid-task → the assistant
  updates the task description or status naturally on its next turn.
  No `predecessor_task_id`, no `superseded_by_task_id` — those scaffolding
  columns are removed.

### Sidebar ordering

The FE sidebar (`js/manager-tasks.js :: partitionTasks`) sorts the
`pending` bucket by `time_to_pickup` ASC — oldest pickup first, which
matches the BE's `fetch_next_due/1` dispatch order. What shows at the top
of the pending section is what the agent will work on next. Tasks
without a pickup fall to the bottom. Other buckets: `ongoing` keeps BE
order (newest first), `recent` is `updated_at` DESC.

---

## Assistant tool schemas

Task-management tools (assistant calls these to shape its task list):

| Tool | Args | Effect |
|------|------|--------|
| `create_task` | `task_title`, `task_spec`, `task_type` (one_off\|periodic), `intvl_sec`, `language`, `attachments?` | Insert a task row (**status=ongoing**, time_to_pickup=now). The model is calling this because it's about to start executing the task in this same turn — so the row starts in `ongoing`, not `pending`. If `attachments` is non-empty, each path is validated (must start with `workspace/` or `data/`) and `📎 <path>` lines are appended to the stored `task_spec` — so the DB row has canonical form. Returns `task_id`. |
| `update_task` | `task_id`, `status?`, `task_spec?`, `intvl_sec?`, `attachments?` | Mutate fields. `status="done"` triggers the auto-reschedule branch for periodic tasks. `attachments`, if passed, REPLACES the existing list (not additive) — same validation + normalisation as `create_task`. Omit to leave attachments untouched. |
| `fetch_task` | `task_id` | Read-only fetch for when the assistant needs task details beyond what the Task-list block shows (e.g. the full description of a done task, the previous cycle's result, the activity log). Returns the full task row plus the latest ≤20 `session_progress` entries for that task. |

### "Redo a done task" vs "new related ask"

**Default: each new user ask is a new task.** A follow-up that asks for
different information — even on the same subject — calls `create_task`
again and runs its own pending → ongoing → done cycle. The sidebar then
shows each distinct ask as its own row with its own audit trail. This is
the rule enforced by `system_prompt.ex :: assistant_base :: ## Task list
discipline`. Example:

> *"Find out what machines are in the network"* → task A (scan).
>
> *"ok which ones have an HTTP server?"* → task B, independent of A —
> different data, different script, different audit trail. Both tasks
> visible in the sidebar.

**Exception: explicit redo of the immediately preceding task.** Only
when the user says *"actually try Y instead"* / *"re-run that"* /
*"do it again but deeper"* — about the task that just finished — does
the assistant reuse that same `task_id`:

- Task still pending / ongoing / paused → `update_task(task_id,
  task_spec: "<new description>")` to rewrite and continue.
- Task already done → `update_task(task_id, status: "pending")` to
  reopen; mark done again when finished. For a periodic task, "done →
  pending" resumes the schedule (the DB row's `time_to_pickup` stays at
  its last value).

Follow-ups that only *look* related to a done task are NOT redos — they
get their own `create_task`.

### Attachment routing

**Uniform attachment pipeline — no format-specific shortcuts.** In
Assistant mode every attachment — image, video, PDF, DOCX, XLSX, plain
text, anything else — follows the same path:

1. FE uploads the raw file to `/assets` (permanent user-accessible
   storage) AND to `/upload-session-attachment` (writes it to
   `<session>/workspace/<name>`). No client-side content extraction.
2. At send time the FE passes each uploaded file's name in
   `attachmentNames: [...]`. The `/agent/chat` body's inline
   `files: [{name, content}]` field is NOT used by the Assistant path —
   it is a Confidant-only inline-injection channel, see Confidant Mode.
3. BE inlines `📎 workspace/<name>` lines into the persisted user
   message, one per attachment.
4. The model sees those paths in the user message. When it wants the
   file's content it calls `extract_content(path: "workspace/<name>")`
   as a tool call — same for images, videos, documents, and text.
   That tool call becomes a `session_progress` row in the chat
   timeline; the read is never invisible.
5. Per the Task-list discipline, the model wraps the extract call in
   a `create_task` → `update_task(done)` cycle when the read is part
   of a substantive action.

The routing inside `extract_content` (image / video / pdf / pandoc-doc /
plain-text branches) is an implementation detail — the model's mental
model is "one path per attachment, one tool call to read, one task per
substantive action". No attachment type is ever auto-injected into the
LLM context in Assistant mode.

When a task involves a specific subset of the attachments listed on the
user message, the model passes those `📎 workspace/...` paths in the
`attachments` argument of `create_task` / `update_task`; never
hand-embeds `📎 ` lines in `task_spec`. The BE normalises the stored
spec from the validated `attachments` list.

Execution tools (unchanged from prior phases):
`web_fetch`, `web_search`, `run_script`, `extract_content`, `read_file`,
`write_file`, `calculator`, `parse_document`, `spawn_task`, `get_date`.

Credential tools (per-user persistent credential store; see
`Dmhai.Agent.Credentials`):

| Tool | Args | Effect |
|------|------|--------|
| `save_credential` | `target`, `cred_type` (ssh_key\|user_pass\|api_key\|token\|other), `payload` (object), `notes?` | Upsert scoped to (user_id, target). Payload is a free-form JSON object — e.g. `{username, private_key}` for ssh_key, `{username, password}` for user_pass, `{value}` for api_key / token. |
| `lookup_credential` | `target?` | With `target`: return the full record (payload included). Without: return the list of saved targets (metadata only, no secrets) so the assistant can pick one. |

Storage is plaintext in the `user_credentials` SQLite table — documented
shortcut matching how the rest of the app treats sensitive fields; revisit
when the DB is moved off local disk. The assistant is prompted (see
`system_prompt.ex :: assistant_base`) to look up before asking, ask
specifically when absent, and save immediately on receipt so future tasks
against the same target don't re-prompt.

**Removed tools** (no longer exist): `plan`, `step_signal`, `task_signal`,
`handoff_to_worker`, `pause_task`, `resume_task`, `set_periodic_for_task`,
`read_task_status` (collapsed into `update_task`, `fetch_task`, and
direct replies).

---

## Scheduler — `Dmhai.Agent.TaskRuntime`

A single named GenServer. Its only job is to arm timers for periodic task
pickups and, on fire, nudge the session to wake up. It does not track
in-flight work (there is none — the session loop is per-turn, not
persistent).

```
schedule_pickup(task_id, when_ms):
  cancel any existing timer for task_id
  ref = Process.send_after(self(), {:pickup_due, task_id}, when_ms - now)
  state.timers = Map.put(state.timers, task_id, ref)

handle_info({:pickup_due, task_id}):
  task = Tasks.get(task_id)
  session_pid = UserSupervisor.ensure_session_started(task.user_id, task.session_id)
  send(session_pid, {:task_due, task_id})

boot rehydrate (Dmhai.Agent.TaskRuntime.rehydrate/0):
  for task in tasks where status="pending" AND task_type="periodic"
      AND time_to_pickup IS NOT NULL:
    schedule_pickup(task_id, task.time_to_pickup)
  for task in tasks where status="ongoing":
    Tasks.update_fields(task_id, status: "pending")
      (a.k.a. any task that was ongoing when the BEAM died reverts to
       pending; the assistant will see it in the task list and pick up
       where the session_progress log left off)
```

Cancelling / pausing a task also cancels its pickup timer (done inside
`Tasks.mark_cancelled/1` and `Tasks.mark_paused/1` via a callback into
TaskRuntime).

---

## Session mailbox interleaving

The session's GenServer has one mailbox. Messages that arrive while a turn
is running:

- `{:dispatch_assistant, %AssistantCommand{}}` — next user message
- `{:task_due, task_id}` — scheduler poke
- `:interrupt` — cancel the current turn

All queue; all are processed in arrival order at the start of the next
turn. The model sees them as they are — the `[Active tasks]` block
reflects whatever state the DB has when context is built.

Because there is only one ongoing turn at a time per session, parallelism
within a session is nil by design. A user who wants two truly independent
threads of work creates a second chat session; each session has its own
GenServer and its own task list.

---

## Completion & output

At the end of a turn the assistant emits text (plus any final tool-call
rounds). That text becomes the `role: "assistant"` entry in
`session.messages`. The FE renders it like any assistant reply. There is
no separate "task done" notification path — the conversation itself
announces completion ("Got it, here's the summary: …"), and the
task's `status=done` row is visible in the FE's task-list sidebar.

External push (Telegram, etc.) for task completion remains available via
`MsgGateway.notify/2` when a task transitions to `done` or `cancelled` —
see #95 for the scheduled-push variant.

---

## Boot rehydration

```
Dmhai.Agent.TaskRuntime.rehydrate/0 (called 500 ms after app start):
  1. Any task with status="ongoing" → revert to "pending"
     (the session turn that owned it didn't complete; the assistant will
      resume via task list on next user message or scheduled pickup).
  2. Any pending periodic task with time_to_pickup IS NOT NULL →
     schedule_pickup (re-arm the timer).
  3. Any pending periodic task with time_to_pickup <= now → poke the
     session immediately (next user interaction will handle it).
```

Disabled in `:test` env via `:dmhai, :enable_task_rehydrate, false`.

Crash survival is trivial under this model: `tasks` + `session_progress`
+ `sessions.messages` are the truth. The assistant reads them on its
next turn and continues. No ctx-snapshot persistence is needed.

---

## Police (shrunk)

Retained:
- **Path safety** — `check_tool_calls/3` still validates any `path`
  argument resolves inside `session_root` via `Dmhai.Util.Path.resolve/2`.
  `run_script` still scans for `rm` / `rmdir` / `cp -r` that target paths
  outside `workspace_dir`.

Removed:
- Signal protocol rules (`step_signal` batching, `task_signal` ordering,
  terminal-tool exclusivity) — protocol is gone, rules along with it.
- Repeated-identical-tool-call kill switch — the conversational model
  doesn't produce the loop-trap failure mode that required it; rely on
  the per-turn max_assistant_tool_rounds cap instead.

---

---

## Filesystem Layout

All paths are derived from `Dmhai.Constants` — the single source of truth. Emails are used as-is; session ids and task ids are sanitised via `Constants.sanitize/1` (alphanumerics + dash + underscore only).

```
/data/user_assets/<email>/<session_id>/
  ├── data/       ← user uploads (POST /assets writes here; GET /assets serves from here)
  └── workspace/  ← scratch shared across ALL tasks in the session
                    (web fetches, temp files, bash output, assistant outputs)
```

One `data/` and one `workspace/` per session — no per-task subdir, no per-origin subdir. Confidant sessions create neither folder until (and unless) a task is spawned.

**`origin` and `pipeline` task columns:**

Both are kept on the tasks row for bookkeeping but are effectively always `"assistant"` now — Confidant sessions don't create tasks. The filesystem layout no longer splits by origin; all tasks in a session share `<session_root>/workspace/`. Columns are retained for future polymorphic use.

### `Dmhai.Constants` Helpers

```elixir
Constants.assets_dir()                             # "/data/user_assets"
Constants.sanitize("foo/bar")                      # "foo_bar"
Constants.session_root(email, sid)                 # <assets>/<email>/<sid>
Constants.session_data_dir(email, sid)             # <session_root>/data
Constants.session_workspace_dir(email, sid)        # <session_root>/workspace
```

### Session turn ctx

When a session turn runs, UserAgent builds the ctx for tool execution:

```elixir
ctx = %{
  user_id:       session.user_id,
  user_email:    <looked-up>,
  session_id:    session.id,
  task_id:       <current task if one is active>,
  session_root:  <.../<email>/<sid>>,
  data_dir:      <session_root>/data,
  workspace_dir: <session_root>/workspace
}
```

Tools receive this ctx and use `session_root` / `data_dir` /
`workspace_dir` for path resolution. `task_id` is nil during
direct-response turns and set to the actively-worked task otherwise.

### Tool Path Resolution — `Dmhai.Util.Path.resolve/2`

| Input path prefix | Resolves under |
|-------------------|----------------|
| `data/` or `/data/` | `ctx.data_dir` |
| `workspace/` or `/workspace/` | `ctx.workspace_dir` |
| `/absolute/...` | as-is, then validated to be inside `session_root` |
| relative (bare) | anchored to `ctx.workspace_dir` (fallback: `session_root`) |

Any path that escapes `session_root` after `Path.expand` → `{:error, "Access denied: path escapes the session root"}`. Defeats `../` traversal.

---

## Media Pipeline

Client does **not** pre-digest media for the Assistant Loop — the Loop calls
tools instead. When media is attached in an Assistant-mode session, both
uploads fire at **attach time** (not at send time), so paths are fully known
by the time the user hits Send.

```
At attach time (user drops file):
  (1) POST /assets                     ← save ORIGINAL to <session>/data/<name>
                                          permanent storage for human access
                                          (thumbnail render, download button).
                                          Video max: 300 MB (MEDIA_MAX_SIZE_BYTES).
                                          Returns fileId used by FE only.
  (2) Workspace upload. Every file type — images, videos, PDFs, DOCX,
      XLSX, plain text, anything — is uploaded as-is to the session
      workspace:
      - Image: resizeImage → 768px JPEG (sub-second canvas op) →
        POST /upload-session-attachment as workspace/<name>.jpg
      - Video: scaleVideo → VIDEO_WORKSPACE_MAX_PX / VIDEO_WORKSPACE_BITRATE
        via MediaRecorder + canvas, real-time 1:1 with duration →
        POST /upload-session-attachment as workspace/<base>.webm.
        Send button is gated until scaling completes.
      - PDF / DOCX / XLSX / TXT / any other format: raw file →
        POST /upload-session-attachment as workspace/<name>.
        NO client-side extraction — the BE's `extract_content` tool
        handles all formats uniformly via pdftotext / pandoc / direct
        read. This keeps the architecture consistent: no attachment
        type is auto-injected into the LLM context, every read is a
        visible `extract_content` tool call.
      Multipart fields: file, sessionId. (No taskId — the workspace is
      per-session since Phase 2 #91, so no task-level namespacing is
      needed.) Max workspace attachment size: 200 MB.

At send time:
  (3) POST /agent/chat                 ← fires with attachmentNames[] in body.
                                          images[] / files[] inline fields
                                          are NOT used by the Assistant path
                                          (Confidant-only).

BE /agent/chat entry:
  (a) wait_for_attachments(workspace, names)
        Safety net — uploads almost always finish at attach time; polls
        up to 30 s if a late upload is still in flight.
  (b) User message is persisted to session.messages with content =
        "<user text>\n\n📎 workspace/<name1>\n📎 workspace/<name2>"
        (one `📎 ` line per attachment). 📎 is a language-neutral
        marker the system prompt teaches the model: `📎 `-prefixed
        lines are uploaded file paths, read them via `extract_content`.

  (c) Session turn proceeds with stored history (now containing the paths).
```

**Obsolete & removed (Phase 2)**:

Endpoints / API:
- `GET /reserve-task-id` endpoint — nothing needs a task_id at upload time.
- `/upload-task-attachment` → renamed `/upload-session-attachment`.
- `taskId` field in the upload multipart body.
- `taskId` field in the `/agent/chat` body.

UserAgent internals:
- `Dmhai.Agent.Command` single struct → split into `AssistantCommand` and
  `ConfidantCommand` (see §Request Lifecycle).
- `UserAgent.run_command/2` — the shared dispatcher that inspected mode
  internally. Mode branch now lives in the HTTP handler; UserAgent receives
  two distinct dispatch message types.
- `Command.task_id` struct field.
- `build_attachment_section`, `wait_for_attachments`, `save_inline_images`
  inside `handle_handoff_to_worker` — replaced by the single
  `UserAgentMessages.inject_attachment_paths/3` step at `/agent/chat` entry.
- `save_inline_images` fallback (the inline-base64-as-workspace-fallback path).
- English-only `[Attached files — use extract_content on these paths as
  needed]` header that inject_attachment_paths used to prepend — replaced
  with the language-neutral `📎` prefix on each path line.

Tool names:
- `handoff_to_worker` → renamed `create_task` (no separate worker exists
  post-#89; the Assistant itself drives the loop).

Classifier inputs:
- Inline `images[]` for the Assistant classifier — classifier is now a
  text-only router. Attached paths live in the stored user message and the
  Assistant Loop processes pixels via `extract_content`. Confidant mode
  continues to use inline images (separate path, unchanged).

Runtime (#96 — event-driven rewire):
- The per-task `poller_loop/3` and all its helpers (`runner_dead?`,
  `safe_shutdown_poller`, `synthesize_blocked` from the poller path).
- `Tasks.advance_cursor/2` — unused after poller removal.
- `tasks.last_reported_status_id` column — only the poller read/wrote it.
- `task_poll_min_interval_sec`, `task_poll_samples_per_cycle`,
  `task_progress_summary_*` settings (except `*_min_interval_sec` which
  remains to rate-limit the on-demand summariser).
- `:task_poll_override_ms` test-env config.
- `poller_task` field in TaskRuntime's per-task state record.
- `broadcast_progress/2` stub in TaskRuntime.
- Poller-driven `maybe_announce_progress/1` — obsoleted with the summariser
  changes in #90 and the poller removal in #96.

Conversational session rearchitecture (#101 — landed):
- `Dmhai.Agent.AssistantLoop` module + `AssistantLoopSupervisor` — the Loop
  is now inline turn-by-turn in `UserAgent.run_assistant`.
- Plan/exec/signal protocol: `Dmhai.Tools.Plan`, `Dmhai.Tools.TaskSignal`,
  `Dmhai.Tools.StepSignal` — deleted.
- `Dmhai.Agent.Prompts` plan-phase / execution-phase prompt builders —
  deleted. Session loop uses one unified system prompt.
- Police signal-protocol rules: batching checks, terminal-tool ordering,
  `step_signal` vs `task_signal` discipline — gone. Path safety retained.
- `tasks.predecessor_task_id`, `tasks.superseded_by_task_id` columns and
  the `'superseded'` status value — fork-on-adjust scaffolding; removed.
- `tasks.current_worker_id`, `last_summarized_status_id`,
  `last_summarized_at`, `last_run_started_at`, `last_run_completed_at`,
  `pipeline`, `origin` columns — derivable from `session_progress` or
  redundant in the one-session model.
- `next_run_at` → renamed `time_to_pickup` (more accurate; covers the
  one-off case too).
- `'one_off'` stays as the task_type value (consistency with existing code).
- `pause_task`, `resume_task`, `set_periodic_for_task`, `read_task_status`
  tools — collapsed into `update_task(task_id, status|task_spec|intvl_sec)`
  and direct assistant replies.
- `TaskRuntime`'s runner tracking — now just the periodic-pickup scheduler.

Pre-turn language detection (#102b):
- `UserAgent.detect_content_language/1` + `parse_language_code/1` —
  vestigial from the old classifier/loop split. The conversational
  assistant model handles language detection inline at zero additional
  cost. Deleted.
- `AgentSettings.language_detector_model/0` + the `languageDetectorModel`
  admin setting — no consumer after detection removal. Deleted.
- `SystemPrompt` `language` parameter + `language_hint/1` helper — the
  system prompt no longer receives or injects a language directive.
- `ContextEngine.build_assistant_messages` `:language` opt — removed.

Phase-3 cleanup (#94 — in progress):
- Task-list block restructured to hierarchical Markdown with `base_level`
  parameterisation (see §Context assembly).
- `create_task` / `update_task` gain explicit `attachments` argument;
  `fetch_task` tool added. The model no longer hand-embeds `📎` lines
  in `task_spec`; the BE normalises the stored spec from the validated
  `attachments` list.
- `Dmhai.Agent.MasterBuffer` module + `master_buffer` DB table — legacy
  notification bus; unused after #90/#101. Removed.
- `UserAgent.cancel_session_workers/2` → renamed `cancel_session_tasks/2`
  (no workers exist any more).
- `UserAgentMessages.archive_by_task_id/3` — obsolete after #101's
  single-session-no-parallel-cycles model. Removed.
- Obsolete i18n keys removed: `worker_exited_no_signal`, `worker_orphaned`,
  `worker_refused_signal`, `max_iter_reached`, `loop_crashed`,
  `loop_max_restarts_blocked`, `unknown_terminal_status`,
  `plan_submission_failed`, `step_blocked_exhausted`,
  `exec_errors_after_warning`, `policy_violation`, `blocked_label`,
  `status_blocked`, `notify_blocked`, `task_spec_fallback`.

When the session loop decides to read an attachment it calls
`extract_content(path: "workspace/<name>")`:

- Image (`.jpg`, `.png`, …) → ImageMagick scale → 1 LLM call → `## Description` + `## Verbatim Content`
- Video (`.webm`, `.mp4`, …) → ffmpeg extracts N frames server-side → 1 LLM call → same two sections
- Document (`.pdf`, `.docx`, …) → pdftotext / pandoc / direct read → text returned directly (no LLM)

All results come back as tool results and stay in the session turn's
context as usual.

---

## Tool result formatting

Per CLAUDE.md rule #10, the session loop's `format_tool_result/1` in
`user_agent.ex` normalises a tool's `{:ok, result}` payload into the
string that is handed to the model as the `tool` role message's content.

Rules:

- **Binary in → binary out, verbatim.** Text-oriented tools (`run_script`,
  `read_file`, `parse_document`, `extract_content`, `datetime`) return raw
  strings. The model sees exactly the text a human would see.
- **Map / list in → pretty JSON out.** Metadata-oriented tools (`create_task`,
  `update_task`, `fetch_task`, `web_search`, `web_fetch`, `save_credential`,
  `lookup_credential`) return structured data. `format_tool_result` runs a
  recursive normalisation first — atoms → strings (`"ok"`, not `:ok`),
  tuples → lists, nested maps/lists flattened to JSON-native — then
  `Jason.encode!/2` with `pretty: true`.
- **Primitives (number, boolean, nil)** are coerced via `to_string/1`.
- **`inspect/1` is forbidden** — it leaks Elixir syntax (`%{}`, `:atom`,
  `{:ok, x}`) into the model's context. Any code path that would reach
  `inspect/1` is a bug.

`run_script` follows the text convention: on success it returns the raw
stdout string; on non-zero exit or timeout it returns `{:error, "<reason>"}`
(handled separately, not through `format_tool_result`). The previous
`%{output, workdir}` map wrapping is removed — `workdir` is already in
the session ctx and isn't useful to the model.

---

## Session LLM trace logging

When the `logTrace` admin setting is `true`, every session turn writes a
verbatim log to:

```
<session_root>/log_traces/<task_id or "direct">.log
```

Each log records every LLM call (full system prompt + message history)
and response (tool calls or plain text) for that turn, timestamped.
Turns on a specific task write into `<task_id>.log`; turns that are
pure direct-response (no task touched) write into `direct.log`.

**Control:** Admin UI → Conversation Settings → "Trace assistant LLM
calls to file" checkbox. Persisted in `admin_cloud_settings.logTrace`
(boolean, default `false`). Takes effect on the next turn.

---

---

# Shared Infrastructure

---

## Web Fetch (CMP-aware)

`Dmhai.Tools.WebFetch` is a thin wrapper over `Dmhai.Web.Fetcher`. Used in the Confidant pipeline (web search synthesis) and as the `web_fetch` worker tool in the Assistant pipeline.

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

## LLM Routing

All calls go through `Dmhai.Agent.LLM`. Model strings: `<provider>::<pool>::<model>`:

```
"ollama::local::llama3.2:3b"
"ollama::cloud::gemini-3-flash-preview:cloud"
"openai::default::gpt-4o"
"anthropic::default::claude-3-5-sonnet"
```

Models ending in `:cloud` / `-cloud` auto-route to cloud pool. Cloud keys managed in admin settings as a per-provider pool; `LLM` picks one per call, shuffles active keys first, then throttled ones. 5xx responses are retried 3× with 2s backoff on the same account before rotating.

### Model Assignments (admin-configurable)

| Role | Default |
|------|---------|
| Confidant | `gemini-3-flash-preview:cloud` |
| Assistant (session loop) | `devstral-small-2:24b-cloud` |
| Context Compactor | `gemini-3-flash-preview:cloud` |
| Progress Summariser (on-demand) | `gemini-3-flash-preview:cloud` |
| Web Search Detector | `ministral-3:14b-cloud` |
| Image Describer | `gemini-3-flash-preview:cloud` |
| Video Describer | `gemini-3-flash-preview:cloud` |
| Profile Extractor | `gemini-3-flash-preview:cloud` |

### Other Settings (admin-configurable)

| Key | Default | Purpose |
|-----|---------|---------|
| `maxAssistantToolRounds` | 50 | Per-turn cap on tool-call roundtrips; abort turn if exceeded |
| `maxToolResultChars` | 8000 | Truncation threshold for tool results fed back into context |
| `spawnTaskTimeoutSecs` | 30 | Bash command timeout inside spawn_task |
| `masterCompactTurnThreshold` | 90 | Session compaction turn count trigger |
| `masterCompactFraction` | 0.45 | Session compaction char-budget fraction |
| `execErrorStreakNudge` | 3 | Consecutive exec-tool failures before a nudge is appended to the model's context |

---

## Internationalisation

**LLM-generated content** (session output, on-demand progress summaries,
task titles, final answers) is produced in the user's language — the
assistant model is multilingual by default and responds in whatever
language the user wrote in. No pre-turn language-detection step, no
`language` hint injected into the system prompt. Trust the model.

The Assistant still stores an ISO 639-1 `language` on every `create_task`
(it reads the user's message and picks the code itself) so the on-demand
progress summariser — a separate LLM call on a smaller model — can be
told explicitly which language to write its one-line update in. That's
the only downstream consumer of the stored field.

**Runtime-generated labels** use the `Dmhai.I18n` module — a plain-dict lookup with interpolation:

```
I18n.t("blocked_label", task.language, %{reason: "..."})
  → "Bị chặn: ..."   (vi)
  → "Bloqueado: ..." (es)
  → "Blocked: ..."   (en fallback)
```

Shipped locales: `en`, `de`, `vi`, `es`, `fr`, `ja`. Fallback chain: `lang → en → raw key`. For unsupported user languages, fixed labels fall back to English while LLM-generated content is still in the user's language (graceful degradation).

---

## Database Schema

```
sessions
  id TEXT PK          ← timestamp-based (Date.now().toString())
  user_id TEXT
  name TEXT
  model TEXT          ← legacy (admin settings drive actual model choice)
  messages TEXT       ← JSON array of {role, content, thinking?, ts, images?, kind?, task_id?}
  context TEXT        ← JSON {"summary": ..., "summary_up_to_index": N}
  mode TEXT           ← 'confidant' | 'assistant'
  created_at / updated_at

users
  id, email UNIQUE, name, password_hash, role, profile, password_changed,
  deleted, created_at

auth_tokens
  token PK, user_id, created_at

tasks                  ← system of record for all tasks in the session
  task_id TEXT PK
  user_id / session_id
  task_type TEXT       ← 'one_off' | 'periodic'
  intvl_sec INT       ← 0 for one_off
  task_title TEXT      ← short label shown in the task-list block + FE sidebar
  task_spec TEXT       ← description; verbatim user message (with 📎-prefixed
                         attachment paths appended, if any). Updated in place
                         when the assistant calls update_task(task_spec: ...).
  task_status TEXT     ← 'pending' | 'ongoing' | 'paused' | 'done' | 'cancelled'
  task_result TEXT     ← last compiled result (final Markdown answer for one_off;
                         last cycle's result for periodic). Reused in the
                         [Active tasks] block context if the task re-runs.
  time_to_pickup INT  ← unix ms; for periodic (next cycle) and any future
                         delayed-oneoff semantics. NULL for immediate-run.
  language TEXT       ← ISO 639-1 (default 'en')
  created_at / updated_at

session_progress         ← per-activity progress rows (UI + audit log)
  id INTEGER PK AUTOINCREMENT
  session_id / user_id / task_id
  kind TEXT           ← 'tool' | 'thinking' | 'summary'
  status TEXT         ← 'pending' | 'done' (tool rows only; flipped when the
                         tool call returns)
  label TEXT          ← truncated to 4k chars; the FE-renderable activity line
  ts INTEGER

master_buffer         ← notification bus (polled by frontend)
  id INTEGER PK AUTOINCREMENT
  session_id / user_id
  content TEXT        ← progress text (non-empty) | empty string (sentinel)
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

The DB schema is consolidated — no legacy `ALTER TABLE` migration chain. Wipe `~/.dmhai/` to re-init from scratch after schema changes. The `master_buffer.worker_id` column is left dormant (unused since the master/worker split was collapsed).

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
 ├── manager-tasks.js — task-list sidebar (renderTasks, polling)
 ├── manager-chat.js  — renderChat, renderSessions
 ├── manager-search.js— sendMessage streaming logic
 └── main.js          — bootstrap, event wiring
```

### Session Modes

Each session has `mode = 'confidant' | 'assistant'`. The sidebar filters by mode.

### Task-list sidebar (Assistant mode)

Section under `#sessions-list` in the sidebar, scoped to the currently-open
session. Data comes from:

```
GET /sessions/:id/tasks
→ { tasks: [task, task, ...] }    -- full Tasks.list_for_session/1 dump
```

The FE partitions the list client-side into:

- **ongoing** (most prominent; pinned at the top)
- **pending** — periodic due next (sorted by `time_to_pickup` ascending),
  then non-periodic pending, by `created_at`
- **paused**
- **Recent** (collapsible; last ~20 done/cancelled by `updated_at` desc)

Each row shows: title, status chip (colour-coded), type icon (🔁 periodic
vs ▸ one_off), and — for pending periodic — a relative pickup time
("in 45m", "now", "3h ago"). Clicking a row scrolls the chat view to the
latest `session_progress` entry for that task (if any) or highlights the
row briefly if none.

Polling cadence: `3 000 ms` while the session is open and has at least
one non-terminal task; `15 000 ms` when idle. Backoff is cooperative —
the same call is triggered opportunistically when `session_progress`
deltas arrive (tasks may have transitioned).

No push channel — the BE does not notify the FE of task changes. This
matches #90's FE-driven progress polling; we keep FE the pull side
everywhere.

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
- `/data/user_assets/<email>/<session_id>/workspace/` — session task scratch (shared across all tasks in the session)
- `/data/system_logs/system.log` — SysLog traces

---

## Testing

Test files are `test/itgr_*.exs`. Harness in `test/test_helper.exs` provides:

- `T.stub_llm_call/1` + `T.stub_llm_stream/1` — replace LLM calls with deterministic stubs.
- `T.tool_call/3` — build a normalised tool-call map matching `LLM.normalize_tool_calls` output.
- `T.session_data/1` — build a session fixture.

Coverage:

| Area | File |
|------|------|
| Session turn loop (tool-call roundtrips, text termination, max-rounds cap) | `itgr_session_loop.exs` (#101; replaces `itgr_worker_loop.exs`) |
| Task runtime (Tasks CRUD, periodic scheduler, mark_done auto-reschedule) | `itgr_task_runtime.exs` |
| Context compaction (session-level) | `itgr_compaction.exs` |
| Confidant pipeline | `itgr_confidant_flow.exs` |
| Context engine message building (incl. [Active tasks] injection) | `itgr_context_engine.exs` |
| Tool capability (real LLM, network-gated) | `itgr_tool_capability.exs` |
| i18n (translation coverage, language propagation) | `itgr_i18n.exs` |
| Web fetch (CMP detection, reader, fallback, real sites under `:network` tag) | `itgr_web_fetch.exs` |

Test env (`config/test.exs`):
- `enable_task_rehydrate: false` — disables boot rehydration during tests.

Run filters:
- Default: `mix test` skips `:network`-tagged tests.
- Full: `mix test --include network` hits real sites (BBC, Reuters, Guardian, NYT, Le Monde, Wikipedia).
