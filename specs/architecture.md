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
>   - The assistant uses a verb-based task API (`create_task`,
>     `pickup_task`, `complete_task`, `pause_task`, `cancel_task`,
>     `fetch_task`) to manage the list, and the full tool catalogue
>     (`web_fetch`, `run_script`, etc.) to execute work.
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
>     assistant naturally cancels the old task (`cancel_task`) and
>     creates a fresh one (`create_task` → `pickup_task`) in its next
>     turn.
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
                    ExtractContent, SpawnTask,
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
    ├── RateLimit plug        — per-user (token-keyed) sliding window,
    │                           falls back to per-IP for pre-auth paths.
    │                           See §Rate limiting below for tiers.
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
  current_task:    nil | {ref, task_pid, reply_pid, session_id}
  platform_state:  %{telegram: %{...}, ...}
```

It accepts two **distinct** dispatch messages — one per mode — and routes
each to its own pipeline function. There is **no shared dispatcher** that
inspects the command to decide which pipeline to call. There is no
interrupt dispatch; see §Mid-chain user message injection below for how
user corrections land while a chain is in flight.

```
handle_call({:dispatch_assistant, %AssistantCommand{} = cmd}, …)
  → if current_task: queue (see §Mid-chain); reply :ok
    else Task.Supervisor.async_nolink(TaskSupervisor, fn ->
           run_assistant(cmd, state, session_data)
         end)

handle_call({:dispatch_confidant, %ConfidantCommand{} = cmd}, …)
  → Task.Supervisor.async_nolink(TaskSupervisor, fn ->
      run_confidant(cmd, state, session_data)
    end)
```

`run_assistant/3` and `run_confidant/3` do not call into each other and do
not share any helper that knows about the other path. Confidant is a
one-shot streaming reply per request — it has no chain, no queue, and
its busy-reply contract is out of scope for mid-chain injection.

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
   text turn (chain end) completes, the accumulated text is appended to
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
- `stream_buffer`: partial text of the in-flight final-answer turn.
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

- New `messages` delta is merged into `currentSession.messages` by ts —
  **dedup-guarded**: before pushing an incoming message, check whether
  `session.messages` already contains an entry with the same `ts`; skip
  the push if so. Required because two polling loops coexist
  (`pollTurnToCompletion` during an active turn, `startProgressPolling`
  between turns) — each with its own `msg_since` baseline — and a
  handoff race can otherwise let both fetch the same just-persisted
  message and double-push it.
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

**Compaction** triggers when `recent_turns > masterCompactTurnThreshold (50)` OR
`recent_chars > masterCompactFraction (45%) of (estimatedContextTokens × 4)`.
The char-budget side derives from `AgentSettings.estimated_context_tokens()`
(default `64_000`, tunable so operators can match the actual model's window;
multiply by ~4 chars/token to get the char budget). `compact!` calls the
compactor LLM (`AgentSettings.compactor_model()`, NOT hardcoded) and writes
`{"summary", "summary_up_to_index"}` to `sessions.context`. The most recent
`@keep_recent = 20` messages are always left outside the summary so fresh
context is preserved. Old messages are retained in the DB and remain
available for keyword retrieval.

**Tool-result retention (`Dmhai.Agent.ToolHistory`)** — orthogonal to
compaction. Retains the last N turns' raw `tool_call` / `tool_result`
message pairs in the `sessions.tool_history` JSON column so the next
turn can inject them back into the LLM input — the model answers
immediate follow-ups without re-running the tool.

- `UserAgent` snapshots a turn's tool messages into `ToolHistory.save_turn/4`
  right after persisting the final assistant text; the save function
  trims to `AgentSettings.tool_result_retention_turns()` (default `5`) and
  a byte budget `AgentSettings.tool_result_retention_bytes()` (default
  `120_000` chars).
- `ContextEngine.build_assistant_messages/2` calls
  `ToolHistory.inject/2` to interleave each saved entry back into
  `history_llm` **immediately before its matching assistant-text message**
  (matched by `ts`). This reconstructs the OpenAI-style
  `user → assistant(tool_calls) → tool(result) → assistant(final text)`
  shape models expect.
- **Contract**: `build_assistant_messages/2` REQUIRES `session_data["id"]`
  (non-empty binary) and raises `ArgumentError` if it's missing. The id
  drives both `ToolHistory.load/1` and the `## Recently-extracted files`
  block — silently skipping them would disable Phase-3 features without
  any visible symptom. Loud-failure contract prevents the regression we
  hit when `UserAgent.load_session/2` forgot to populate the key. The
  loader, and any direct test-side session_data construction, must
  include `"id"`.
- Entries age out naturally past the N-turn window; pathological
  extraction marathons are bounded by the byte budget (oldest-first
  eviction).
- Independent budget from compaction: compaction's char trigger counts
  only `session.messages` text — tool_history is a separate ceiling.

**First-class `tasks.attachments` column** — JSON array of workspace/data
paths. Source of truth for `fetch_task`, the task-list block
`**Attachments:**` line, and `extract_content`'s dedup scan. Previously
derived via regex from `task_spec` text, which broke when the model
flattened newlines and left `📎` mid-line. `create_task` writes the
validated `attachments` argument directly into the column — no merging
into task_spec. Legacy rows (pre-migration) fall back to the regex
parser so existing tasks keep working. `AttachmentPaths.clean_spec/1`
scrubs any `📎 ` references the model embeds in `task_spec` so the
stored spec is pure prose.

**Per-session human-readable `tasks.task_num`** — monotonic integer from 1,
shown as `(N)` in the task-list block and FE sidebar. Users reference
tasks by number ("tell me more about task 1", "redo task (2)");
`system_prompt.ex` teaches the model to map these references to the
matching `task_id` from the block.

**Runtime `## Recently-extracted files` directory** — generated on each
turn by `ContextEngine.build_recently_extracted_block/3` from the
current `tool_history` state. Lists every file whose `extract_content`
tool_call appears in the retention window, cross-referenced to its
originating task_num. Empty on non-extraction sessions. Injected
between the task-list block and the current user message as a
user/assistant pair ("Understood."). Purpose: give the model a
self-expiring directory of "files whose raw content is in my
retained `role: "tool"` messages right now" so it answers
follow-ups from retained content instead of re-running
`extract_content`.

**Generic Police schema validation** (`check_tool_call_schema/2`) —
validates every tool_call against the tool's declared
`definition/0`. Catches missing required args and wrong types.
Generates a schema-driven nudge example from the tool's own property
descriptions (no hardcoded values — `<string>` / `<integer>` /
`[...]` placeholders plus verbatim `description` lines). Tagged
rejections (`{issue_atom, reason}`) flow through `execute_tools/2`
into the message marker `[[ISSUE:<atom>]]`, which `session_chain_loop`
strips from the model-visible message AND counts in `ctx.nudges`.
Once any issue's counter hits `@model_behavior_nudge_limit = 3`,
`maybe_abort_on_model_behavior_issue/2` terminates the turn,
persists the user-facing "Internal AI model error" message, and
emits `[ModelBehaviorIssue] type=<atom> model=<...> session=<...>
count=<n>` at error level plus a `[CRITICAL]` SysLog entry.
Purpose: during the dev phase, surface which models trip which
rules and how often — primary data for production model selection.

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

## Chain loop

**Terminology** (used consistently throughout the codebase):

- **turn** — one LLM roundtrip: one `LLM.stream` call + the tool
  execution it triggers. A turn either produces `tool_calls` (and
  recurses into the next turn) or produces user-facing text (ending
  the chain).
- **chain** — a sequence of turns that begins when a user message (or
  scheduler-triggered `{:task_due}`) lands and ends when the assistant
  emits user-facing text. A simple ask resolves in one chain; a
  complex multi-step objective can span many chains with user
  refinements between them.
- **task** — a persistent objective row, created with `create_task`,
  spans many chains. Lifecycle is verb-driven
  (`pickup_task → exec tools → complete_task`).

```
incoming:
  {:dispatch_assistant, %AssistantCommand{...}}
  OR
  {:task_due, task_id}                ← scheduler; no user text
  OR
  {:auto_resume_assistant, session_id} ← Phase 2 auto-resume
                                         (unanswered user msg detected)

  ▼
UserAgent.run_assistant(cmd, state, session_data)
  │
  ├── build context (§Context assembly)
  │     system prompt + history + [Active tasks] block + current input
  │
  └── session_chain_loop(messages, model, ctx, turn=0):
        │  (at top of each turn:) splice_mid_chain_user_msgs/2 —
        │     fold any user messages persisted to session.messages
        │     after the chain started into `messages`.
        │
        LLM.stream(model, messages, collector, tools, ...) →
          ┌─ {:tool_calls, calls} ─┐
          │   collector cleared (defensive), execute each call,
          │   append tool result, recurse into turn+1
          └─ {:text, text} ─┘
               collector accumulated the text into sessions.stream_buffer
               progressively during generation → FE polling rendered it
               in real time → now persist the final message to
               session.messages + clear stream_buffer → CHAIN DONE

  Return value: {:chain_done, watermark_ts} where watermark_ts is the
    max user-ts in the chain's final `messages` list (the highest user
    message ts the chain's LLM calls actually saw). The GenServer's
    chain-complete hook uses it against DB state to detect "a user
    message landed AFTER the chain finished consuming input" and
    trigger an auto-resume.

  Safety cap: max_assistant_turns_per_chain (default 50) — if hit,
  abort with a "let's continue next time" message.
```

