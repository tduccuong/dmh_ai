# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Commands.Memo do
  @moduledoc """
  Unified `/memo <input>` runtime command. Two Oracle round-trips
  worst case (classify + digest); the request thread blocks on
  neither — the user message is persisted synchronously to keep
  FE optimistic-render dedup happy, then a `Task.Supervisor` child
  runs classify + ingest/fetch/digest in the background and posts
  the result via the existing `/poll` channel.

  Branches:

    * `:save` — input is a fact / preference / note. Run vector
      ingest; persist ack with `kind="command_ack"`. The user
      message keeps its initial `kind="command"` tag so
      ContextEngine excludes both from LLM context.

    * `:query` — input is a question / lookup. Fetch hits from the
      memo store, dispatch the Oracle to compile a natural-language
      answer. Strip the user message's `kind` tag and persist the
      answer without one so the legitimate Q&A pair flows into the
      next assistant turn's LLM context.

  Safety: the user message is always persisted synchronously with
  `kind="command"` first. If the background task crashes mid-
  classify, the worst case is a stuck "command" message in
  scrollback — never an unanswered query polluting the LLM
  context.

  Misclassification fallback: any Oracle error or unparseable
  verdict routes to `:save` (we keep the input verbatim; user can
  rephrase to retry as a query).

  See specs/commands.md.
  """

  alias Dmhai.Agent.{AgentSettings, LLM, Oracle, UserAgentMessages}
  alias Dmhai.Commands
  alias Dmhai.VectorDB
  alias Dmhai.VectorDB.Embedder
  require Logger

  @spec run(String.t(), String.t(), String.t(), String.t()) :: {:handled, non_neg_integer()}
  def run(arg, original_content, session_id, user_id) do
    arg = String.trim(arg)

    if arg == "" do
      # No input → no language signal; English usage hint, sync.
      Commands.append_command_pair(session_id, user_id, original_content,
        "Usage: `/memo <fact to save | question to look up>`")
    else
      # Persist user msg synchronously with kind="command" — this
      # is the safe default (filtered from LLM context) and gives
      # us a `user_ts` to return immediately so the FE can patch
      # its optimistic copy.
      {:ok, user_ts} = UserAgentMessages.append(session_id, user_id, %{
        role: "user",
        content: original_content,
        kind: "command"
      })

      Task.Supervisor.start_child(Dmhai.Agent.TaskSupervisor, fn ->
        do_async(arg, session_id, user_id, user_ts)
      end)

      {:handled, user_ts}
    end
  end

  # Background worker — runs after the HTTP response has already
  # closed. Result lands in `session.messages` and reaches the FE
  # via `/poll`.
  defp do_async(arg, session_id, user_id, user_ts) do
    case classify(arg) do
      {:save, save_ack} ->
        run_save(arg, save_ack, session_id, user_id)

      {:query, _} ->
        # The user message was persisted with kind="command" as a
        # safe default. Strip it now — the Q&A pair belongs in the
        # LLM context.
        case UserAgentMessages.update_kind(session_id, user_id, user_ts, nil) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[Memo] couldn't strip kind from user msg ts=#{user_ts}: #{inspect(reason)}")
        end

        run_query(arg, session_id, user_id)
    end
  rescue
    e ->
      Logger.error("[Memo] async worker crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
  end

  # ── save path ────────────────────────────────────────────────────────

  defp run_save(text, save_ack, session_id, user_id) do
    attrs = %{
      scope:       :memo,
      user_id:     user_id,
      source_kind: "text",
      source_ref:  sha256(text),
      title:       nil
    }

    ack =
      case VectorDB.ingest(attrs, text) do
        {:ok, _info} ->
          # Pre-localized by `classify/1` in the same Oracle round-trip,
          # so save success doesn't pay a second translation call.
          save_ack

        {:error, reason} ->
          # Rare path — pay the extra Oracle round-trip to localize.
          Oracle.localize("Couldn't save: #{inspect(reason, limit: 80)}", text)
      end

    UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: ack,
      kind: "command_ack"
    })
  end

  # ── query path ───────────────────────────────────────────────────────

  defp run_query(q, session_id, user_id) do
    answer =
      case fetch_hits(q, user_id) do
        {:ok, []} ->
          # Empty result still goes to LLM context — next turn knows
          # we already looked, so the assistant won't re-fetch.
          Oracle.localize("I don't have any saved memo matching `#{q}`.", q)

        {:ok, hits} ->
          # Digest call already produces output in the user's
          # language (see `digest_system_prompt/0`). No extra
          # localize call.
          compile_answer(q, hits)

        {:error, reason} ->
          # Search infrastructure failure — surfaces as a plain
          # assistant message (no kind tag) so the LLM sees the
          # exchange and can retry / apologize on the next turn if
          # needed.
          Oracle.localize("Couldn't search memos: #{inspect(reason, limit: 80)}", q)
      end

    UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: answer
    })
  end

  defp fetch_hits(q, user_id) do
    with {:ok, vec}      <- Embedder.embed(q),
         {:ok, raw_hits} <- VectorDB.search(:memo, q, vec, AgentSettings.kb_top_n(), {:user, user_id}) do
      threshold = AgentSettings.kb_score_threshold()
      hits      = Enum.filter(raw_hits, fn h -> (h.score || 0.0) >= threshold end)
      log_hits(q, raw_hits, hits, threshold)
      {:ok, hits}
    end
  end

  # One-line summary of what the vector DB returned BEFORE and
  # AFTER the score threshold filter. Lands in the runtime log
  # alongside the Oracle trace so we can tell "VDB returned X but
  # threshold dropped it" / "VDB returned X and Oracle ignored it"
  # / "VDB never returned X" apart when diagnosing.
  defp log_hits(q, raw_hits, kept_hits, threshold) do
    summary =
      raw_hits
      |> Enum.map(fn h ->
        score = if is_number(h.score), do: Float.round(h.score, 3), else: h.score
        "#{score}|#{h.source_kind}:#{String.slice(h.source_ref || "", 0, 16)}"
      end)
      |> Enum.join(", ")

    Logger.info("[Memo] VDB query=#{inspect(q)} returned #{length(raw_hits)} raw hits (kept #{length(kept_hits)} at threshold ≥ #{threshold}): [#{summary}]")
  end

  # Single Oracle round-trip to compile a short, natural answer from
  # the matched chunks. Falls back to a plain chunk listing if the
  # call fails — at least the user gets *something* instead of a
  # silent empty.
  defp compile_answer(q, hits) do
    chunks_text =
      hits
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {h, i} -> "[#{i}] #{h.chunk_text}" end)

    messages = [
      %{role: "system", content: digest_system_prompt()},
      %{role: "user",   content: "User asked:\n#{q}\n\nMatching saved memos:\n#{chunks_text}"}
    ]

    trace = %{origin: "system", path: "Commands.Memo.compile_answer", role: "MemoDigest", phase: "digest"}

    case LLM.call(AgentSettings.oracle_model(), messages, options: %{temperature: 0.0}, trace: trace) do
      {:ok, text} when is_binary(text) and text != "" ->
        String.trim(text)

      _ ->
        "Found #{length(hits)} match#{if length(hits) == 1, do: "", else: "es"}:\n\n" <> chunks_text
    end
  rescue
    e ->
      Logger.warning("[Memo] Oracle digest failed: #{Exception.message(e)}")
      "Found #{length(hits)} matches but couldn't compile a summary."
  end

  defp digest_system_prompt do
    """
    You are composing a reply to the user's question about their saved memos. You receive:
      1. the user's question — this also defines the language of your reply
      2. one or more matching memo entries the user previously saved

    Hard rules — read carefully, follow strictly:

      LANGUAGE
      - Reply in the SAME LANGUAGE the user wrote their question in. If the matching memos are in a different language, translate the relevant facts back into the question's language. Do NOT echo memo text in its original language unless the question itself was in that language.

      FAITHFUL TO THE MEMOS — DO NOT INVENT
      - Use ONLY facts present in the matching memos. If a fact isn't in the memos, do NOT invent, infer, or extrapolate it. If the memo says "1 cat (red)", you say "1 cat, red" — never "2 cats" or "black".
      - Pay special attention to NUMBERS, COLORS, DATES, and ANIMAL/OBJECT TYPES. Read them character by character; do NOT swap a dog ("chó" / "dog" / "Hund") for a cat or vice versa. Do NOT change colors. Do NOT round dates.
      - If the memo wording is unclear or abbreviated (no diacritics, slang), reproduce it as best you can but never replace ambiguous words with confident guesses.

      NAMES AS WRITTEN — MULTI-WORD NAMES ARE ONE ENTITY
      - Treat names exactly as written. A multi-word name like "Jan John", "Mary Anne", "Lily John" is ONE person, NOT two. Never split them. Never assume two adjacent capitalized words are two separate people.

      ATTRIBUTION
      - Attribute each fact to the named entity exactly as the memo states. If the memo says "Jan John has a cat", reply about "Jan John's cat" — never about "your cat" or "the cat" without context. Only use "you/your" when the memo explicitly refers to the user (e.g., "my bank is X" → "your bank is X").

      DISAMBIGUATION
      - If the matching memos clearly describe MULTIPLE DIFFERENT ENTITIES that all fit the user's query term (e.g., the user asked about "John" and the memos mention several different people named John, or several different projects called "Atlas"), do NOT pick one. Reply with a brief clarifying question that lists the candidates so the user can disambiguate.

      NO ENTITY MATCH
      - If none of the chunks clearly match the entity the user asked about, reply that you don't have that information about that entity. Do NOT force an answer from a partially-matching chunk that's about a different entity.

      FORMAT
      - Otherwise, compose ONE short natural-language answer drawn from the memo content. Plain text only — no markdown headers, no tool calls, no thinking aloud, no apologies.
      - If the answer is a single fact (a number, name, date, account), state it plainly.
    """
  end

  # ── Oracle classifier ────────────────────────────────────────────────

  # Default English save ack — used as a fallback when the classify
  # call errors out (we still want SOMETHING in the user's chat) and
  # as the literal source string the localize prompt translates from.
  @default_save_ack "Saved."

  @doc """
  Classify a `/memo <input>` as `{:save, save_ack}` or `{:query, nil}`
  via a single Oracle round-trip. The classify prompt asks Oracle to
  also produce a localized save-success ack on the SAVE branch — so
  the common save path costs ONE round-trip total, not two.

  Any error / unparseable verdict falls back to `{:save, "Saved."}`
  (conservative: keep the input verbatim, default English ack).
  """
  @spec classify(String.t()) :: {:save, String.t()} | {:query, nil}
  def classify(input) when is_binary(input) do
    messages = [
      %{role: "system", content: classify_system_prompt()},
      %{role: "user",   content: input}
    ]

    trace = %{origin: "system", path: "Commands.Memo.classify", role: "MemoClassify", phase: "classify"}

    case LLM.call(AgentSettings.oracle_model(), messages, options: %{temperature: 0}, trace: trace) do
      {:ok, text} when is_binary(text) ->
        parse_verdict(text)

      {:ok, {:tool_calls, _}} ->
        {:save, @default_save_ack}

      {:error, reason} ->
        Logger.warning("[Memo] classify error: #{inspect(reason)}")
        {:save, @default_save_ack}
    end
  rescue
    e ->
      Logger.error("[Memo] classify raised: #{Exception.message(e)}")
      {:save, @default_save_ack}
  end

  defp classify_system_prompt do
    """
    You classify a one-line user input that arrived via the `/memo` command, AND prepare a localized acknowledgement for the SAVE branch in one shot.

    Decide:
      SAVE   — the user wrote a fact, preference, account detail, note, reminder, or piece of personal context they want recorded for later. Examples: "my bank is NorthWest Trust", "I prefer green tea", "rent is due on the 1st".
      QUERY  — the user wrote a question, lookup, or recall request that expects an answer drawn from previously saved memos. Examples: "what's my bank", "where do I store passwords", "do I have any notes about Q3 plans?".

    Output format — EXACTLY two lines for SAVE, one line for QUERY:

      SAVE
      <a GENERIC one-sentence confirmation in the user's language that the memo was saved. STRICT: do NOT paraphrase, summarize, describe, parse, or interpret the user's input — leave the content untouched. Treat names exactly as written: a multi-word name like "Jan John" or "Mary Anne" is ONE entity, never split it into multiple people. Plain text, no quotes, no markdown, no preamble. Detect the language from the input; if unclear, use English.>

      QUERY

    Examples:
      Input: "my bank is NorthWest Trust"           → SAVE\\nSaved.
      Input: "ngân hàng của tôi là Vietcombank"    → SAVE\\nĐã lưu.
      Input: "jan john con co 1 con cho mau xanh"  → SAVE\\nĐã lưu.   (NOT "Đã lưu thông tin về Jan và John")
      Input: "what's my bank?"                      → QUERY
      Input: "ngân hàng của tôi là gì?"             → QUERY

    No explanation, no extra lines.
    """
  end

  defp parse_verdict(text) do
    lines =
      text
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)

    case lines do
      [first | rest] ->
        verdict =
          first
          |> String.upcase()
          |> String.split(~r/\W+/, trim: true)
          |> List.first()

        case verdict do
          "QUERY" ->
            {:query, nil}

          "SAVE" ->
            ack =
              rest
              |> Enum.join(" ")
              |> String.trim()
              |> strip_wrapping_quotes()

            {:save, if(ack == "", do: @default_save_ack, else: ack)}

          _ ->
            Logger.warning("[Memo] unparseable classify verdict: #{inspect(String.slice(text, 0, 120))}")
            {:save, @default_save_ack}
        end

      _ ->
        {:save, @default_save_ack}
    end
  end

  defp strip_wrapping_quotes(s) do
    s
    |> String.trim_leading(~s("))
    |> String.trim_trailing(~s("))
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp sha256(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
end
