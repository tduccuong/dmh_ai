# Slash Commands

## Goal

Two prefixes the runtime detects on user messages, **fully runtime-handled** — both intercept BEFORE the agent loop and never go through an LLM round-trip on the assistant model:

- `/wiki <text | url | file_path | folder_path>` — write-only.
  Runtime runs the ingest pipeline against the **global wiki** and emits a synthetic ack.
- `/memo <input>` — read OR write against the user's **per-user memo store**.
  Runtime Oracle-classifies the argument as SAVE or QUERY, then routes:
  - SAVE  → vector-ingest the text; ack as a synthetic assistant message.
  - QUERY → fetch hits, dispatch Oracle to compile a natural-language answer; surface as a regular assistant message that **does** flow into the next LLM turn's context.

Storage and retrieval are owned by `specs/vector_kb.md`. Pool resolution for the embedding/Oracle models is owned by `specs/api_pools.md`.

## What's in / out

**In scope:**
- Slash-command parser at the chat HTTP entry.
- Source pipelines for `/wiki`: text inline, file, URL crawl, folder scan.
- Sync-ack flow for light sources; async background flow for heavy ones.
- Oracle classifier on every `/memo` invocation (SAVE vs QUERY).
- `kind` column on persisted messages + `ContextEngine` filtering.
- Failure UX (extraction error, broken URL, permission denied folder, classify timeout).

**Out of scope:**
- Authenticated URL crawls (Confluence behind SSO etc.) — v2.
- `.gitignore` parsing for folder scans — v2; v1 ships with a static skiplist.
- Cross-source dedup (same content learned via URL and via file). Source-ref dedup only — see `specs/vector_kb.md`.
- A user-facing `/fetch_memo` — superseded by smart `/memo`. (The `fetch_memo` *tool* is still in the LLM catalog and called naturally by the assistant; only the slash command was removed.)
- Other slash commands (`/help`, `/cancel-wiki`, …) — same dispatch pattern when they land.

## Command parser

Triggered in `Dmhai.Handlers.AgentChat.handle_assistant_chat/4` (`handlers/agent_chat.ex:140`) — after attachment-path rewriting, before `UserAgentMessages.append/2`.

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

## /memo — the smart command

`Dmhai.Commands.Memo.run/4` is the single entry point. **The classify + ingest/fetch/digest chain runs asynchronously** under `Dmhai.Agent.TaskSupervisor`. The HTTP request thread persists the user message synchronously (so `user_ts` can return for FE optimistic-render dedup) and returns immediately; the ack or answer lands later via the existing `/poll` channel. This avoids a 2–5 s blocking request whenever Oracle is in the loop.

Safety default: the user message is always persisted with `kind="command"` first. If the background task crashes mid-classify, the worst case is a "stuck" command-tagged message in scrollback — never an unanswered query message in the LLM's context. After classify succeeds, the QUERY branch strips the kind tag via `UserAgentMessages.update_kind/4` so the legitimate Q&A pair flows into the next assistant turn.

```elixir
def run(arg, original_content, session_id, user_id) do
  arg = String.trim(arg)

  if arg == "" do
    Commands.append_command_pair(session_id, user_id, original_content,
      "Usage: `/memo <fact to save | question to look up>`")
  else
    case classify(arg) do
      :query -> run_query(arg, original_content, session_id, user_id)
      _      -> run_save(arg, original_content, session_id, user_id)
    end
  end
end
```

### Oracle classifier

