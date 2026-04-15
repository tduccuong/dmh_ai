# DMH-AI Architecture

## Overview

DMH-AI is a self-hosted AI assistant application. Users interact with it through a browser-based chat interface. The system routes each conversation through one of two distinct pipelines — **Confidant** (synchronous, conversational) or **Assistant** (async, agentic) — selected per session.

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

Docker Compose mounts `/data` as a named volume (`dmh-ai-data`), so the database and user-uploaded assets survive container restarts.

---

## Frontend Architecture

The SPA is plain JavaScript — no framework, no bundler.

```
index.html
 ├── core.js          — i18n (en/vi/de/es/fr), apiFetch, syslog
 ├── constants.js     — client-side-only constants (image sizing, timeouts)
 ├── api.js           — SessionStore, ImageDescriptionStore, VideoDescriptionStore
 ├── profile.js       — Settings, UserProfile, UserFactTracker
 ├── ui.js            — Modal, Lightbox, SettingsModal helpers
 ├── manager-app.js   — session list sidebar, mode switching, session CRUD
 ├── manager-chat.js  — renderChat(), renderSessions(), streaming placeholder
 ├── manager-search.js— sendMessage() — streaming, thinking block, scroll
 └── main.js          — app bootstrap, event wiring, notification polling
```

### Session Modes

Each session has a `mode` stored in the DB (`confidant` | `assistant`). The sidebar filters sessions by the currently selected mode. Switching mode changes the sidebar view and the pipeline used for new messages.

```
Topbar
┌─────────────────────────────────────┐
│  [Confidant ▼]   [New Chat]  [⚙]   │
└─────────────────────────────────────┘
         │
         ▼
Sidebar (filtered by mode)
┌──────────────────────┐
│ ● Session A  [🗑]    │  ← active (highlighted)
│   Session B  [🗑]    │
│   Session C  [🗑]    │
└──────────────────────┘
```

### Streaming Response Rendering

```
sendMessage()
    │
    ├─ renderChat()          — shows user msg, clears input
    ├─ Build streaming DOM   — assistantDiv + bodyDiv (minHeight trick)
    ├─ Scroll user msg to top
    ├─ await SessionStore.updateSession()   — persist before sending
    │
    └─ POST /agent/chat  (NDJSON stream)
           │
           ├── {status: "..."}      → status bar update
           ├── {message:{thinking}} → think block (collapsible <details>)
           ├── {message:{content}}  → answer content (renderWithMath)
           └── {done: true}         → onComplete() → renderChat()

Think Block lifecycle:
  streaming thinking  →  open <details>, live-update (last line buffered)
  first content chunk →  auto-collapse, apply full digestThinking(final=true)
  onComplete()        →  renderChat() rebuilds from stored msg.thinking
```

### Notification Polling (Assistant mode)

The frontend polls for worker completion notices:

```
setInterval(
  GET /notifications?since=<last_ts>
    → [{id, session_id, summary, created_at}, ...]
    → show toast / update session in sidebar
  interval: configurable in user settings
)
```

---

## Backend Architecture

### Process Tree

```
Application
 ├── Repo                        (SQLite via Ecto + Exqlite)
 ├── Dmhai.Agent.Registry        (Registry for UserAgent lookups)
 ├── Dmhai.Agent.Supervisor      (DynamicSupervisor for UserAgents)
 ├── Dmhai.Agent.TaskSupervisor  (Task.Supervisor — inline tasks)
 ├── Dmhai.Agent.WorkerSupervisor(Task.Supervisor — detached workers)
 └── Bandit (HTTP server, :8080 / :8443)
      └── Dmhai.Router (Plug.Router)
```

### Request Lifecycle

```
HTTP request
    │
    ├─ BlockScanners plug    — drop known scanner user-agents
    ├─ SecurityHeaders plug  — CSP, HSTS, etc.
    ├─ Plug.Static           — serve /app/static
    ├─ RateLimit plug        — per-IP rate limiting
    │
    └─ Router (match + dispatch)
           │
           ├─ Public routes  — /auth/login, /api/* (Ollama proxy), /search
           └─ Auth routes    ── AuthPlug.get_auth_user(conn)
                                    │ token cookie → users table
                                    ▼
                               Handler function
```

