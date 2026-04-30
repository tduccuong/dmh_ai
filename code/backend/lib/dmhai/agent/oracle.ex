# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Oracle do
  @moduledoc """
  Independent classifier consulted by Police's anchor-pivot gate.

  Compares the chain-start user message against the active anchor's
  `task_spec` and returns one of three classes:

    * `:related`   — the message extends, refines, or replies to the
      anchor; tools may run as usual.
    * `:unrelated` — the message is off-topic from the anchor; the
      assistant must confirm with the user (pause / cancel / stop)
      before any tool work for the new ask.
    * `:knowledge` — the message is a greeting, chitchat, identity
      question, or factual question answerable from the model's
      training (no live lookup needed); regardless of anchor, no tool
      call should run for it.

  Soft fail: any error (timeout, transport, parse) returns `:error`.
  Police treats `:error` as a pass-through so a flaky classifier
  never blocks legitimate work.

  Also exposes `localize/2` — a small helper to express a runtime
  ack template in the user's language. Used by `/memo` (rare error /
  empty-result paths; the common save-success ack is folded into
  `Dmhai.Commands.Memo.classify/1` to avoid an extra round-trip) and
  by `/wiki` pipelines for their accepted/final acks.

  Model role: `oracleModel` (configurable via AgentSettings; default
  ministral-3:14b-cloud — small, fast, cheap).
  """

  require Logger
  alias Dmhai.Agent.{AgentSettings, LLM}

  @doc """
  Classify a user message against an anchor task spec. Returns one of
  `:related | :unrelated | :knowledge | :error`.

  Optionally takes the assistant's most recent reply as conversational
  context — when the assistant just asked a clarifying question, the
  user's terse follow-up reply ("yes", a stage name, an account, …) is
  RELATED, not DONE / UNRELATED. Without that context Oracle is blind
  to "user is answering my question" and misclassifies short replies.
  Callers that don't have the prior reply pass `nil`.

  When `anchor_task_spec` is `nil` or empty, the RELATED/UNRELATED
  axis is meaningless and we report `:related` (pass-through);
  KNOWLEDGE is still meaningful but the caller (Police) only fires
  the gate when an anchor exists, so this is fine.
  """
  @spec classify(String.t(), String.t() | nil) ::
          :related | :unrelated | :knowledge | :error
  def classify(user_msg, anchor_task_spec), do: classify(user_msg, anchor_task_spec, nil)

  @spec classify(String.t(), String.t() | nil, String.t() | nil) ::
          :related | :unrelated | :knowledge | :error
  def classify(user_msg, anchor_task_spec, prev_assistant_msg)
      when is_binary(user_msg) and
           (is_binary(anchor_task_spec) or is_nil(anchor_task_spec)) and
           (is_binary(prev_assistant_msg) or is_nil(prev_assistant_msg)) do
    spec = (anchor_task_spec || "") |> String.trim()

    if spec == "" do
      :related
    else
      do_classify(user_msg, spec, prev_assistant_msg)
    end
  end

  def classify(_, _, _), do: :error

  # ── private ───────────────────────────────────────────────────────────

  defp do_classify(user_msg, spec, prev_assistant_msg) do
    model = AgentSettings.oracle_model()

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: user_prompt(user_msg, spec, prev_assistant_msg)}
    ]

    trace = %{origin: "system", path: "Agent.Oracle.classify", role: "OraclePivot", phase: "classify"}

    case LLM.call(model, messages, options: %{temperature: 0}, trace: trace) do
      {:ok, text} when is_binary(text) ->
        parse_verdict(text)

      {:ok, {:tool_calls, _}} ->
        # Classifier model isn't supposed to emit tool_calls — its
        # tools list was empty. Treat this as a parse failure.
        :error

      {:error, reason} ->
        Logger.warning("[Oracle] classify error: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.error("[Oracle] classify raised: #{Exception.message(e)}")
      :error
  end

  defp system_prompt do
    """
    You are a classifier. You read an active task spec, optionally the assistant's last reply, and the user's current message. Output exactly one word.

    Output one of:
      RELATED    — the user message extends, clarifies, refines, or replies to the active task. If the assistant's last reply was a clarifying question (e.g. "which option?", "which stage?", "do you want X or Y?"), the user's reply is ALWAYS RELATED — even when it's terse like a single name, status, number, "yes", or "the second one".
      DONE       — the user wants to STOP / CLOSE / CANCEL / PAUSE the active task with NO follow-up. Requires an EXPLICIT termination verb: "stop", "cancel", "abort", "drop", "pause", "close", "no need", "ko cần", "đóng nhiệm vụ", "thôi", "quitter", "annule". Naming a status, stage, option, or value the assistant offered in its last reply is NEVER DONE — it's RELATED. Phrases like "switch to X" or "use Y" are NOT termination — they're choosing an option, RELATED.
      UNRELATED  — the user message proposes a DIFFERENT task to do instead — off-topic from the active task AND describes new work that would need different tools or different research. Pick this only when the user is genuinely pivoting to a new objective, not just closing the current one or answering a question.
      KNOWLEDGE  — the user message is a greeting, chitchat, identity question, or factual question a competent assistant can answer from its own training without any tool call (no live data, no current events, no user-specific lookup). Pick this regardless of how it relates to the active task whenever it applies.

    Priority when more than one fits: KNOWLEDGE > DONE > UNRELATED > RELATED.

    Reply with EXACTLY one word: RELATED, DONE, UNRELATED, or KNOWLEDGE. No punctuation, no explanation.
    """
  end

  defp user_prompt(user_msg, spec, nil) do
    """
    Active task: #{spec}

    User message: #{user_msg}
    """
  end

  defp user_prompt(user_msg, spec, prev_assistant_msg) when is_binary(prev_assistant_msg) do
    case String.trim(prev_assistant_msg) do
      "" ->
        user_prompt(user_msg, spec, nil)

      trimmed ->
        # Truncate to keep the classify prompt small. The conversational
        # signal we need ("did the assistant just ask a question?") sits
        # in the last few hundred chars at most.
        snippet = String.slice(trimmed, 0, 800)

        """
        Active task: #{spec}

        Assistant's last reply (for context — the user's message may be answering this): #{snippet}

        User message: #{user_msg}
        """
    end
  end

  defp parse_verdict(text) do
    norm =
      text
      |> String.trim()
      |> String.upcase()
      |> String.split(~r/\W+/, trim: true)
      |> List.first()

    case norm do
      "RELATED"   -> :related
      "DONE"      -> :done
      "UNRELATED" -> :unrelated
      "KNOWLEDGE" -> :knowledge
      _ ->
        Logger.warning("[Oracle] unparseable verdict: #{inspect(String.slice(text, 0, 80))}")
        :error
    end
  end

  # ── localize ──────────────────────────────────────────────────────────

  @doc """
  Express `message` in the user's language, inferred from
  `user_input`. Returns one short sentence in plain text. On any
  error / empty reply, falls back to `message` verbatim — a flaky
  Oracle never strands the user with no ack.

  `user_input` is the language signal. Strong for inline text (the
  text itself); weak for paths/URLs (Oracle defaults to English,
  which is fine for path-shaped commands).
  """
  @spec localize(String.t(), String.t()) :: String.t()
  def localize(message, user_input)
      when is_binary(message) and is_binary(user_input) do
    msgs = [
      %{role: "system", content: localize_system_prompt()},
      %{role: "user",   content: "User input: #{user_input}\nMessage to express: #{message}"}
    ]

    trace = %{origin: "system", path: "Agent.Oracle.localize", role: "OracleLocalize", phase: "localize"}

    case LLM.call(AgentSettings.oracle_model(), msgs, options: %{temperature: 0}, trace: trace) do
      {:ok, text} when is_binary(text) ->
        case String.trim(text) do
          ""    -> message
          clean -> clean
        end

      _ ->
        message
    end
  rescue
    e ->
      Logger.warning("[Oracle] localize raised: #{Exception.message(e)}")
      message
  end

  def localize(message, _), do: message

  defp localize_system_prompt do
    """
    You translate a short runtime message into the user's language. Detect the language from the user's input.

    Hard rules:
      - If the user's input is in English (or the language is unclear), return the message VERBATIM. Do not rephrase, paraphrase, shorten, or "improve" it. Pass it through unchanged.
      - Otherwise, translate into the user's input language while preserving meaning EXACTLY.
      - Preserve the speaker. If the message has the assistant as subject (e.g. "I will confirm…", "I indexed your input"), the translation must keep the assistant as subject — NEVER swap to a request the user has to act on (e.g. "let me know…").
      - Do not translate proper nouns, paths, URLs, file names, or code. Preserve any backticks, single-quoted strings, and angle-bracket placeholders already in the message.

    Output ONE short sentence in plain text. No quotes around the reply, no markdown, no preamble, no explanation.
    """
  end
end