Uses `LLM.stream` (not `LLM.call`) on every turn — same pattern as
Confidant — so that the final-answer text turn streams tokens into
`sessions.stream_buffer` as they're generated. The FE polling loop
renders progressive text with the same "thinking…" → "streaming the
answer…" status flip as Confidant. Tool-call turns emit no content
tokens, so `stream_buffer` stays empty through them and `LLM.stream`
just returns `{:ok, {:tool_calls, …}}` — identical to what `LLM.call`
used to return.

The chain is strictly sequential: the model emits tool calls, tools
run, results come back, the model emits the next turn (or text). Text
output ends the chain — no "must end with signal" rule.

If a new user message arrives while a chain is in flight, it is spliced
into the working `messages` list at the START of the next turn in the
same chain — the next LLM call sees it as context. See §Mid-chain user
message injection for the full semantics.

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

### Identity (Phase 3, planned — 2026-04-24+)

A task is addressed by its **per-session integer** `task_num` `(N)`.
This is the only identifier the user sees, the model sees, and the
tools take as an argument.

- **`task_num`** — `integer`, per-session monotonic from 1, generated at
  `create_task` time. Rendered as `(N)` in prompts, chat UI, logs
  shown to humans. Users refer to tasks as "task 1" / "task (2)".
  Tool schemas (`pickup_task`, `complete_task`, `pause_task`,
  `cancel_task`, `fetch_task`) all take `task_num: integer` — never a
  cryptic id.
- **`task_id`** — `string`, cryptic, DB primary key. **Internal only.**
  Foreign keys on `session_progress.task_id`, `tool_history`, and the
  new `task_turn_archive` still use this for global uniqueness and
  audit stability across sessions. Never surfaced to the user or model
  and never appears in prompts / chat.
- **Boundary resolution.** Every tool handler accepting `task_num`
  resolves `(session_id, task_num) → task_id` at the BE boundary
  (helper: `Tasks.resolve_num/2`) before any DB work. If the `task_num`
  doesn't exist for the session, the tool returns a crisp "no task (N)
  in this session" error — impossible to collide across sessions,
  impossible to hallucinate a plausible-looking string id.
- **Operator logs (SysLog, `[POLICE]`, telemetry) KEEP `task_id`** for
  global uniqueness. These are operator-facing, not user- or
  model-facing.

Rationale: the model was previously asked to map the user's `(N)`
reference to the task list's cryptic `task_id` on every tool call.
Observationally it did this correctly but it's an avoidable failure
surface. Using `task_num` end-to-end removes the mapping step — Police's
schema check rejects non-integers cleanly, and the BE resolver rejects
non-existent numbers with a specific error.

### Status transitions

```
task_status transitions (verb-based API, 2026-04-24):

  (no state)──► pending   (create_task)
                   │
                   │  pickup_task
                   ▼
                ongoing   ──► done       (complete_task — one_off)
                   │          │
                   │          └─ complete_task on a periodic row
                   │             auto-reschedules via Tasks.mark_done:
                   │               status=pending,
                   │               time_to_pickup=now+intvl_sec,
                   │               TaskRuntime.schedule_pickup
                   │
                   ├──► paused    (pause_task)
                   │
                   ├──► cancelled (cancel_task)
                   │
                   └──► (stays ongoing; the assistant may go idle
                         waiting for next user turn)

  pending ◄── (periodic auto-reschedule OR pickup_task on a done
               task, which reopens it to ongoing for rework)
      │
      └── when scheduled pickup fires (time_to_pickup reached),
          UserAgent injects a {:task_due} silent turn which calls
          Tasks.mark_ongoing at pickup start; model then produces
          the task's output via execution tools and closes with
          complete_task (auto-reschedules for periodics).
```

Key properties:

- **`create_task` inserts with `task_status='ongoing'`** (Phase 3 lever
  2b, 2026-04-24+). The task is created AND started in one verb: the
  model can run execution tools right after `create_task` with no
  separate `pickup_task` call. `pickup_task` remains the verb for
  RESUMING previously done / paused / cancelled (and idempotent
  re-pickup of ongoing). Collapsing the two into one tool-call turn
  saves ~8 k input tokens on every fresh-session opener (previously
  `create_task → pending` then `pickup_task → ongoing` required two
  LLM roundtrips, each re-shipping the full system prompt + tool
  schemas). The tool's **returned map is self-describing** —
  `{task_num, status: "ongoing", do_not: "call pickup_task — task is
  already ongoing", ...}` — because prompt-only guidance alone did
  not stop 14 B-class models from reflexively firing `pickup_task(N)`
  as the next turn. Weak models anchor on the immediate tool result
  far more than on the system prompt (which is far away in the
  context window), so the instruction is repeated at the point of
  decision. The hint is **prohibitive only** — an earlier positive
  variant ("call run_script / web_search directly") over-prescribed
  the path: the model took it as "next call MUST be run_script" and
  skipped natural intermediate tools (`lookup_credential`,
  `read_file`, `extract_content`), folding credential lookup INTO
  the bash script as a shell command.
- **`Tasks.mark_done/2` is the single source of rescheduling for periodic
  tasks.** The assistant doesn't call a separate reschedule tool — it just
  updates status to "done", and the mark_done implementation branches on
  `task_type`.
- **Best-effort scheduling.** If `time_to_pickup` arrives while the session
  is mid-turn on another task, the pickup waits in the mailbox until the
  current turn completes. On the next turn the assistant sees a pending
  periodic in its task list with pickup in the past and acts on it.
- **Runtime auto-close of forgotten-done tasks.** If the session-turn
  loop finishes a text turn (chain end) while any task owned by this session is
  still in `ongoing` status, `auto_close_ongoing_tasks/2` sweeps those
  tasks and calls `Tasks.mark_done/2` with the first 500 characters of
  the assistant's final text as `task_result`. Catches the failure mode
  where the model did the work but forgot to explicitly call
  `complete_task` before emitting its answer — a compliance gap that
  otherwise leaves rows stuck in the sidebar indefinitely. Periodic
  tasks re-schedule themselves via
  `Tasks.mark_done/2`'s built-in branch, so the auto-close path works
  for them too (ongoing → pending + bumped pickup).
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

Verb-based API (2026-04-24): each lifecycle transition is its own tool.
The runtime owns the state machine — the model picks a verb, Police
rejects invalid transitions with educational nudges.

All lifecycle verbs take **`task_num: integer`** (per-session,
user-visible `(N)` — see §Task lifecycle §Identity). Only `create_task`
returns a `task_num` rather than taking one.