### Agent Subsystem

One `UserAgent` GenServer per authenticated user, started lazily and idle-timed-out after 30 minutes.

```
UserAgent (GenServer, per user)
  state:
    current_task: nil | {ref, reply_pid}   ← one inline task at a time
    workers:      %{worker_id => worker}   ← many concurrent workers
    platform_state: %{telegram: ...}

  worker entry:
    ref, pid, session_id, description, started_at
    progress: ["tool_name: result_preview", ...]   ← live step log
```

### Worker Monitoring

Workers report progress back to their parent UserAgent after each tool execution. The UserAgent stores each step in the worker's `progress` list, which is injected into the Master Agent's context so it can answer status queries without interrupting the worker.

```
Worker Task
   │
   ├─ LLM.call() → tool_calls
   │
   ├─ execute tool
   │      │
   │      └─ send {:worker_progress, worker_id, "tool: result_preview"} → UserAgent
   │              └─ UserAgent.handle_info → append to worker.progress
   │
   └─ loop

On crash (abnormal :DOWN):
   UserAgent finds crashed worker → MasterBuffer.append(crash notice)
   → next Master LLM call sees the failure
```

---

## Confidant Pipeline (synchronous)

Used for conversational chat. The entire pipeline runs in a single inline Task, and the HTTP connection stays open streaming tokens to the browser.

```
Browser                  Backend inline Task
   │                            │
   │  POST /agent/chat          │
   ├──────────────────────────► │
   │                            │
   │                     ┌──────▼────────────────────────────────┐
   │                     │  1. WebSearch.detect_category()       │
   │                     │     (fast LLM call — yes/no + topic)  │
   │                     │                                       │
   │                     │  2. [if search needed]                │
   │  ◄── status: "🔍"   │     build_queries()                   │
   │  ◄── status: "📄"   │     search_and_fetch() → pages        │
   │                     │     build_web_context()               │
   │                     │       → synthesize if > 45k chars     │
   │                     │                                       │
   │                     │  3. ContextEngine.build_messages()    │
   │                     │     [system] + [summary prefix]       │
   │                     │     + [history] + [snippets]          │
   │                     │     + [web_context] + [current msg]   │
   │                     │                                       │
   │  ◄── thinking tok.  │  4. LLM.stream() → Ollama /api/chat  │
   │  ◄── content tok.   │     streams {:thinking} / {:chunk}   │
   │  ◄── {done}         │                                       │
   │                     │  5. append_session_message() → DB     │
   │                     │  6. background: maybe_compact()       │
   │                     │  7. background: ProfileExtractor      │
   │                     └───────────────────────────────────────┘
```

---

## Assistant Pipeline (asynchronous)

Used for agentic, multi-step tasks. The Master Agent can delegate to a Worker, closing the HTTP connection early. The Worker runs independently and notifies the user when done.

```
Browser              Master (inline Task)           Worker (detached Task)
   │                        │                               │
   │  POST /agent/chat      │                               │
   ├───────────────────────►│                               │
   │                        │                               │
   │                 ┌──────▼──────────────────────┐       │
   │                 │ 1. MasterBuffer.fetch()      │       │
   │                 │    mark_consumed()           │       │
   │                 │                             │       │
   │                 │ 2. ContextEngine.build()     │       │
   │                 │    + buffer_context          │       │
   │                 │    + active worker list      │       │
   │                 │                             │       │
   │                 │ 3. LLM.stream(tools:         │       │
   │                 │     [handoff_to_worker,      │       │
   │                 │      cancel_worker])         │       │
   │                 └──────┬──────────────────────┘       │
   │                        │                               │
   │         ┌──────────────┴──────────────┐               │
   │         │ text response               │ tool_call      │
   │         ▼                             ▼                │
   │  ◄── stream + done         ack to browser             │
   │                            ◄── {chunk: ack}            │
   │                            ◄── {done}                  │
   │                            HTTP conn closes             │
   │                                        │               │
   │                                        └──────────────►│
   │                                                        │
   │                                          Worker.run()  │
   │                                           loop (≤10x): │
   │                                           LLM.call()   │
   │                                           → tool_calls │
   │                                           → execute    │
   │                                           → append msg │
   │                                           → loop       │
   │                                          final text    │
   │                                           ▼            │
   │                                     MasterBuffer       │
   │                                     .append()         │
   │                                           │            │
   │                                     trigger_master_    │
   │                                     from_buffer()      │
   │                                           │            │
   │                                     Master LLM.call()  │
   │                                     (non-streaming)    │
   │                                           │            │
   │                                     append to DB       │
   │                                     MsgGateway.notify()│
   │                                                        │
   │  GET /notifications?since=...                          │
   │◄──────────────────────────────────────────────────────-│
   │  [{summary, session_id}]                               │
   │  show toast / render new message                       │
```

