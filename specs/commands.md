# Slash Commands

## Goal

Two prefixes the runtime detects on user messages, **fully runtime-handled** — both intercept BEFORE the agent loop and never go through an LLM round-trip on the assistant model:

- `/wiki <text | url | file_path | folder_path>` — write-only.
  Runtime runs the ingest pipeline against the **global wiki** and emits a synthetic ack.
- `/memo <content>` — write-only against the user's **per-user memo store**.
  Runtime vector-ingests the content; emits a localized synthetic ack.

Both slash commands are **verbs that store**. Querying / retrieving stored content is conversational — the user just asks naturally, and the model retrieves:

- **Assistant**: `fetch_memo` is in the LLM tool catalog. The assistant calls it on its own when a question matches stored memo content.
- **Confidant**: no tool loop. Retrieval runs as an automatic pre-step before the LLM call — see `## Confidant memo auto-retrieve` below.

Storage and retrieval are owned by `specs/vector_kb.md`. Pool resolution for the embedding/Oracle models is owned by `specs/api_pools.md`.

## What's in / out

**In scope:**
- Slash-command parser at the chat HTTP entry.
- Source pipelines for `/wiki`: text inline, file, URL crawl, folder scan.
- Sync-ack flow for light sources; async background flow for heavy ones.
- `/memo` save pipeline: vector-ingest + localized ack via `Oracle.localize/2`.
- `kind` column on persisted messages + `ContextEngine` filtering.
- Failure UX (extraction error, broken URL, permission denied folder).

**Out of scope:**
- Authenticated URL crawls (Confluence behind SSO etc.) — v2.
- `.gitignore` parsing for folder scans — v2; v1 ships with a static skiplist.
- Cross-source dedup (same content learned via URL and via file). Source-ref dedup only — see `specs/vector_kb.md`.
- A user-facing `/fetch_memo` — superseded by smart `/memo`. (The `fetch_memo` *tool* is still in the LLM catalog and called naturally by the assistant; only the slash command was removed.)
- Other slash commands (`/help`, `/cancel-wiki`, …) — same dispatch pattern when they land.

## Command parser

Triggered in BOTH `Dmhai.Handlers.AgentChat.handle_assistant_chat/4` AND `handle_confidant_chat/4` — after the entry-point bookkeeping, before persistence + dispatch to the user-agent loop. The runtime command itself (`Commands.Memo.run/4`, the `/wiki` pipelines) is mode-agnostic — only the handler-level intercept needs to live in both routes.

```elixir
case Dmhai.Commands.dispatch(stored_content, session_id, user.id) do
  {:handled, ack_ts} ->
    json(conn, 200, %{ts: ack_ts, handled: true})
    # Returns immediately; the agent loop is never invoked.

  :not_a_command ->
    # Existing flow — append + dispatch to UserAgent.
end
```

Parse rules (`Dmhai.Commands.Parser.parse/1`):

- Match `/wiki <arg>` or `/memo <arg>` at the **start** of the (left-trimmed) message, case-sensitive. Trailing arguments after the first whitespace make up `<arg>` verbatim — no further parsing (preserves URLs with query strings, paths with spaces).
- Empty `<arg>` → handled by the runtime: a usage-hint command_ack, no LLM round-trip.
- A leading `/` followed by anything else (`/foo`, `/help`) → treat as a regular message and continue down the agent path. We don't reserve `/` globally.

## /memo — write-only save

`Dmhai.Commands.Memo.run/4` is the single entry point. **Vector ingest + localize-ack runs asynchronously** under `Dmhai.Agent.TaskSupervisor`. The HTTP request thread persists the user message synchronously (so `user_ts` can return for FE optimistic-render dedup) and returns immediately; the ack lands later via the existing `/poll` channel. This avoids a 1–3 s blocking request while embedding + Oracle.localize run.

Safety default: the user message is always persisted with `kind="command"`. If the background task crashes mid-ingest, the worst case is a "stuck" command-tagged message in scrollback — never an unanswered message in the LLM's context.