`Memo.classify/1` runs a single Oracle round-trip and returns `{:save, save_ack} | {:query, nil}`. The Oracle prompt asks for a two-line output for SAVE (verdict + a localized one-sentence acknowledgement in the user's language) and a one-line output for QUERY. Folding the localized save-success ack into the classify call means the **save common path costs ONE Oracle round-trip total**, not two.

| Input | Verdict | Line 2 |
|---|---|---|
| "my bank is NorthWest Trust"      | SAVE  | `Saved.`             |
| "ngân hàng của tôi là Vietcombank" | SAVE  | `Đã lưu.`            |
| "I prefer green tea"              | SAVE  | `Saved.`             |
| "what's my bank?"                 | QUERY | (none)              |
| "ngân hàng của tôi là gì?"        | QUERY | (none)              |
| "do I have any notes about Q3?"   | QUERY | (none)              |

Verdict parsing is forgiving — first uppercase token of line 1, after a `\W+` split. Line 2 is taken verbatim (with wrapping quotes stripped). Any error / unparseable verdict → `{:save, "Saved."}` (conservative fallback: keep the input, default English ack).

Model: `oracleModel` (configurable in `AgentSettings`; default `ministral-3:14b-cloud` — small, fast, cheap).

### Localizing the rare-path acks

The classify call covers save success. The remaining ack sites pay one extra Oracle round-trip via `Dmhai.Agent.Oracle.localize/2` — a generic helper that takes a meaning + a user-input language signal and returns the meaning expressed in the user's language (or English on weak/unclear signal):

- `/memo` save **error** path — localizes `"Couldn't save: <reason>"` against the input text.
- `/memo` query **empty hits** — localizes `"I don't have any saved memo matching <q>"` against the query.
- `/memo` query **infra error** — localizes `"Couldn't search memos: <reason>"` against the query.
- `/memo` empty arg → uses English usage hint verbatim (no input → no language signal).
- `/wiki` text pipeline — localizes `WikiAck.final_ack/1` against the body.
- `/wiki` file pipeline — localizes against the extracted body.
- `/wiki` URL pipeline — localizes the accepted ack against the URL (weak signal → English) and the final ack against the fetched page text (strong signal).
- `/wiki` folder pipeline — localizes accepted + final acks against the path (weak signal → English).
- `Commands.finalize_command/4` error branch — localizes `"Couldn't process: <reason>"`.

Localize is soft-failing: any Oracle error returns the input message verbatim, so a flaky classifier never strands the user with no ack.

### Save path

```elixir
defp run_save(text, original_content, session_id, user_id) do
  attrs = %{scope: :memo, user_id: user_id, source_kind: "text",
            source_ref: sha256(text), title: nil}

  ack = case VectorDB.ingest(attrs, text) do
    {:ok, _info}     -> "Saved."
    {:error, reason} -> "Couldn't save: #{inspect(reason)}"
  end

  Commands.append_command_pair(session_id, user_id, original_content, ack)
end
```

Persisted messages (both filtered from LLM context):

| Role | Content | kind |
|---|---|---|
| user      | `/memo my bank is NorthWest Trust` | `command`     |
| assistant | `Saved.`                            | `command_ack` |

### Query path

```elixir
defp run_query(q, original_content, session_id, user_id) do
  case fetch_hits(q, user_id) do
    {:ok, []} ->
      persist_query_pair(session_id, user_id, original_content,
        "I don't have any saved memo matching `#{q}`.")

    {:ok, hits} ->
      answer = compile_answer(q, hits)   # one Oracle round-trip
      persist_query_pair(session_id, user_id, original_content, answer)

    {:error, reason} ->
      # Search infra failure — falls back to a kind-tagged ack so
      # the apology doesn't pollute LLM context.
      Commands.append_command_pair(session_id, user_id, original_content,
        "Couldn't search memos: #{inspect(reason)}")
  end
end
```

Persisted messages (both **kept in** LLM context — no `kind` tag):

| Role | Content |
|---|---|
| user      | `/memo what is my bank?`                        |
| assistant | `Your bank is NorthWest Trust.` (Oracle digest) |

The query path exposes the Q&A pair to the next assistant turn so the LLM:
- knows the user already asked about the memo and got an answer,
- can answer follow-ups ("can you elaborate?") from context without re-fetching.

The Oracle digest is one round-trip with a system prompt asking for *one short natural answer*, plain text, in the user's language. On Oracle failure: fallback to a templated chunk listing — at least the user gets something instead of silence.

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
| (absent)            | user / assistant | Regular chat (incl. **/memo query path**). | yes |
| `command`           | user             | The original `/wiki …` text or **/memo save** text. | **no** |
| `command_ack`       | assistant        | Runtime-synthesised ack for `/wiki` and `/memo` save path. | **no** |
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
