# Data flows

Two pipelines, branched at the HTTP handler entry and never re-merged.

## Confidant flow

A single streaming LLM call answers each user message. No tasks, no
tool calls, no chain.

```
POST /agent/chat   (mode=confidant)
    │
    ├── handle_confidant_chat
    │     parse body → %ConfidantCommand{content, images, files, has_video, ...}
    │
    └── UserAgent.run_confidant
          │
          ├── [pre-step, parallel via Task.async]
          │     web_task   — search-planner LLM → SearXNG → page fetches
          │     memo_task  — embed query → vector ANN over kb_vec_memo
          │     wait with Task.await(_, confidant_pre_step_timeout_ms)
          │
          ├── media resolution
          │     load image / video descriptions from DB
          │     describe inline if any are missing
          │
          ├── ContextEngine.build_confidant_messages
          │     (see context_management.md — system prompt + history +
          │      compaction prefix + relevant snippets + current input
          │      with optional web/memo context block)
          │
          └── LLM.stream(confidantModel, messages)
                ↓ tokens streamed into sessions.stream_buffer
                ↓ FE polling renders progressive text
                final text appended to session.messages on completion
```

`%ConfidantCommand` carries inline `images[]` for direct vision
answering — Confidant is the only path that passes images straight to
the LLM without an `extract_content` tool call.

## Assistant flow

Each user message (or scheduler-triggered `{:task_due}`) starts a
**chain** of LLM turns. The same model sees the conversation, the
current task list, and the new input, and decides per turn whether
to call tools or emit user-facing text.

```
incoming:
  {:dispatch_assistant, %AssistantCommand{...}}        ← user message
  {:task_due, task_id}                                 ← scheduler poke
  {:auto_resume_assistant, session_id}                 ← chain-complete hook

  ▼
UserAgent.run_assistant
  │
  ├── ContextEngine.build_assistant_messages
  │     (see context_management.md)
  │
  └── session_chain_loop(messages, model, ctx, turn=0):
        │  ┌─ at top of each turn: splice mid-chain user msgs ──┐
        │  └────────────────────────────────────────────────────┘
        │
        LLM.stream(assistantModel, messages, collector, tools, ...)
          ┌─ {:tool_calls, calls} ─┐
          │   Police gate each call
          │   execute → append tool result → recurse turn+1
          └─ {:text, text} ─┘
               final text already streamed into stream_buffer;
               persist as assistant message → CHAIN DONE
```

Cap: `maxAssistantTurnsPerChain` (default 50). Hit → abort with a
"let's continue next time" reply.

### Task verbs

Lifecycle is verb-driven — the runtime owns the state machine.

| Verb            | Effect                                                         |
|-----------------|----------------------------------------------------------------|
| `create_task`   | Insert row (status=`ongoing`) AND make it the current anchor.  |
| `pickup_task`   | Resume an existing task → `ongoing`. Idempotent. Permissive.   |
| `complete_task` | one_off → `done`. periodic → auto-reschedule.                  |
| `pause_task`    | Flip `ongoing`/`pending` → `paused`.                           |
| `cancel_task`   | Flip non-terminal → `cancelled`.                               |
| `fetch_task`    | Read-only stitched view (metadata + archive + live + tools).   |

After every chain end, `Tasks.fetch_next_due/1` looks for a pending
periodic whose pickup time has passed — if found, the agent
self-sends `{:task_due, task_id}` and starts a silent turn. The
chain terminates when the queue is empty or all pending pickups are
in the future.

### Mid-chain user message injection

Users can send a new message while the assistant is mid-chain. The
design is stateless DB-driven queuing — the DB is the source of
truth, no in-memory mailbox tracks pending messages.

Three integration points:

1. **HTTP handler** persists the user message with a BE timestamp
   BEFORE dispatch. Dispatch always returns 202 — busy is not a
   failure mode.
2. **Mid-chain splice** — `session_chain_loop` queries
   `session.messages` at the top of every turn for user-role entries
   newer than the last one already in its in-memory accumulator.
   Found ones are appended; the next LLM call sees them.
3. **Chain-complete hook** — when the inline Task finishes, if any
   user message was persisted after the chain's watermark,
   self-dispatch a fresh `AssistantCommand`.

Consequence: user messages are NEVER dropped. In-flight LLM / tool
calls run to completion; the new message is folded in on the NEXT
LLM roundtrip (typically 1-10 s).

### Cancellation

Two distinct paths:

**Per-task Stop** (sidebar button on `ongoing` tasks):
`POST /tasks/:id/cancel` → `Tasks.mark_cancelled/2` → row flips. The
chain isn't signalled directly — `session_chain_loop` re-reads the
anchor task's status at the top of every turn, sees `cancelled`,
clears `stream_buffer`, writes a `chain_aborted` `session_progress`
row, and exits. DB row is the truth-source; chain loop is the only
authority on "what turn is next".

**Chat-level Stop** (interrupts the in-flight inline turn):
`POST /sessions/:id/stop` → `cancel_current_turn` brutal-kills the
inline Task (`Process.exit(:kill)`), clears `stream_buffer` /
`thinking_buffer` / `ChainInFlight`, writes a `chain_aborted` row,
clears `current_task`. Idempotent — a second cancel returns
`:no_active_turn`.

Crashes (uncaught exception, OOM, pre-step timeout) follow the same
cleanup via the `:DOWN` handler, with a different label
(`"Internal error — please try again."`). No auto-resume on crash —
the cause is typically deterministic and a tight re-dispatch would
loop.

### Delivery: stream_buffer + session_progress

Both modes feed the same FE plumbing:

- Each LLM-stream collector writes accumulated tokens to
  `sessions.stream_buffer` (throttled at 250 ms). FE polling renders
  them progressively.
- Tool calls, thinking tokens, and chain-end signals land as rows in
  `session_progress`. FE polls deltas by `prog_since=<id>` and
  upserts by id (done-flips overwrite the prior pending row).
- When the final text turn completes, the accumulated text is
  persisted as a real `role: "assistant"` entry in `session.messages`
  and `stream_buffer` is cleared.
- `ChainInFlight` (ETS) is set on chain entry and cleared on every
  exit path (natural completion, cancel, crash) so `/poll` returns
  `chain_in_flight` correctly through tool-call gaps.

### Long-running tools

`run_script` may run for seconds, minutes, or hours. The runtime
spawns it under `nohup` inside the sandbox, tracks the PID in
`RunningTools` (ETS), and polls for completion every
`tool_run_poll_interval_ms`. The model's contract is unchanged —
`{:ok, output}` on exit, `{:error, ...}` on non-zero / kill /
timeout. The model isn't taught about backgrounding; the runtime
enforces it transparently.

### Boot scan (orphan recovery)

On `UserAgent.init/1`, the GenServer queries its user's Assistant
sessions for any whose last message is `role="user"` (i.e.
unanswered) and self-dispatches an `AssistantCommand` to resume.
Covers GenServer crash + supervisor restart, and idle-timeout
shutdown + lazy respawn. Not a poller — runs once at start.

### Periodic + long-running coordination

When a periodic task fires while a long-running one_off is `ongoing`,
the periodic runs as a silent turn with the anchor flipped to it. The
one_off stays `ongoing` (no implicit pause). When the periodic
chain ends, the next chain's context build re-resolves the anchor —
typically returning to the long-running task on the next user
interaction.

The scheduler also skips a periodic firing if any other periodic in
the same session is already `ongoing` — overlapping silent chains
would compound.