### Worker Tool Set

The Worker Agent has access to these tools (registered in `Tools.Registry`):

| Tool | Description |
|------|-------------|
| `web_search` | Query SearXNG for search results |
| `web_fetch` | Fetch and extract text from a URL |
| `read_file` | Read a file from the data directory |
| `write_file` | Write a file to the data directory |
| `list_dir` | List directory contents |
| `bash` | Execute a shell command |
| `calculator` | Evaluate a math expression |
| `datetime` | Get current date/time |

### Periodic Jobs (no Cronjob needed)

Workers can implement scheduled / repeating work natively using `bash` with `sleep` or by looping inside a tool sequence. Because a Worker is a long-lived Elixir Task with no wall-clock timeout, it can simply `Process.sleep/1` between iterations. No separate cron mechanism is required — the Worker itself is the cron.

---

## Context Engine

Builds the message list for every LLM call. Handles compaction (summarisation) automatically when conversation history grows large.

```
build_messages(session_data, opts)
    │
    ├── system prompt
    │     (persona + user profile + image/video descriptions)
    │
    ├── [summary prefix]   ← if history was compacted
    │     user:  "Summary of conversation so far: ..."
    │     asst:  "Understood, I have full context."
    │
    ├── recent history     (messages after compaction cutoff)
    │     role: user/assistant, content only (thinking stripped)
    │
    ├── [relevant snippets] ← top-4 keyword-matched old messages
    │     (from compacted history, re-injected when relevant)
    │
    ├── [buffer context]   ← Assistant only: worker results
    │     user:  "[Worker agent updates] ..."
    │     asst:  "I've reviewed the worker updates..."
    │
    └── current user message
          + images + files + web_context (merged in)

Compaction triggers when:
  - recent turn count > 90, OR
  - recent chars > 45% of ~32k char budget

Compaction: LLM summarises old messages → stored in sessions.context
            old messages become "dead" — only used for snippet retrieval
```

---

## Media Pipeline

Images and video are pre-processed client-side before being sent to the server.

```
Client side:
  Photo attach  → resize to max 1568px (vision budget)
                → generate 100px thumbnail (for display)
                → upload to /assets (original stored)
                → POST /describe-image (background)
                     → LLM describes image → image_descriptions table

  Video attach  → GET /video-frame-count  (BE decides frame count)
                     base: 8 (cloud) / 16 (local)
                     multiplier: admin setting (low/medium/high)
                → extract N evenly-spaced JPEG frames (canvas API)
                → upload full video to /assets (background)
                → POST /describe-video  (background)
                     → LLM describes video → video_descriptions table

Server side (LLM call):
  if description exists → pass [] images, inject description in system prompt
  if no description yet → pass raw images/frames directly
```

---

## User Profile & Personalisation

After every assistant response, a background task extracts personal facts from the conversation and merges them into the user's profile.

```
ProfileExtractor.extract_and_merge(user_text, assistant_text, user_id)
    │
    ├── LLM prompt → extracts two sections:
    │     [FACTS]      — explicit self-descriptions ("I am...", "I work at...")
    │     [CANDIDATES] — topics the user shows curiosity about
    │
    ├── FACTS → merge into users.profile (bullet list, dedup by key)
    │            condense if > 50 facts (LLM compression)
    │
    └── CANDIDATES → Auth.track_facts_for_user()
                       Jaccard-normalize against known topics
                       increment user_fact_counts table
                       promote to users.interests if count ≥ threshold
```

