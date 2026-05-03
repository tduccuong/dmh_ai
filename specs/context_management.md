# Context management

What goes into each LLM call's `messages` list, and how the runtime
keeps that list useful as a session grows past the model's window.

## Message assembly

Both pipelines build a fresh `messages` list per turn from DB state
(`ContextEngine.build_confidant_messages/2` /
`build_assistant_messages/2`). General shape:

```
[0]      system prompt
           ├── persona + tool-use rules + output-quality rules
           ├── today's date
           └── user profile (silently injected)

[1..N]   compaction prefix (only when session.context.summary is set)
           {role: user,      content: "[Summary of our conversation so far]\n<summary>"}
           {role: assistant, content: "Understood, I have the full context..."}

[N+1..M] recent messages (from sessions.messages JSON)
           all messages with index > context.summary_up_to_index
           tool_call/tool_result pairs interleaved by ToolHistory.inject

[M+1..P] relevant snippets (optional; keyword retrieval over old messages)

[P+1]    Assistant only: task-list block + ## Active task anchor block
[P+2]    current input (user message OR synthetic [Task due: ...])
```

The Assistant model is fully multilingual — language detection is
NOT a separate step and language is NOT a system-prompt field. The
model picks up the user's language from the current message.

## Compaction

Triggered when one of:

- `recent_turns > masterCompactTurnThreshold` (default 50), OR
- `recent_chars > masterCompactFraction × estimatedContextTokens × 4`
  (defaults: 0.45 × 64_000 × 4 chars/token).

`ContextEngine.compact!`:

1. Slice oldest messages above the keep-recent floor (`@keep_recent =
   20`) into a `to_summarize` set.
2. Call the compactor LLM (`oracleModel`) → produce a summary.
3. Write `{summary, summary_up_to_index}` to `sessions.context`.

The most recent N messages always stay outside the summary so fresh
context is preserved verbatim. Older messages remain in the DB and
remain available for keyword retrieval (the "relevant snippets"
block).

## Tool-result retention (`ToolHistory`)

Orthogonal to compaction. Retains the last few turns' raw
`tool_call` / `tool_result` pairs in `sessions.tool_history` so the
next turn's context build can interleave them back into the LLM
input — the model answers immediate follow-ups without re-running
the tool.

- Trim to `toolResultRetentionTurns` (default 5) and
  `toolResultRetentionBytes` (default 120 000).
- `ToolHistory.inject/2` re-interleaves saved entries before each
  matching assistant-text message (matched by `ts`), reconstructing
  the OpenAI-style `user → assistant(tool_calls) → tool(result) →
  assistant(text)` shape.
- `fetch_task` tool_call/tool_result pairs are stripped before save —
  their bodies already live in `task_turn_archive`, no need to
  duplicate.
- Flushed to `task_turn_archive` on `complete_task` / `cancel_task`
  / `pause_task` so closed tasks stop paying context-rent on every
  subsequent chain.

## Per-message task tag

Every user and assistant message persisted during an anchored chain
carries a `task_num` field alongside `role`, `content`, `ts`. The tag
is set at persistence time:

- **User messages** — `/agent/chat` resolves the current anchor and
  stamps the message. No anchor → untagged.
- **Assistant messages** — `session_chain_loop` persists with the
  anchor's `task_num`.