```elixir
def run(arg, original_content, session_id, user_id) do
  arg = String.trim(arg)

  if arg == "" do
    Commands.append_command_pair(session_id, user_id, original_content,
      "Usage: `/memo <content to save>`")
  else
    {:ok, user_ts} = persist_user_command(session_id, user_id, original_content)

    Task.Supervisor.start_child(Dmhai.Agent.TaskSupervisor, fn ->
      run_save(arg, session_id, user_id)
    end)

    {:handled, user_ts}
  end
end
```

No classifier — every `/memo <X>` saves `X` verbatim. Querying happens conversationally:

- **Assistant**: model calls `fetch_memo` from its tool catalog when a question matches stored memo content. No `/memo` prefix needed for lookups.
- **Confidant**: an automatic memo-retrieval pre-step attaches matching memos as a `[memo context]` block before each turn (see `## Confidant memo auto-retrieve` below). No `/memo` prefix needed for lookups.

Trade-off: a user typing `/memo what is my bank?` will literally save the question string as a memo. The slash command is a *verb*, not a *mode*.

### Save path

```elixir
defp run_save(text, session_id, user_id) do
  attrs = %{scope: :memo, user_id: user_id, source_kind: "text",
            source_ref: sha256(text), title: nil}

  ack = case VectorDB.ingest(attrs, text) do
    {:ok, _info}     -> Oracle.localize("Saved.", text)
    {:error, reason} -> Oracle.localize("Couldn't save: #{inspect(reason)}", text)
  end

  Commands.append_command_ack(session_id, user_id, ack)
end
```

Persisted messages (both filtered from LLM context):

| Role | Content | kind |
|---|---|---|
| user      | `/memo my bank is NorthWest Trust` | `command`     |
| assistant | `Saved.` (or `Đã lưu.` if user wrote in VN) | `command_ack` |

### Localizing acks via `Oracle.localize/2`

`Dmhai.Agent.Oracle.localize/2` is a generic helper that takes a meaning + a user-input language signal and returns the meaning expressed in the user's language (or English on weak/unclear signal). Used by:

- `/memo` save success — localizes `"Saved."` against the input text.
- `/memo` save error path — localizes `"Couldn't save: <reason>"` against the input text.
- `/memo` empty arg → uses English usage hint verbatim (no input → no language signal).
- `/wiki` text pipeline — localizes `WikiAck.final_ack/1` against the body.
- `/wiki` file pipeline — localizes against the extracted body.
- `/wiki` URL pipeline — localizes the accepted ack against the URL (weak signal → English) and the final ack against the fetched page text (strong signal).
- `/wiki` folder pipeline — localizes accepted + final acks against the path (weak signal → English).
- `Commands.finalize_command/4` error branch — localizes `"Couldn't process: <reason>"`.

Localize is soft-failing: any Oracle error returns the input message verbatim, so a flaky classifier never strands the user with no ack.

## Confidant memo auto-retrieve

Confidant runs no tools, so the model can't call `fetch_memo` on its own. To make memos work for natural-language follow-ups in Confidant ("what is John's birthday?", "and his email?"), the runtime auto-retrieves relevant memos as a pre-step before every Confidant LLM call and attaches them as a `[memo context]` block in the prompt. Assistant does NOT auto-retrieve — it relies on the model's own decision to call `fetch_memo`.

### Pipeline

```
user msg arrives
   ↓
embed_text = concat(prior_user_turns[-2..], current_msg)
   ↓
Embedder.embed(embed_text)
   ↓
VectorDB.search(:memo, embed_text, vec, top_k, {:user, user_id})
   ↓
filter score ≥ kb_score_threshold; cap at memo_context_top_k
   ├─ zero hits        → EMPTY-state [memo context] block (telling the
   │                     model "we checked, nothing relevant — answer
   │                     honestly if it's a personal-fact question")
   └─ ≥1 hits          → POPULATED [memo context] block (bulleted hits
                         + language rule)
   ↓
ContextEngine.build_confidant_messages(memo_context: block)
   ↓
Confidant LLM
```

The block is **always attached** when retrieval ran successfully (regardless of hit count). Only an embed/search RPC failure suppresses the block entirely (graceful degradation). This is what makes Confidant honest: when no memo matches the question, the model receives an explicit "we searched and found nothing" signal and tells the user truthfully, instead of falling back to hallucinated general knowledge framed as personal fact.

### Block format — two states

**Found state:**