The profile text is injected into the system prompt on every LLM call, giving the model persistent memory of who the user is.

---

## Database Schema

```
sessions
  id TEXT PK          ← timestamp-based (Date.now().toString())
  name TEXT
  model TEXT          ← legacy (models now from admin settings)
  messages TEXT       ← JSON array of {role, content, thinking?, ts, images?, ...}
  context TEXT        ← JSON {summary, summaryUpToIndex}  (compaction state)
  mode TEXT           ← 'confidant' | 'assistant'
  created_at INTEGER
  updated_at INTEGER

users
  id TEXT PK
  email TEXT UNIQUE
  name TEXT
  password_hash TEXT
  role TEXT           ← 'user' | 'admin'
  profile TEXT        ← accumulated personal facts (bullet list)
  created_at INTEGER

auth_tokens
  token TEXT PK
  user_id TEXT
  created_at INTEGER

master_buffer
  id INTEGER PK AUTOINCREMENT
  session_id TEXT
  user_id TEXT
  content TEXT        ← full worker result (injected into next Master call)
  summary TEXT        ← short one-liner (shown as notification)
  consumed INTEGER    ← 0 = pending, 1 = already injected into Master
  created_at INTEGER

image_descriptions   → (session_id, file_id, name, description)
video_descriptions   → (session_id, file_id, name, description)
user_fact_counts     → (user_id, topic, count)
settings             → (key, value)  ← admin settings KV store
blocked_domains      → (domain, reason, timeout_count, blocked_until)
```

---

## LLM Routing

All LLM calls go through `Dmhai.Agent.LLM`. The model string encodes the provider:

```
"ollama::mistral:latest"          → local Ollama (:11434)
"ollama::cloud::gemini-3-flash:cloud"  → Ollama cloud proxy (authenticated)
"openai::gpt-4o"                  → OpenAI API
"anthropic::claude-3-5-sonnet"    → Anthropic API
```

Cloud API keys are managed in admin settings (key pool per provider). The LLM module picks a key from the pool on each call.

### Model Assignments (admin-configurable)

| Role | Default |
|------|---------|
| Confidant Master | admin setting |
| Assistant Master | admin setting |
| Worker Agent | `glm-5:cloud` |
| Web Search Detector | `ministral-3:14b-cloud` |
| Image Describer | `gemini-3-flash-preview:cloud` |
| Video Describer | `gemini-3-flash-preview:cloud` |
| Profile Extractor | admin setting |
| Session Namer | `gemini-3-flash-preview:cloud` |
| Context Compactor | `gemini-3-flash-preview:cloud` |

---

## Security

```
Request path:
  BlockScanners   → drop /etc/passwd, /.env, /wp-admin, etc.
  SecurityHeaders → CSP, X-Frame-Options, HSTS, referrer-policy
  RateLimit       → per-IP sliding window (configurable)
  AuthPlug        → cookie token → users table lookup
                    all /agent, /sessions, /assets routes require auth

Auth:
  POST /auth/login   → bcrypt verify → set httpOnly cookie (auth_token)
  POST /auth/logout  → delete token from DB
  GET  /auth/me      → return current user (used for session restore)

Admin:
  role='admin' required for: GET/PUT /admin/settings,
                              GET /admin/user-profiles,
                              POST /users (create user)
```

---

## Deployment

```
docker-compose up
    │
    ├── dmh-ai container
    │     FROM elixir:1.18-alpine
    │     mix release → /app
    │     Bandit → :8080 (HTTP) / :8443 (HTTPS, TLS)
    │     self-signed cert generated at first boot
    │
    └── searxng container
          SearXNG search engine
          port 8080 (internal, not exposed)
          used by web search pipeline
```

User data lives in `/data` (Docker named volume):
- `/data/db/chat.db` — SQLite database
- `/data/user_assets/<email>/<session_id>/` — uploaded files
- `/data/system_logs/system.log` — web search trace log