- **Tool history entries** — tagged by the chain's anchor at save
  time (slicing the chain's own messages from the accumulator).

The tag drives:

1. **Model self-focus.** Prompt rule: when scanning own prior
   messages, ignore those whose `(N)` tag differs from the current
   anchor — those are from a different task the runtime
   interleaved.
2. **Archive partitioning.** Compaction groups `to_summarize` by
   `task_num` and snapshots each group to `task_turn_archive` before
   summarising.
3. **`fetch_task` filtering.** Live messages + tool_history entries
   for a task are retrieved by matching `task_num`.

## Active-task anchor

The runtime — not the model — decides which task is the current
focus of a chain. It communicates the decision via a synthetic user
message at the end of the LLM input, just before the real current
input:

```
## Active task

- Current task: (N)
- Your recent activity on this task is already present in the
  conversation above. Answer / act from it directly.
- Call fetch_task(task_num: N) ONLY as a fallback (compaction
  recovery).
- Once the task is done, close it with complete_task(...).
```

Anchor resolution at chain start, in priority order:

1. Scheduler-triggered silent pickup (`{:task_due, task_id}`) → that
   task.
2. Chain-complete auto-resume → the task the prior chain was on.
3. User-initiated chain on a session with exactly one non-terminal
   task → that task.
4. Otherwise → omitted (free mode; model's next meaningful action is
   usually `create_task`).

The anchor is **mutable mid-chain**, driven by verb tool calls. A
nullable `back_to_when_done_task_num` column on each task row models
a back-stack: when `pickup_task(N)` runs while another task was the
ambient anchor, that ambient task_num is recorded on N. When N
later closes, the anchor returns to it. Net effect: silent periodic
pickups don't strand the user's long-running task — the anchor
reverts naturally.

## Task state continuity — `task_turn_archive`

Compaction loses detail. For tasks that span many chains the
runtime keeps an append-only raw archive per task, hooked into:

- **`ContextEngine.compact!`** — before summarising, group the
  `to_summarize` slice by `task_num` and append each group verbatim
  to `task_turn_archive` keyed by `task_id`.
- **`ToolHistory` eviction** — when a chain rolls out of the
  retention window, snapshot its `tool_call` / `tool_result`
  messages to the archive under the chain's anchor `task_id`.

Per-task sliding cap (`taskArchiveRowCap` / `taskArchiveByteCap`)
trims oldest first. Eviction is terminal — older history compacts
into the master session summary via the usual path.

`fetch_task(task_num)` stitches the model-visible view:

1. Metadata (title, status, type, attachments, result, ...).
2. Archive rows ordered by `original_ts` ASC.
3. Live messages from `session.messages` whose `task_num` matches
   AND `ts` is after the archive's latest `original_ts`.
4. Live tool-history entries tagged with this `task_num`.

The model reads it as a chronological replay of its own prior work
on this task, even after many unrelated chains interleaved.

## Recently-extracted files block

A self-expiring directory generated each Assistant turn from current
`tool_history` state — lists every file whose `extract_content`
tool_call appears in the retention window, cross-referenced to its
originating task_num. Empty on non-extraction sessions. Tells the
model "files whose raw content is in my retained tool messages right
now" so follow-ups don't re-run extraction.

## Attachment marker discipline

User messages may end with `📎 workspace/<name>` lines, one per
attachment. The model sees these in current AND historical messages.

To distinguish "user just attached this" from "user attached this
turns ago", `build_assistant_messages/2` rewrites the `📎 ` lines on
**only the last user message** to `📎 [newly attached] workspace/...`.
Earlier messages render bare. The marker is purely transient — never
written to DB, self-expiring on the next turn.

The Police gate `check_fresh_attachments_read/2` enforces that every
fresh-marked path is passed to `extract_content` before chain end.
Combined with a runtime re-extract dedup (scan recent done tasks for
a prior extraction of the same path; if found, return the prior
`task_result` instead of running the heavy pipeline), heavy
extraction runs at most once per session per file.

## Settings that gate context behaviour

| Key                            | Default  | Controls                                            |
|--------------------------------|----------|-----------------------------------------------------|
| `masterCompactTurnThreshold`   | 50       | Compaction by message count                         |
| `masterCompactFraction`        | 0.45     | Compaction by char-budget fraction                  |
| `estimatedContextTokens`       | 64_000   | Budget driving the char trigger                     |
| `toolResultRetentionTurns`     | 5        | Retained tool-message turns                         |
| `toolResultRetentionBytes`     | 120_000  | Retained tool-message byte ceiling                  |
| `taskArchiveRowCap`            | 60       | Per-task archive sliding row cap                    |
| `taskArchiveByteCap`           | 120_000  | Per-task archive byte cap                           |
| `maxToolResultChars`           | 8_000    | Per-tool-result truncation before injection         |
| `maxAssistantTurnsPerChain`    | 50       | Hard chain-length cap                               |