```
[memo context]
The user previously saved these personal notes. Use any that are relevant to the question; ignore the rest. The notes may be in a different language than the user's question — translate any facts you cite. Reply in the user's question language, NOT the notes' language.

- <chunk_text>
- <chunk_text>
[/memo context]
```

**Empty state:**

```
[memo context]
We checked the user's saved memos for this question. Nothing relevant found.

How to use this signal:
- IF the user's message itself references their memo store (e.g. words like "memo", "saved", phrases like "search memo …", "find in memo …", "look up memo …", "do I have a memo on …", "memo about …", "memo contains …"): you MUST tell the user honestly that no saved memo matches their question. Do NOT substitute general knowledge, do NOT invent.
- OTHERWISE (the user is asking a normal question or chatting and never mentioned the memo store): ignore this block entirely and answer per your usual system-prompt instructions.
[/memo context]
```

The empty-state wording is **anchored on a lexical trigger in the user's input**, not on the model classifying whether the question is personal-fact-flavored. This avoids the gate problem `Oracle.memo_keywords` had — the model only changes behavior when the user explicitly invoked memo, which is unambiguous from the message text.

The retrieval and `WebSearchEngine.search` run in parallel (`Task.async`) so total pre-step latency is `max(t_memo, t_websearch)` rather than the sum.

### Why no LLM gate

An earlier design used an Oracle classifier (`memo_keywords/2`) to decide whether to retrieve at all, with the goal of skipping embed+search on chitchat. In practice the gate failed in the **cross-session case**: a question like "who eats chicken?" in a fresh session got classified `NONE` because Oracle's only signal is the user's text + recent same-session turns — it has no view of what's actually saved in the memo store. The user's answer ("my wife eats chicken") was sitting in the memo store, but a fresh session never retrieved it.

The fix is to remove the gate and **always** embed + search. The score threshold (`kb_score_threshold`, default 0.55) is the real filter; chitchat embeddings score low against personal-fact memos and get dropped naturally. Cost analysis:

| Step | Latency |
|---|---|
| Embed (qwen3-0.6b) | ~30 ms |
| `VectorDB.search` | ~10 ms |
| Total per turn | ~40 ms |
| Old Oracle gate per turn | 250–500 ms |

The simpler design is also faster on average. Pronoun resolution falls out implicitly because the embed input concatenates the last 1–2 prior user turns with the current message — embedding co-occurrence carries over, no rewrite step needed.

### Persistence and prompt wrapping

The block is **prepended to the current user message** at build time (mirrors how `[web context]` is wrapped today in `build_current_msg/4`). The wrap is build-time only — `session.messages` stores the user message as the user typed it, with no wrap. Each turn rebuilds fresh against a fresh embed + search; **no accumulation**.

The language rule in the FOUND-state preamble is load-bearing: vec0 cosine retrieval is multilingual via `qwen3-embedding`, so a Vietnamese question can hit an English memo. Without the rule, weak Confidant models echo the memo's language back to the user instead of translating.

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `memo_context_top_k`  | `5` | Max hits attached to the `[memo context]` block per turn. |
| `kb_score_threshold`  | `0.55` | Existing — drops weak hits before ranking. Shared with `fetch_memo` and the Assistant retrieval pipeline. |

### Persistence invariant

The `[memo context]` block lives ONLY in the in-flight prompt sent to the Confidant LLM. It is NEVER:
- written to `session.messages`,
- echoed back to the FE,
- visible to the next turn's history scan.

This is what makes the "fresh each turn, never accumulates" property hold. The pattern is identical to how `web_context` and `profile` work today.

## /wiki — write-only ingest

The wiki path is unchanged from earlier specs. Source classification (URL → folder → file → text) and sync-vs-async dispatch live in `Dmhai.Commands.Pipelines.{URL,Folder,File,Text}`. All four pipelines persist `kind="command"` / `kind="command_ack"` pairs via `Commands.append_command_pair/4` so they're invisible to the LLM context engine.

### Source classification

Argument is classified in this order:

1. **URL** — matches `^https?://`. Pipeline: BFS deep crawl over same-prefix pages (`learn_url_max_depth`, `learn_url_max_pages`, `learn_url_concurrency` in `AgentSettings`; concurrency defaults to 1 so the FE renders the crawl as a strict sequence of progress rows). Each page emits a `session_progress` 'tool' row labeled `IndexWiki -> <sliced url>`, pending → done with duration. The accepted-ack is returned synchronously; the final ack summarises pages indexed and any failures, and Oracle-localizes the summary using the first page's text as language signal.
2. **Folder** — matches an existing absolute path that is a directory. Pipeline: recursive scan with skiplist + extension whitelist.
3. **File** — matches an existing absolute path that is a file. Pipeline: `extract_content` then index.
4. **Text** — fallback. Pipeline: index inline.

### Sync vs async

| Pipeline | Mode | Reasoning |
|---|---|---|
| Inline text | sync | Single-chunk-or-few; finishes in <1s. |
| File ≤ 5 MB | sync | Most config / README sized; extraction + embedding completes fast. |
| File > 5 MB | async | OCR-heavy PDFs, large logs. |
| URL         | async | Crawl is unbounded by definition. |
| Folder      | async | Same. |

The 5 MB threshold is `learn_sync_max_file_bytes` in AgentSettings (configurable — magic-number rule).

Sync ack — `WikiAck.final_ack/1` — uses the 18-word title-truncate convention:
```
"I indexed your input about '<title…>' in the internal Wiki, ready to use from now."
```

Async ack — `WikiAck.accepted_ack/1` — initial:
```
"Noted, indexing '<title…>' in the background — I'll confirm when done."
```

…followed by `session_progress` rows streaming live status; final assistant ack persisted on completion using `WikiAck.final_ack/1`.

## Persistence model

### Messages with `kind`

`messages` (the JSON column on `sessions`) carries a `kind` field on entries (existing pattern, also used for `service_connected` / `form_response`):

| Kind | Role | Meaning | In LLM context? |
|---|---|---|---|
| (absent)            | user / assistant | Regular chat. | yes |
| `command`           | user             | The original `/wiki …` or `/memo …` text. | **no** |
| `command_ack`       | assistant        | Runtime-synthesised ack for `/wiki` and `/memo`. | **no** |
| `service_connected` | user             | (existing) MCP attach receipt. | no (already filtered) |
| `form_response`     | user             | (existing) request_input synthesis. | yes (already passed through) |

Filter step in `Dmhai.Agent.ContextEngine.build_core/4`:

```elixir
messages
|> Enum.reject(&(&1["_archived"] == true))
|> Enum.reject(fn m -> m["kind"] in ["command", "command_ack"] end)
```

Same filter applies to both `build_assistant_messages/2` and `build_confidant_messages/2` (it lives in their shared `build_core/4` private). Filtered messages are still serialised to FE on `/sessions/:id` reads — **scrollback works exactly as for normal chat**.

### FE rendering

`kind="command"` and `kind="command_ack"` are **BE-only markers**. The FE renders them identically to normal chat — same bubble, same role, same colors (no `msg-command` class, no opacity reduction). The only difference is that the BE filters them from the LLM's context window.

This is deliberate: from the user's perspective, a `/memo my X is 42` line they typed *is* their message, and `Saved.` *is* a legitimate assistant reply. They should look it up in scrollback the same way they look up any other exchange.

## Cross-spec contract summary

| Boundary | Owner | Contract |
|---|---|---|
| Embed text → vector              | `vector_kb.md` | `Embedder.embed(text)` / `Embedder.embed_batch(texts)` |
| Vector upsert                    | `vector_kb.md` | `VectorDB.ingest(attrs, body)` with `:scope` ∈ `:knowledge | :memo` |
| Memo retrieval                   | `vector_kb.md` | `VectorDB.search(:memo, vec, top_n, {:user, user_id})` |
| Pool resolution                  | `api_pools.md` | `Pools.resolve("<pool>::<model>")` |
| Account rotation back-pressure   | `api_pools.md` | `{:error, :all_throttled, retry_ms}` |
| Source registry                  | `vector_kb.md` | `KbSources.upsert(scope, kind, ref, raw_text)` |

This spec stops at "ingest succeeded; chunks land in vec0" and "Oracle answered the query". Retrieval indexing detail belongs in `vector_kb.md`. Pool/auth detail belongs in `api_pools.md`. Together they form the full feature.