| Tool | Args | Effect |
|------|------|--------|
| `create_task` | `task_title`, `task_spec`, `task_type` (one_off\|periodic), `intvl_sec`, `language`, `attachments?` | Insert a task row (**status=pending**, time_to_pickup=now). Attachments (if any) are validated (must start with `workspace/` or `data/`) and `📎 <path>` lines are appended to the stored `task_spec`. **Returns `task_num` `(N)`** — the per-session integer the model will use for all subsequent verb calls. Creation does NOT start execution — the model must call `pickup_task(task_num: N)` next. |
| `pickup_task` | `task_num` | Flip the target task → `ongoing`. Idempotent: already-ongoing returns ok without a write. Permissive: accepts `pending`, `paused`, `done`, `cancelled` and reopens them (the "resume / redo" path). Only failure is "no task (N) in this session." |
| `complete_task` | `task_num`, `task_result`, `task_title?` | Close the task. One_off → `done`. Periodic → auto-reschedule branch: `status=pending`, `time_to_pickup=now+intvl_sec`, timer re-armed. Optional `task_title` refines the stored title at close (e.g. "Research X" → "Found 3 candidates"). Rejects terminal tasks (done / cancelled). |
| `pause_task` | `task_num` | Flip the target task → `paused`. Only `ongoing` / `pending` are accepted. Terminal and already-paused tasks are rejected. |
| `cancel_task` | `task_num`, `reason?` | Flip any non-terminal task → `cancelled`. `reason` is stored as `task_result` (defaults to "Cancelled by user"). |
| `fetch_task` | `task_num` | Read-only, resumable view of a task. Returns: metadata (title, status, type, attachments, `task_result`), **archive** (verbatim pre-compaction turns stitched from `task_turn_archive`), **live** (current session.messages filtered by this task's tag), and **tool bodies** (tool_history entries tagged with this task, within retention). See §Task state continuity. Use when the Task-list block's summary isn't enough OR when the anchor named a task whose history isn't in the current LLM context. |

## Active-task anchor (Phase 3, planned)

The runtime — not the model — decides which task is the current focus
of a chain. It communicates this decision to the model through a
single, unambiguous prompt block we call the **anchor**, injected by
`ContextEngine.build_assistant_messages/2`.

Exact shape of the anchor block (rendered as a synthetic user message
at the end of the context, immediately before the real current user
message):

```
## Active task

- Current task: (N)
- Your recent activity on this task (prior tool calls, results,
  narration) is already present in the conversation above. Answer /
  act from it directly.
- Call `fetch_task(task_num: N)` ONLY as a fallback: if you need a
  specific past decision or tool output that was compacted away
  (older turns no longer visible in your context).
```

**Why non-leading wording matters.** An earlier draft said "If you
don't see this task's details, call `fetch_task`" — that phrasing
acted as encouragement: weaker models reflexively fetched on every
chain because "if you don't see" is permissive. With recent activity
already injected via `ToolHistory.inject/2`, fetching was redundant.
The current wording anchors the default ("already present, act from
it") and frames `fetch_task` as a compaction-recovery fallback, not a
routine step.

Rules:

- **Exactly one current task at any moment.** No "come back to X after
  Y" hint in the prompt — that's runtime's job to arrange automatically
  via the back-reference chain described below. The model's cognitive
  scope is the single named task.
- **Runtime sets the initial anchor at chain start.** Possible
  sources, in priority order:
  - Scheduler-triggered silent pickup (`{:task_due, task_id}`): anchor
    = that task.
  - Chain-complete auto-resume (Phase 2 mid-chain splice path): anchor
    = the task the chain-that-just-ended was working on.
  - User-initiated chain on a session with exactly one active
    (pending/ongoing) task: anchor = that task.
  - Otherwise (no active task OR ambiguous): anchor is OMITTED. Model
    operates in "free" mode — its next meaningful action will be
    `create_task` (or a pure chat reply).
- **Anchor is MUTABLE during a chain** (2026-04-24 revision), driven
  by verb tool calls — see §Anchor mutation and the `back_to_when_done`
  back-stack below.
- **Anchor mutation triggers a refreshed `## Active task` block at the
  next turn boundary**, so subsequent LLM calls within the same chain
  see the updated anchor value. Both the prompt-side block AND the
  runtime-side `ctx.anchor_task_num` (used for per-message tagging
  and Police scope) stay in sync.
- **Anchor is not persisted as such** — it's a derived, recomputed
  value. But its back-reference stack IS persisted on each task
  (see `back_to_when_done_task_num` column in §Database Schema) so
  the "where to go back to after I'm done" graph survives restarts.

### Anchor mutation via `back_to_when_done` back-stack

Each task row carries a nullable **`back_to_when_done_task_num`**
(per-session integer, FK-style to `tasks.task_num`). Set at
`pickup_task` time; read at `complete_task` / `cancel_task` /
`pause_task` time. Models a back-stack "while I work on T, remember
that Y was the anchor before me — when I'm done, the anchor returns
to Y."

Transitions:

- **`pickup_task(N)` succeeds.** Behavior:
  - If `N` was already ongoing (idempotent re-pickup): no back-ref
    update — we don't want to overwrite the original back-ref on
    repeated pickups.
  - If `N` is transitioning from a non-ongoing state (pending /
    paused / done / cancelled): read `ctx.anchor_task_num` (the
    anchor BEFORE this pickup). If it's a real task_num AND differs
    from `N`, persist it as `tasks[N].back_to_when_done_task_num`.
  - Set `ctx.anchor_task_num = N`. Refresh the prompt's
    `## Active task` block at the top of the next turn iteration.
- **`complete_task(N)` / `cancel_task(N)` / `pause_task(N)` succeeds
  AND `N == ctx.anchor_task_num`** (the verb targets the current
  anchor, not some other task):
  - Read `tasks[N].back_to_when_done_task_num` → call it `prev`.
  - Set `ctx.anchor_task_num = prev` (may be `nil`).
  - Refresh the prompt's `## Active task` block at the top of the
    next turn iteration — if `prev` is `nil`, the refreshed block
    says "Current task: none" (free mode).
- **`complete_task(N)` etc. succeeds BUT `N != ctx.anchor_task_num`**
  (e.g. the model closes some OTHER task than the current anchor):
  no anchor change. Leave the back-stack alone.

Worked example — user's nextcloud scenario:

```
User creates task 1 (nextcloud setup)  → ctx.anchor = 1, tasks[1].back = nil
User creates task 2 (joke/30s periodic):
  pickup_task(2)                       → tasks[2].back = 1 (stored), anchor = 2

[silent joke pickup chain]:
  complete_task(2)                     → anchor = tasks[2].back = 1
  [periodic auto-reschedules for next cycle]

Next silent joke pickup chain:
  pickup_task(2)                       → tasks[2].back already = 1; no overwrite
  complete_task(2)                     → anchor = 1

User eventually says "cancel the jokes":
  cancel_task(2)                       → anchor = tasks[2].back = 1

User completes nextcloud setup (much later):
  complete_task(1)                     → anchor = tasks[1].back = nil → free mode
```

Consequence: when the pickup task of a silent chain is closed, the
chain's runtime anchor naturally returns to whatever was ambient
before. The model's subsequent messages tag + the Police scope flip
together. No orphan tags; no phantom "Task (2): [Docker work]"
mislabels.

### Scheduler — don't stack periodic pickups

When `TaskRuntime` fires a periodic timer, before dispatching
`{:task_due, task_id}` to the UserAgent it checks: **is any other
periodic task in this session already in `ongoing` state?** If yes,
skip this firing (the prior cycle hasn't finished). The missed cycle
isn't made up for; the next natural timer cycle handles it. Prevents
overlapping periodic silent chains in the same session.

One_off tasks in `ongoing` state do NOT block periodic pickup — the
periodic interrupts, does its work, and returns to the one_off via
the back-stack.

### Periodic + long-running coordination (Approach A)

When a periodic task is due while a long-running one_off task is
`ongoing`, the runtime:

1. Picks up the periodic as a silent turn (current behaviour).
2. Sets the anchor to the periodic's `task_num`.
3. The long-running task's status stays `ongoing` (no implicit
   pause). It's just not the anchor for this chain.
4. When the periodic's chain completes (`complete_task` → auto-
   reschedule), the NEXT chain's context build re-resolves the anchor
   via the priority rules above — typically returning to the long-
   running task on the next user interaction.

No `pause_task` / `pickup_task` dance needed between model-facing
transitions; coordination is runtime-owned and invisible to the model
beyond the anchor block flipping.

Approach B (strict sequential — periodic blocks until long-running
is done) was considered and rejected: users expect periodics to fire
on time, and the anchor is strong enough signal to scope the model
without requiring it to orchestrate the handoff itself.

## Per-message task tag (Phase 3, planned)

Every **user** and **assistant** message persisted to
`session.messages` during an anchored chain carries a `task_num`
field alongside `role`, `content`, `ts`. Tool-result messages (kept in
`tool_history`, not `session.messages`) are tagged by the anchor of
their owning chain at save time.

### How the tag is set

- **User messages**: `/agent/chat` handler resolves the current anchor
  at persistence time (same logic `ContextEngine` uses to build the
  anchor block). If an anchor exists, the stored message carries its
  `task_num`. No anchor → untagged (pure chat).
- **Assistant messages**: `session_chain_loop` persists with the
  anchor's `task_num`. Both the final text turn AND the narration-
  before-tool-call turns (Phase 2 fix).
- **Tool history**: when `collect_tool_messages` snapshots a chain's
  tool messages at chain end, the chain's anchor `task_num` is
  recorded on the entry. **The input to `collect_tool_messages` MUST
  be `Enum.drop(messages, ctx.chain_start_idx)`** — not the full
  `messages` list. `messages` at chain end contains the tool_history
  re-injected by `ContextEngine.build_assistant_messages` from PRIOR
  chains; slicing by `chain_start_idx` isolates this chain's own
  tool_calls. Without the slice, successive chains stack prior
  chains' tool_calls into their own saved entries — causing
  duplicated re-injection in future context builds (entry 1 and the
  bloated entry 2 both re-splice the same chain-1 tool_calls). See
  the fix in `UserAgent.session_chain_loop`.

### What the tag is used for

1. **Model self-focus.** Prompt rule: *"When scanning your own prior
   messages in context, ignore any whose `(N)` tag differs from the
   current anchor. Those are from a different task the runtime
   interleaved; not yours to reason about on this chain."* Assistant
   messages render with the tag visible to the model as
   `"[task (N)] ..."` at context-build time.
2. **FE user focus.** Chat UI renders the message prefix as
   `"[12:39] <icon> Assistant — on task (N):"` (i18n key `onTask`).
   User sees at a glance which task an assistant reply belongs to.
3. **Archive partitioning (see §Task state continuity).** Compaction
   groups `to_summarize` messages by `task_num` and snapshots each
   group to `task_turn_archive` before summarising.
4. **`fetch_task` filtering.** Live messages + tool_history entries
   for a task are retrieved by matching `task_num`.

### Why tag users AND assistants

Tagging only assistant messages would break archive/fetch partitioning
— user refinements and decisions are critical context for resuming a
task, and without a tag they'd either get summarised into the master
session summary (losing detail) or leak across tasks. Handler-side
tagging (via the anchor at persist time) solves this without asking
the model to annotate its own inputs.

## Task state continuity across chains (Phase 3, planned)

**Problem.** A task that spans many chains (e.g. nextcloud setup with
30+ interleaved periodic pickups) eventually has its oldest activity
aged out of the LLM's working context: `session.messages` crosses
`ContextEngine.should_compact?`, the compactor LLM summarises the
oldest range into `session.context.summary`, and `tool_history` entries
roll out of their retention window. When the model later calls
`pickup_task` on the long-running task, its view of *what it already
did* has been lossy-compressed.

**Solution.** A per-task, append-only raw archive: `task_turn_archive`.

### Hook — `ContextEngine.compact!`

Before invoking the compactor LLM on the `to_summarize` slice:

1. Group `to_summarize` by each message's `task_num` field.
2. For each non-nil group, resolve `(session_id, task_num) → task_id`
   and append each message verbatim to `task_turn_archive` keyed by
   that `task_id`.
3. Proceed with the summarisation as before.

Untagged messages (pure chat) don't land in any archive; they're only
represented via the master session summary. Acceptable — they weren't
task work.

### Hook — `tool_history` eviction

`tool_history` maintains a bounded retention window (last N chains).
When the retention window drops a chain, look up the chain's anchor
`task_num`; if present, snapshot the chain's `tool_call` / `tool_result`
messages to `task_turn_archive` under that `task_id`. Drop untagged
chains' tool messages as today.

### Schema — `task_turn_archive`

```sql
CREATE TABLE task_turn_archive (
  id           INTEGER PRIMARY KEY,
  task_id      TEXT NOT NULL,           -- cryptic BE id (FK)
  session_id   TEXT NOT NULL,
  original_ts  INTEGER NOT NULL,        -- the message's own ts when originally written
  role         TEXT NOT NULL,           -- user / assistant / tool
  content      TEXT,                    -- nullable for tool_calls-only messages
  tool_calls   TEXT,                    -- JSON, present on role=assistant when tool_calls were emitted
  tool_call_id TEXT,                    -- present on role=tool
  archived_at  INTEGER NOT NULL
);
CREATE INDEX idx_task_turn_archive_task_ts ON task_turn_archive(task_id, original_ts);
```

Append-only. Eviction is sliding-window drop — no LLM summarisation.

**Per-task sliding cap.** At every `append_raw/3`, a post-insert
`prune/1` trims the task's archive to the tighter of:

- `taskArchiveRowCap` (default 60 rows — approx 30 user+assistant pairs)
- `taskArchiveByteCap` (default 120 000 bytes, summed over `content`)

Rows are walked newest → oldest; we keep rows while under BOTH caps;
everything older than the last kept row is dropped (`DELETE … WHERE
id < min_keep_id`). A single heavy row (pasted 80 KB paragraph,
massive JSON dump) shrinks the effective window further by triggering
the byte cap first. Drop is terminal — no resurrect, no second-tier
storage. Users with tasks whose relevant history predates the
sliding window will see `fetch_task` return only the live + recent
archive slice; older decisions compact into the master session
summary via the usual `ContextEngine.compact!` path.

### `fetch_task(task_num)` — the stitched view

Response sections, in assembly order:

1. **Metadata**: `task_num`, title, type, status, result, attachments,
   `intvl_sec`, `time_to_pickup`.
2. **Archive**: rows from `task_turn_archive` for this `task_id`,
   ordered by `original_ts` ASC. Capped for safety at the most-recent
   K entries if the archive has grown large; older entries are
   represented by their most-recent predecessor only (no summarisation
   v1).
3. **Live conversation**: entries from `session.messages` whose
   `task_num` matches AND `ts` is after the archive's latest
   `original_ts`. Ensures no duplicate between archive and live.
4. **Live tool bodies**: `tool_history` entries tagged with this
   `task_num`, within the current retention window.

Presented to the model chronologically end-to-end. The model reads
this response like a dense replay of its own work on this task —
decisions, tool outputs, user refinements — regardless of how many
unrelated chains interleaved in between.

## Prompt teaching model for Phase 3 (planned)

The system prompt's `## Tasks` section must teach the model a clean
hierarchy — terminology → identity → workflow → edge cases — in that
order. The structure below is normative for the prompt rewrite that
accompanies the Phase 3 implementation. Prompt copy will approximate
but not necessarily match verbatim.

### Level 1 — Terminology

- **task**: a persistent objective row. Spans many chains. Has a
  per-session number `(N)` — that's how you and the user refer to it.
- **chain**: your path from seeing a user (or `[Task due]`) trigger
  through to emitting your final user-facing text. Many turns per
  chain.
- **turn**: one of your LLM roundtrips inside a chain — an
  `LLM.stream` call + any tool execution it triggers.
- **anchor**: a runtime-injected block at the end of your context
  naming the ONE task this chain is for. Trust it.

### Level 2 — Identity

- Tasks are addressed by **`task_num` — the per-session integer**
  `(1)`, `(2)`, `(3)`. The user says "task 1" / "task (2)"; you use
  `1`, `2` in your tool args.
- **Never invent or guess a `task_num`.** The only valid values are
  those listed in the Task list block or returned to you by
  `create_task`.
- You will NOT see any cryptic string id in your context. That's
  deliberate — it's a BE-internal detail.

### Level 3 — Workflow

- **Read the anchor FIRST.** It says `Current task: (N)`. Everything
  you do this chain is for that task — including tools called,
  narration emitted, and `complete_task` call.
- **If you don't have the task's details in your context**, call
  `fetch_task(task_num: N)`. Returns metadata + archive of older turns
  + live activity + tool bodies. Read it and proceed.
- **Mid-chain user refinements** (multiple user messages since your
  last reply) are refinements of the SAME anchored task. Don't treat
  them as fresh asks. Let them redirect your next step.
- **`complete_task` means DELIVERED.** If your reply asks the user
  anything, do NOT call `complete_task` this chain — leave the task
  `ongoing`. The anchor will be set back to this task on the next
  chain once the user replies.

### Level 4 — Focus rule (when scanning own history)

Assistant messages in your context carry a `(N)` tag. When reading
your own prior messages:

- **If the tag matches the anchor** → it's your prior work on this
  task; read it.
- **If the tag differs** → the runtime interleaved a different task
  there (e.g. a periodic pickup). Do NOT reason about that content
  on this chain; it's not yours to advance.

### Level 5 — Edge cases

- **No anchor in context** → free mode. You're on a fresh session
  with no active task, or the user is chatting without a tracked
  objective. Your next meaningful action is usually `create_task` (or
  just answer directly if it's small).
- **Anchor is a task you don't recognise** → `fetch_task(task_num: N)`
  first, then act.
- **Anchor flipped to a periodic while you were mid-thought on a
  different task** — doesn't happen within a chain (anchors only
  change AT chain boundaries). If you perceive a mismatch, call
  `fetch_task` and trust the anchor.

---

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
the assistant reuse that same `task_num`:

- Task still pending / ongoing / paused → `pickup_task(task_num: N)` to
  continue, then `complete_task(task_num: N, task_result: …, task_title: …)`
  when done (the optional `task_title` is where the refined scope gets
  persisted).
- Task already done → `pickup_task(task_num: N)` to reopen it to
  `ongoing`; execute; `complete_task(task_num: N, ...)` when finished.
  For a periodic task, reopening from `done` keeps the existing
  `time_to_pickup` — the schedule resumes from its last value.

Follow-ups that only *look* related to a done task are NOT redos — they
get their own `create_task`.

### Attachment routing

**FE file-format gate** (`manager-chat.js :: handleFileSelect`). Before
uploading, the FE decides if the file is supported:

1. Known-format fast paths: image extension (`.png/.jpg/.jpeg/.gif/…`),
   `file.type` starts with `video/` or `text/`, PDF magic bytes, office-
   format (DOCX/XLSX via ZIP signature + internal XML detection).
2. **Content sniff fallback** — for files that match none of the
   above (e.g. `.json`, `.yaml`, `.toml`, source-code files, logs
   without a common extension), read the first 4 KB and check whether
   it's textual: zero NULL bytes AND ≥90% of bytes are printable
   ASCII / tab / newline. If yes, treat as text and upload normally.
3. Otherwise: reject with a modal dialog ("Sorry, we do not support
   this format. Could you please try another file?") and do NOT
   upload. This is the "better safe than sorry" guard — the BE still
   has `extract_content`'s fallback for oddly-extensioned text, but
   binary garbage that would explode at tool-call time is blocked at
   the edge.

**Uniform attachment pipeline — no format-specific shortcuts.** In
Assistant mode every attachment — image, video, PDF, DOCX, XLSX, plain
text, anything else that passed the sniff — follows the same path:

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
   a `create_task` → `pickup_task` → `extract_content` → `complete_task`
   cycle when the read is part of a substantive action.

The routing inside `extract_content` (image / video / pdf / pandoc-doc /
plain-text branches) is an implementation detail — the model's mental
model is "one path per attachment, one tool call to read, one task per
substantive action". No attachment type is ever auto-injected into the
LLM context in Assistant mode.

#### Distinguishing fresh vs stale `📎 ` lines

The model can see `📎 ` lines in every user message — current AND
historical (they stay in `session.messages` forever). Without a fresh
vs stale signal, the model tends to trust its prior-turn memory of a
file ("I already extracted it once") and skip re-reading when the user
re-attaches the same path. That's wrong — re-attaching is an explicit
signal the user wants another look.

**Mechanism: context-build-time transient marker**. At
`ContextEngine.build_assistant_messages/2` (called at the start of
every turn), the LLM input array is built from `session.messages`. At
that build step we rewrite each `📎 ` line in the **last** user message
only to `📎 [newly attached] workspace/...`. Prior user messages keep
their bare `📎 ` lines.

- No DB mutation — `session.messages` is untouched. Marker lives purely
  in the ephemeral LLM message array for this turn.
- Self-expiring — on the next turn, a different user message becomes
  "last". The previously-marked message now renders bare in the LLM
  input. No stale markers.
- Deterministic signal for the model AND for the Police
  `check_fresh_attachments_read/2` gate: the set of "fresh attachments
  this turn" is exactly the `📎 ` paths in the last user message.
- **Persistence-boundary sanitisation** — models occasionally copy the
  marker verbatim into tool-call arguments they're building (e.g. they
  paste `task_spec: "📎 [newly attached] workspace/foo.pdf"` into a
  `create_task` call, echoing what they saw in their input). The
  `create_task` handler strips the ` [newly attached]` literal from any
  `📎 ` line in `task_spec` before writing to the DB. The marker is
  invalid as persisted data — only the context-builder may emit it,
  only for the current turn's last user message.
- **Post-normalise empty-spec guard** — `AttachmentPaths.normalise_spec/2`
  strips all `📎 ` lines from the input because the `attachments`
  argument is authoritative. A failure mode: the model packs the
  attachment path into `task_spec` as a `📎 ` line AND leaves
  `attachments` empty — normalisation then produces `""` and a garbage
  task row is persisted. `create_task` re-checks the normalised spec
  for non-emptiness and rejects with a nudge ("paths belong in
  `attachments`, not `task_spec`") so the model retries with the
  correct argument split instead of silently writing an empty spec.

Prompt rule (in `system_prompt.ex :: assistant_base :: ## Attachments`):
every `📎 [newly attached]`-prefixed line in the current turn's user
message must be passed to `extract_content` as part of a fresh task
cycle (`create_task` → `extract_content` → `update_task(done)`). Do
not rely on prior-turn memory even when the path matches a file you
read before — the user re-attached it for a reason.

When a task involves a specific subset of the attachments listed on the
user message, the model passes those `📎 workspace/...` paths in the
`attachments` argument of `create_task` / `update_task`; never
hand-embeds `📎 ` lines in `task_spec`. The BE normalises the stored
spec from the validated `attachments` list.

**Follow-up discipline** — the primary path is prompt-enforced: for a
follow-up question about a previously-attached file (bare `📎 `, no
`[newly attached]` marker), the model answers conversationally from
the prior task's `task_result` and its own earlier reply — **no
`extract_content`, no `create_task`, no tool use at all**. Task wrapping
is reserved for NEW work (new tool calls). The follow-up is just chat.

**Runtime re-extract dedup** — belt-and-braces for when the model
ignores the rule. `extract_content` at execute-time:

1. Checks `ctx.fresh_attachment_paths` (the 📎 lines marked
   `[newly attached]` on the current turn). If the path is in that
   list, always runs the full pipeline — the user re-uploaded and
   wants a fresh read.
2. Otherwise, scans the session's recent done tasks (cap
   `@prior_scan_limit = 50`) for one whose `task_spec` listed the
   same path as an attachment AND has a non-empty `task_result`.
   If found, returns a payload that cites the prior task_id and
   inlines its `task_result`, with a note telling the model to use
   that instead of triggering another extraction.

Net effect: heavy extraction (LLM vision for images/video, or
pdftotext/pandoc for docs) runs at most once per session per file.
Even if the model wrongly creates a re-extract task, the dedup short-
circuits the expensive work.

**PDF extraction chain with OCR fallback** — `extract_content` handles
PDFs in this order:

1. `pdftotext -layout` → test result against `meaningful?/1` (trimmed
   length ≥ `AgentSettings.min_extracted_text_chars()`, default 50).
2. If meaningful → return. Otherwise the PDF is scanned / image-only;
   skip pandoc (doesn't help PDFs) and enter the OCR path.
3. `pdfinfo` → page count `n`. If `n > AgentSettings.ocr_page_cap()`
   (default 16), return an error telling the model to ask the user to
   split the file.
4. `pdftoppm -r 200 -png` renders all `n` pages into a temp dir.
5. Pages are chunked by `AgentSettings.ocr_pages_per_chunk()` (default
   8, aligned with the video-frame batch) and each chunk is sent as a
   single vision-LLM call (`image_describer_model`) with a transcribe-
   verbatim prompt. **Chunks run sequentially** to keep pressure off
   the cloud-account pool.
6. Chunk outputs are concatenated and truncated to `@max_doc_chars`.
7. Temp dir is cleaned in an `after` block.

Hard-coded 50 / 8 / 16 are `AgentSettings` defaults so operators can
tune them without a code change (per the no-magic-numbers rule).

**Doc / unknown paths — honest failure** — `run_pandoc`, `read_text`,
and `try_pandoc_then_read` all check `meaningful?/1` on their output.
Empty / near-empty / whitespace-only results now return `{:error, ...}`
instead of `{:ok, ""}`. Combined with the `## Attachments` prompt rule
("if extract_content returns an error, tell the user truthfully — do
NOT summarise from the filename"), this closes the hallucination
failure mode where a silent empty extraction was interpreted as
license to fabricate content from the filename.

Execution tools (unchanged from prior phases):
`web_fetch`, `web_search`, `run_script`, `extract_content`, `read_file`,
`write_file`, `calculator`, `spawn_task`, `get_date`.
(`parse_document` was retired — `extract_content` absorbed its doc
routing and added the OCR fallback for scanned PDFs.)

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

Both queue; both are processed at chain boundaries. The model sees them
as they are — the `[Active tasks]` block reflects whatever state the DB
has when context is built.

Because there is only one ongoing turn at a time per session, parallelism
within a session is nil by design. A user who wants two truly independent
threads of work creates a second chat session; each session has its own
GenServer and its own task list.

### Mid-chain user message injection

There is no Stop button and no `/agent/interrupt` endpoint. The user can
send a new message at any time, including while the assistant is
mid-chain; the message is persisted and folded into the assistant's
context as soon as possible — typically on the very next LLM roundtrip
within the current chain.

The design is **stateless DB-driven queuing**. The DB is the source of
truth; there is no in-memory mailbox tracking pending messages.

Three integration points:

1. **HTTP handler (`agent_chat.ex`).** Persists the user message to
   `session.messages` with a BE timestamp BEFORE dispatch (unchanged
   from before), then calls `dispatch_assistant`. The dispatch always
   returns 202 — busy is no longer a failure mode the FE sees. The
   message is queued the moment it hits the DB.

2. **Mid-chain splice (`session_chain_loop`).** Each turn iteration of the
   loop, BEFORE calling the LLM, queries `session.messages` for
   user-role entries whose `ts` is greater than the last user-role
   entry already present in the in-memory messages accumulator. Any
   found are appended as plain `{role: "user", content: ...}` entries;
   the next LLM call sees them in context. This splice point is safe:
   tool-call and tool-result pairs have already been appended together
   in the prior recursion, so a new user message here doesn't break
   OpenAI's tool-sequencing rules. Between the spawn of the current
   LLM request and its completion, user messages can still arrive —
   they're picked up at the START of the next iteration.
   **Contract**: every user-role entry in the working messages list
   MUST carry its source DB-row `ts`. `ContextEngine.build_current_msg`
   and `ContextEngine.to_llm_msg` both preserve it; without that,
   `max_user_ts_in_messages/1` collapses the floor to 0 and the splice
   re-appends the current user message as a duplicate — observed
   2026-04-24 as "two identical `[USER]` blocks every turn".

3. **Chain-complete hook (`handle_info({ref, _result}, …)`).** When
   the Task finishes, check `session.messages` for unanswered user
   messages (i.e. the last message in the array is role="user" with
   `ts` greater than the last role="assistant" message). If any,
   self-synthesise an `AssistantCommand` for this session and
   dispatch a fresh turn. Otherwise fall through to
   `maybe_trigger_next_due` for periodic-task chaining.

Consequences:

- **User's messages are NEVER dropped.** 409 no longer exists.
- **In-flight LLM / tool calls run to completion** — there is no
  hard-kill. The user's new message is seen on the NEXT LLM roundtrip,
  which is typically within 1–10 s. Token burn on the in-flight call
  is accepted as the cost of not having an interrupt path.
- **Safety nets for runaway behaviour** remain the same: Police's
  3-strike escalation, `max_assistant_turns_per_chain` cap. User-initiated
  hard-stop is no longer supported; if a turn is genuinely stuck,
  sending a new message ("stop what you're doing, cancel task X") is
  the escape hatch — the model sees it on the next LLM call and is
  expected to comply.
- **`session_progress` zombie cleanup is obsolete.** It only existed
  for the interrupt path; without interrupt, tools always run to
  completion and mark their own progress rows done.

### Boot scan for orphan recovery

On `UserAgent.init/1`, after the GenServer starts, it queries its
user's Assistant-mode sessions for any session whose last message is
role="user" (i.e. unanswered by the assistant). For each, it
self-dispatches an `AssistantCommand` to resume work. This guarantees
responsiveness across:

- **GenServer crash + supervisor restart** — pending mid-chain
  messages that were never processed because the old GenServer died
  are picked up by the new one.
- **Idle-timeout shutdown + lazy respawn** — next `ensure_started` on
  a user whose last message was never answered picks up the work.

The scan runs once at startup; it is NOT a poller. Subsequent
interactions rely on the chain-complete hook + mid-chain splice. The
DB-query cost is small (one indexed lookup per user's Assistant
sessions) and happens only at cold-start.

The user experience guarantee is: **after sending a message, the user
should never have to "nudge" to get a reply.** At worst, they wait a
bit longer while the system self-heals.

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
  1. Any PERIODIC task with status="ongoing" → revert to "pending".
     Periodic tasks' ongoing state is inherently tied to a running
     cycle; if the BEAM died mid-cycle, the cycle is lost and the
     task must be re-armed to fire again. One_off tasks' ongoing
     state is NOT reverted — a one_off task can legitimately stay
     `ongoing` across multiple chains (Phase 2 multi-chain: assistant
     finished a chain asking for clarification, waiting for user). If
     the chain was genuinely killed mid-work, the Phase 2 boot scan
     detects unanswered user messages and auto-dispatches a fresh
     resume chain; the task's `ongoing` status is correct for the
     continuation. See §Mid-chain user message injection.
  2. Any pending periodic task with time_to_pickup IS NOT NULL →
     schedule_pickup (re-arm the timer).
  3. Any pending periodic task with time_to_pickup <= now → poke the
     session immediately (next user interaction will handle it).
```

Disabled in `:test` env via `:dmhai, :enable_task_rehydrate, false`.

Crash survival is trivial under this model: `tasks` + `session_progress`
+ `sessions.messages` + `task_turn_archive` are the truth. The assistant
reads them on its next turn and continues. No ctx-snapshot persistence
is needed.

---

## Police

Runtime gate that runs inside `execute_tools` per individual tool call.
The gate is the enforcement mechanism for what the prompt asks of the
model — when the model forgets or cheats, Police rejects the call
before it runs and returns a tool-result the model can read + correct on.

Checks:

1. **Task discipline** — every execution-class tool call must be
   preceded in THIS chain by a `pickup_task` call. The verb-based API
   (2026-04-24) makes `pickup_task` the single signal for "I am
   actively working on a task right now" — creation alone
   (`create_task`) leaves the task at `pending`, not `ongoing`, so the
   gate can no longer be satisfied by a long-lived task left over from
   an unrelated prior user ask.
   - Gated tools: `run_script`, `web_fetch`, `web_search`,
     `extract_content`, `read_file`, `write_file`, `spawn_task`.
   - Bypass: task-management verbs themselves (`create_task`,
     `pickup_task`, `complete_task`, `pause_task`, `cancel_task`,
     `fetch_task`), credential tools (`save_credential`,
     `lookup_credential`), and read-only utilities (`datetime`,
     `calculator`).
   - Bypass: silent chains (`ctx[:silent_turn_task_id]` set) — the
     scheduler already fired for a specific task and
     `run_assistant_silent` applies `mark_ongoing` at chain start, so
     the model doesn't need to re-pickup the same task. Rule #9
     governs cross-task misuse in that context instead.
   - Rule: if `pickup_task` hasn't been called yet this chain, the call
     is rejected with a nudge teaching the full lifecycle
     (`create_task` (optional, for new objectives) → `pickup_task` →
     execution tools → `complete_task`).
   - Order-in-batch is tolerated: if the model's batch is
     `[pickup_task, run_script]`, execute_tools processes them
     sequentially and `run_script`'s check sees the `pickup_task` call
     already in the in-chain accumulator.
   - **Not user-visible**: the rejection row is written with
     `hidden = 1` (see §Hidden progress rows below) so it stays in the
     DB for audit/debug but never renders in the chat. The tool-result
     error still reaches the LLM on the next turn; that's what drives
     self-correction.

2. **Tool-name validity** — the tool_call's `function.name` must match
   a tool registered in `Dmhai.Tools.Registry`. Guards against model
   output malformation where the model emits a garbled or hallucinated
   name (we've seen devstral emit ~1000-char blobs — entire JSON
   argument payloads concatenated with its own natural-language reply —
   as the `name` field). Rejection message enumerates the valid tool
   names so the model self-corrects on the next turn. Same silent-to-
   user handling as task discipline (no progress row written).

3. **Text-turn sanity** — when the model ends a chain with a text
   response (i.e. no tool_calls), `Police.check_assistant_text/1`
   inspects that text. If the trimmed content is EXACTLY a registered
   tool name (e.g. `"complete_task"`) or has the shape `tool_name(...)`
   where `tool_name` is a registered tool, it's treated as the model
   emitting what it MEANT to be a tool_call but put in the content
   field instead — a devstral-class failure mode we've observed in
   production. Instead of persisting that text as the final assistant
   reply, the chain loop appends a corrective user-role message
   (*"Your response was '<tool_name>' which looks like a tool name
   emitted as text — tool actions must live in the `tool_calls` array,
   not message content. Retry."*) and recurses one more turn.
   Silent to the user — the broken text is never persisted; only the
   corrected response lands in `session.messages`. Conservative by
   design: it fires only on EXACT tool-name match or clear call-shape,
   never on legitimate short replies like "Done." or "Yes".

4. **Fresh-attachment read enforcement** — after a chain's final text
   turn completes, `Police.check_fresh_attachments_read/2` verifies
   that every `📎 ` path in the current chain's latest user message
   was passed to `extract_content` during this chain. If any weren't,
   the final text is rejected and a corrective nudge appended, listing
   the missed paths, so the model re-runs and actually reads them.
   Catches the compliance failure where the model acknowledges an
   attachment in prose (*"I see the PDF you attached…"*) without
   actually calling `extract_content`. Requires tracking which paths
   the model extracted in the current chain — done by scanning the
   chain's in-progress message list for `tool_call.function.name ==
   "extract_content"` entries and collecting the `path` arguments.

5. **Path safety** — `check_tool_calls/3` still validates any `path`
   argument resolves inside `session_root` via `Dmhai.Util.Path.resolve/2`.
   `run_script` still scans for `rm` / `rmdir` / `cp -r` that target paths
   outside `workspace_dir`. (Retained from pre-#101; wiring invocation is
   pending.)

6. **Duplicate-tool-call-in-chain** — `check_no_duplicate_tool_call/3`
   rejects a tool call whose `(name, significant_arg)` has already been
   invoked earlier in THIS chain. Significance key per tool:
   `create_task` → `task_title` (case-insensitive, trimmed);
   `extract_content` → `path` (case-sensitive, Linux FS);
   `web_search` → `query` (case-insensitive, trimmed). Tools outside
   that list bypass. Scans both the in-chain message accumulator (prior
   turns) AND earlier calls in the SAME batch (one LLM response with
   multiple tool_calls) — `execute_tools/3` threads a rolling pseudo-
   message list through `Enum.map_reduce/3` so a second call in the
   same batch sees the first. Cross-chain repeats are NOT flagged here —
   those are addressed by the `## Recently-extracted files` prompt
   block and the `[newly attached]` marker logic. Tagged rejection
   `{:duplicate_tool_call_in_chain, reason}` → `[[ISSUE:...]]` marker →
   `ctx.nudges` counter bump → 3-strike escalation. Catches the
   "create_task twice with same title for one follow-up question"
   misbehaviour we see on weaker models like gemini-3-flash.

7. **Consecutive-web_search** — `check_no_consecutive_web_search/3`
   rejects a `web_search` call when the IMMEDIATELY-PRIOR tool call in
   this chain was also `web_search`. Rationale: one `web_search` already
   fans out 2-3 parallel queries in the BE (see
   `Dmhai.Web.Search.generate_queries`), so back-to-back web_searches
   are wasted effort. Intra-batch AND inter-turn covered via the same
   pseudo-message threading as rule #6. Alternating patterns are
   allowed (`web_search` → `run_script` → `web_search`) — the gate only
   blocks literal consecutivity. The nudge is TEACHING: it tells the
   model the correct research loop (digest results → dig with a
   DIFFERENT tool on concrete findings → only re-search if a genuine
   gap remains). Tagged `{:consecutive_web_search, reason}` → same
   marker / counter / escalation plumbing. Catches the "slight query
   reword spam" failure mode where gemini-3-flash chains 3-4 near-
   identical web_searches that the duplicate gate (rule #6) can't
   catch because the query strings technically differ.

8. **Single periodic task per chat session** —
   `check_no_duplicate_periodic_task_in_session/3` rejects
   `create_task(task_type: "periodic", ...)` when the session already
   has an ACTIVE periodic task (any non-terminal state: `pending`,
   `ongoing`, or `paused`). Policy rationale: each periodic task fires
   on its own 30-s (or other `intvl_sec`) timer, and if a model spawns
   multiple periodics for a single user ask, silent turns compound —
   we saw 4 periodic rows spawned from one "give me a joke every 30
   sec" request with `nemotron-3-nano:30b-cloud`, producing 6+ pickups
   per 30-s window instead of 1. Unlike rule #6 (keys on `task_title`),
   this gate keys on `task_type` alone, so it catches the failure mode
   regardless of whether the duplicate titles match.

   The nudge is USER-FACING: it tells the model exactly what to say
   back to the user, naming the existing task as `(N) <title>` and
   explaining the policy ("DMH-AI only supports 1 periodic task per
   chat session"). If the user genuinely wants a different periodic
   schedule, the model must propose cancelling the existing one first
   and WAIT for confirmation — no silent replacement. If the model was
   trying to progress an existing periodic mid-`[Task due:]` pickup,
   the nudge redirects it to the verb API against the existing id
   (`pickup_task` → execution tools → `complete_task`).
   `Tasks.session_active_periodic/1` supplies the `(task_num, title,
   task_id)` tuple the nudge embeds.

### Complementary prompt guidance (periodic task pickup)

`run_assistant_silent`'s synthetic `[Task due: <id> — <title>]` message
now explicitly forbids `create_task` during a pickup and spells out the
workflow (run tools → `complete_task(task_id: <id>, task_result: ...)`
→ final text). It also tells the model its final text IS the task
output (the joke, quote, status) with no meta-prefix like "Joke
delivered:" or "Task complete" — matches the `## No bookkeeping in
user-facing text` rule from the base prompt but re-states it in the
task-pickup context where weaker models drift. A STAY IN LANE bullet
reinforces the one-task-per-silent-turn scope (no create_task, no
verb calls on other task_ids, no self-re-pickup loops) so rule #9
below is the runtime safety net, not the first line of defense.
Rule #8 is the runtime safety net for when this guidance doesn't
stick.

9. **Silent-turn scope lock** — `check_silent_turn_scope/3` reads
   `ctx[:silent_turn_task_id]` (set only by `run_assistant_silent` for
   scheduler-triggered pickups; never set for user-initiated turns).
   When present, rejects:
   * `create_task` regardless of `task_type`. A new task must come from
     a real user message, not from the scheduler happening to trigger a
     pickup.
   * `pickup_task` / `complete_task` / `pause_task` / `cancel_task`
     targeting a `task_id` that differs from the pickup's — a silent
     turn can only progress the task it was fired for. `fetch_task`
     (read-only) is always allowed.
   Allowed: execution tools (`run_script`, `web_fetch`, etc., the model's
   means of producing output), `fetch_task`, and the four scoped verbs
   when they target the pickup task_id itself (including
   `cancel_task` on the pickup task — the model legitimately may
   want to cancel the current pickup; scope gate stays out of that
   path).

   Motivating incident (2026-04-24, `ministral-3:14b-cloud`): a joke-
   task pickup fired at 21:44:29. In a single silent turn, the model
   ran `cancel_task` on the joke task, `create_task` for a new ASCII
   periodic, and then multiple verb cycles on the new task —
   effectively acting on a prior conversational-turn request that the
   user had never confirmed. Rule #9 blocks both the cancellation of
   the joke task (different task_id) and the create_task at their
   first call. Tagged rejections `{:silent_turn_create_task, reason}`
   and `{:silent_turn_other_task_verb, reason}` feed the existing
   `[[ISSUE:...]]` / `ctx.nudges` / 3-strike escalation plumbing.

**Prompt-level counterpart to #7**: the Assistant prompt's new
`## Tool selection` section teaches the model WHICH tool matches WHICH
question shape up-front — "if the user names a service with an HTTP
API or CLI you can invoke (Ollama, GitHub, systemd, a local daemon),
the answer is at the endpoint — use `run_script`, not `web_search`."
Rule #7 is the runtime safety net for when that guidance doesn't stick.

Removed:
- Signal protocol rules (`step_signal` batching, `task_signal` ordering,
  terminal-tool exclusivity) — protocol is gone, rules along with it.

### Hidden progress rows

`session_progress` has a `hidden INTEGER DEFAULT 0` column. Rows written
with `hidden = 1` stay in the DB for audit / debugging (you can still
see them via direct SQL or an admin tool) but are filtered out of the
FE-facing reader `SessionProgress.fetch_for_session/2` — so the user's
chat timeline never surfaces them. `SessionProgress.append/4` exposes
the `:hidden` option (default `false`). Current uses:

- **Police rejections**: the "you must call pickup_task first" row is
  hidden. The model still gets the error in its tool-result and
  self-corrects; the user sees only the corrected retry, not the
  blocked attempt.
- **`complete_task` calls**: the final-cleanup progress row is hidden.
  The assistant's actual final message IS the completion event from
  the user's perspective; a trailing "CompleteTask(…)" row before the
  answer is noise. The other verbs (`pickup_task`, `pause_task`,
  `cancel_task`) stay visible — those are meaningful state changes
  the user benefits from seeing in the chat timeline.

The mechanism is generic: any future "internal plumbing that shouldn't
clutter the chat" can pass `hidden: true` at append time.

---

## Rate limiting (`Dmhai.Plugs.RateLimit`)

Hammer-backed sliding window, one bucket per (key, tier). The key is
**the authenticated user** whenever the request carries a valid bearer
token; otherwise it falls back to **the client IP** (real IP from
`X-Forwarded-For` when present, else `conn.remote_ip`). Running
in the plug chain BEFORE the route dispatcher, so it guards every
path — but it does a cheap bearer-token → `users.id` lookup inline
whenever `Authorization` is present so the bucket scopes properly.

### Why per-user, not per-IP

The original design was per-IP. That breaks for our target deployment
(SME, up to ~50 users sharing an office NAT gateway → **single public
IP**). Under per-IP keying, 50 legitimate users polling the chat API
at 2 req/s collide in the same bucket and hit the general-tier cap in
under a second — the 429 error users saw in chat was this exact race
against the post-polling refactor.

Per-user keying isolates each user's bucket regardless of NAT. The
pre-auth fallback (IP-keyed) retains flood protection for the login
endpoint, where no user_id is available yet.

### Tiers and caps (per-minute, per key)

| Tier | Cap | Key | Paths |
|------|-----|-----|-------|
| `:auth` | 8 | **IP** (pre-auth) | `/auth/*` — login flood protection |
| `:upload` | 30 | user | `/assets`, `/describe-video`, `/describe-image` |
| `:poll` | 200 | user | `/sessions/:id/poll`, `/sessions/:id/tasks`, `/sessions/:id/progress` |
| `:general` | 120 | user | everything else |

**Sizing the `:poll` tier**: the FE's active-turn cadence is 500 ms on
`/poll` = 120 req/min. Idle cadence is 5 s = 12 req/min. Add task-list
sidebar polling at ~3 s while tasks are active = 20 req/min. Sum:
~140 req/min nominal. Cap at 200 leaves headroom for two tabs viewing
the same session, brief double-polling during session switch, and
transient bursts while scrolling history.

### Aggregate load — 50-user SME scenario

Per user, at steady state, active session polling: 2 req/s to `/poll`.
All 50 users active simultaneously:

- `/poll` requests: 50 × 2 = **100 req/s** aggregate = 6 000 req/min
- Each `/poll` = one SELECT on `sessions` + one on `session_progress`
  + one on `tasks` via `fetch_next_due/1`. All three indexed. SQLite
  comfortably serves hundreds of such queries per second on local
  disk; Bandit has no measurable overhead at this scale.
- No bucket collides: each user sits in their own `"user:<id>:poll"`
  bucket with 200 req/min capacity, so none of the 50 is ever
  false-throttled.

### Known tradeoffs

- **No horizontal scaling yet**. Hammer's default backend is an in-
  memory ETS table, single-node. If / when we split the BE across
  multiple nodes, Hammer needs the distributed-ETS or Redis backend.
  Small-SME deployments run one node, so this is acceptable for now.
- **Token-to-user lookup on every request**. The plug does an
  `auth_tokens` JOIN per request for authed paths. That's one indexed
  SELECT on a small table — measured < 1 ms. If it becomes a
  bottleneck (10 000+ req/s range) we'd cache token → user_id in an
  ETS with short TTL, same pattern as existing rate-limit buckets.
- **IP fallback for anonymous paths can still be NAT-collided**. A
  brute-force login attack from 50 different machines on the same
  office NAT looks like one IP. `/auth` tier's 8 req/min cap is
  already narrow enough that this doesn't meaningfully change the
  threat model — an attacker behind NAT still can't out-slow-scan a
  human typing a password.
- **Sudden cadence bursts during reconnects**. When a user's tab
  wakes from sleep or switches sessions rapidly, the FE may briefly
  fire several polls concurrently. The 200-cap has enough slack to
  absorb this, but if we ever see false-throttles here the right fix
  is on the FE (`AbortController` the previous polling loop before
  starting a new one).

### Future todos

- **Move off polling to a persistent channel (SSE / WebSocket)** when
  the user base exceeds the low-hundreds mark. Polling at 500 ms is
  fine for 50-user SME deployments but scales at O(users) per second
  indefinitely; a single long-lived SSE per user is O(1). This is a
  larger architectural decision — see §Polling-based delivery for the
  tradeoffs we weighed; revisit when we hit the scale that forces it.
- **Operator-facing tier overrides** in `AgentSettings`. Today the
  tier caps are module constants. If a specific deployment needs
  higher throughput (e.g. power users doing heavy scripting), a
  config row lets the admin tune without a code push.
- **Distributed Hammer backend** once we move to multi-node. The
  migration is backend-swap only — key format and tier scaffolding
  stay the same.
- **Per-tier telemetry**: log how often each tier's cap is actually
  hit, per user, so we can tune the caps from data rather than
  guesses. Hammer already exposes a count; we just don't surface it.

---

## Outbound HTTP for LLM calls

Outbound HTTP from the app goes through one shared Finch pool
(`Dmhai.Finch`, size 10, `conn_max_idle_time: 30_000`). Most callers
(SearXNG, Jina reader, Telegram, `/assets` proxy) benefit from
connection reuse — same hosts, steady traffic, no observed issues.

**LLM calls specifically opt OUT of connection reuse AND response
compression.** Both `do_call_request/5` and `do_stream_request/6` in
`lib/dmhai/agent/llm.ex`:

- Add a `Connection: close` header on every outbound request so Finch
  terminates the TCP/TLS session after the response (no pool reuse).
- Pass `compressed: false` to `Req.post` so the client does NOT send
  `Accept-Encoding: gzip`. Ollama Cloud's edge otherwise returns a
  gzipped response for longer generations; the client-side streaming
  gzip decoder stalled on the final-text response pattern (observed
  multiple times — short tool-call responses fit in one packet and
  decoded cleanly; multi-packet text responses stalled mid-decode for
  minutes). curl works fine because it doesn't send Accept-Encoding
  by default; the server returns plain text and nothing to decode.
- Bound `receive_timeout` at 120 s as a floor so any future unknown
  stall fails out rather than blocks forever.

### Why

Observed in production (see `[LLM:finch] host=ollama.com` telemetry
in system.log): Ollama Cloud's edge silently detaches backend state
between two successive requests on the same keepalive socket. The
second request sends its bytes, the server never emits a response,
no FIN / RST / TLS alert is observed on the client socket, and Finch
blocks forever in `recv` (previously with
`receive_timeout: :infinity` — a 6-plus-minute mystery hang that
eventually cleared when some unrelated timeout elsewhere broke the
socket). The failure mode is specific to reused connections: first
requests on a freshly-connected socket always succeeded, only
subsequent reuses were at risk.

### Tradeoffs

- **Cost**: one fresh TLS handshake per LLM call (~50–200 ms). For
  requests whose server-side work takes multiple seconds, that's a
  few-percent overhead — invisible in practice.
- **Gain**: eliminates an entire class of silent multi-minute hang
  whose only visible symptom was the user's chat window sitting on
  a spinner with nothing happening in any log.

### Belt-and-suspenders

`receive_timeout: 120_000` (2 min) caps any individual LLM HTTP call
— if something else ever silently hangs at the network level, we
error out rather than blocking forever.

**Transport-error classification.** `Req.TransportError` /
`Mint.TransportError` / any error with `reason` in `[:timeout,
:closed, :econnrefused, :econnreset, :nxdomain]` is mapped to
`{:error, :server_error}` inside `do_call_request/5` and
`do_stream_request/6`. This routes the failure into the existing
`do_cloud_call/6` / `do_cloud_stream/7` retry loop — 3 attempts on
the same account with 2 s delay, then rotation to the next account.
Without this, a raw `%Req.TransportError{reason: :timeout}` would
propagate up to the session loop and be persisted verbatim as the
user-facing assistant message (`"LLM error: %Req.TransportError{…}"`).

### Other outbound HTTP is unaffected

SearXNG / Jina / Telegram / proxy paths still use pooled Finch
connections with their existing receive_timeout values. They don't
exhibit the same failure pattern because they don't talk to Ollama
Cloud's edge. When adding a new outbound caller, use pooled Finch by
default; only opt-out with `Connection: close` if you observe
zombie-connection hangs against that specific host.

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
  `read_file`, `extract_content`, `datetime`) return raw
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
| Assistant (session loop) | `gpt-oss:120b-cloud` |
| Context Compactor | `gemini-3-flash-preview:cloud` |
| Progress Summariser (on-demand) | `gemini-3-flash-preview:cloud` |
| Web Search Detector | `ministral-3:14b-cloud` |
| Image Describer | `gemini-3-flash-preview:cloud` |
| Video Describer | `gemini-3-flash-preview:cloud` |
| Profile Extractor | `gemini-3-flash-preview:cloud` |

### Other Settings (admin-configurable)

| Key | Default | Purpose |
|-----|---------|---------|
| `maxAssistantTurnsPerChain` | 50 | Per-chain cap on the number of turns (LLM roundtrips); abort chain if exceeded |
| `maxToolResultChars` | 8000 | Truncation threshold for tool results fed back into context |
| `spawnTaskTimeoutSecs` | 30 | Bash command timeout inside spawn_task |
| `masterCompactTurnThreshold` | 50 | Session compaction trigger by message count |
| `masterCompactFraction` | 0.45 | Session compaction char-budget fraction |
| `estimatedContextTokens` | 64_000 | Usable context-window size driving the char-budget trigger |
| `toolResultRetentionTurns` | 5 | Number of recent turns whose tool_call/tool_result messages stay in context |
| `toolResultRetentionBytes` | 120_000 | Byte ceiling for retained tool messages (oldest-first eviction on overflow) |
| `taskArchiveRowCap` | 60 | Per-task archive sliding-window row cap (~30 user+assistant pairs). Oldest dropped on append. |
| `taskArchiveByteCap` | 120_000 | Per-task archive byte budget summed over `content`. Oldest dropped until under cap. |
| `rateLimitThrottleSecs` | 60 | Default throttle for an LLM account that hit 429 with no `Retry-After`. Was 3600 s before — caused burst stress-tests to lock the whole account pool for an hour. |
| `quotaExhaustedThrottleHours` | 168 | Throttle for an LLM account that reports weekly quota exhausted (Ollama cloud's weekly reset). |
| `llmNumPredictAssistant` | 16_384 | Output-token ceiling (`num_predict`) on assistant-mode `LLM.stream` calls. A cap, not a reservation — unused headroom has no cost. Prevents the truncation loop observed 2026-04-24 (15-line bash scripts cut mid-string → `syntax error` → model retries same malformed call). |
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
  task_id TEXT PK     ← cryptic; BE-internal FK for session_progress,
                         task_turn_archive, tool_history. Never user/
                         model-facing (see §Task lifecycle §Identity).
  task_num INT        ← per-session monotonic integer (1, 2, 3, …); the
                         ONLY identifier the model/user/UI sees ("(N)").
  user_id / session_id
  task_type TEXT       ← 'one_off' | 'periodic'
  intvl_sec INT       ← 0 for one_off
  task_title TEXT      ← short label shown in the task-list block + FE sidebar
  task_spec TEXT       ← description; verbatim user message (with 📎-prefixed
                         attachment paths appended, if any).
  task_status TEXT     ← 'pending' | 'ongoing' | 'paused' | 'done' | 'cancelled'
  back_to_when_done_task_num INT ← nullable back-reference. Set at pickup_task
                                    time when another task was anchor; read at
                                    complete/cancel/pause time to restore that
                                    prior anchor. See §Active-task anchor.
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
                         tool call returns — including on tool error to
                         keep the FE's upsert-by-id dedup working; pre-
                         Phase-2 `delete` path retired)
  label TEXT          ← truncated to 4k chars; the FE-renderable activity line
  ts INTEGER

task_turn_archive       ← per-task raw message archive (Phase 3, planned).
                          Hooked into ContextEngine.compact! and
                          ToolHistory eviction. Preserves verbatim
                          turns for tasks that span many chains, so
                          fetch_task(task_num) can replay decisions
                          exactly even after master session summaries
                          compact the session.messages view.
                          See §Task state continuity across chains.
  id INTEGER PK AUTOINCREMENT
  task_id TEXT        ← FK to tasks.task_id (NOT task_num — this table
                         outlives per-session number allocation and uses
                         the stable cryptic id)
  session_id TEXT     ← for operator queries / cross-session joins
  original_ts INT    ← the message's own ts when originally written
  role TEXT           ← 'user' | 'assistant' | 'tool'
  content TEXT        ← NULL allowed (tool_calls-only assistant msgs)
  tool_calls TEXT     ← JSON; present on role='assistant' w/ tool_calls
  tool_call_id TEXT   ← present on role='tool'
  archived_at INT    ← unix ms; when compaction wrote this row
  INDEX (task_id, original_ts)

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
