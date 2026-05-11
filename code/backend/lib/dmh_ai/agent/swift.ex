# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Swift do
  @moduledoc """
  The "Swift" tier — short, single-shot LLM calls that return a
  classification or a one-line answer. Cheapest model in the
  agent_settings hierarchy (`swiftModel`); designed for fast
  decisions where latency dominates and the output is a few tokens.

  Today this module exposes:

    * `classify/2` (and `classify/3`) — Police's anchor-pivot gate.
      Compares the chain-start user message against the active
      anchor's `task_spec` and returns one of:

        * `:related`   — extends/refines/replies to the anchor; tools
          may run as usual.
        * `:unrelated` — off-topic from the anchor; the assistant must
          confirm with the user (pause / cancel / stop) before any
          tool work for the new ask.
        * `:knowledge` — greeting, chitchat, identity question, or
          factual question answerable from training (no live lookup);
          regardless of anchor, no tool call should run for it.

      Soft fail: any error (timeout, transport, parse) returns
      `:error`. Police treats `:error` as a pass-through so a flaky
      classifier never blocks legitimate work.

    * `localize/2` — translates a short English template message into
      the user's language using their recent text as the language
      signal. Used by `/memo` (success / error acks) and `/index`
      pipelines (accepted / final acks).

  Other Swift-tier callers (Web.Search query planner, Handlers.Data
  session naming) live in their own modules but read the same
  `swiftModel` setting.
  """

  require Logger
  alias DmhAi.Agent.{AgentSettings, LLM}

  @doc """
  Classify a user message against an anchor task spec. Returns one of
  `:related | :unrelated | :knowledge | :error`.

  Optionally takes the assistant's most recent reply as conversational
  context — when the assistant just asked a clarifying question, the
  user's terse follow-up reply ("yes", a stage name, an account, …) is
  RELATED, not DONE / UNRELATED. Without that context Swift is blind
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
    model = AgentSettings.swift_model()

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: user_prompt(user_msg, spec, prev_assistant_msg)}
    ]

    trace = %{origin: "system", path: "Agent.Swift.classify", role: "SwiftPivot", phase: "classify"}

    case LLM.call(model, messages, options: %{temperature: 0}, trace: trace) do
      {:ok, text} when is_binary(text) ->
        parse_verdict(text)

      {:ok, {:tool_calls, _}} ->
        # Classifier model isn't supposed to emit tool_calls — its
        # tools list was empty. Treat this as a parse failure.
        :error

      {:error, reason} ->
        Logger.warning("[Swift] classify error: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.error("[Swift] classify raised: #{Exception.message(e)}")
      :error
  end

  defp system_prompt do
    """
    You are a classifier. You read an active task spec, optionally the assistant's last reply, and the user's current message. Output exactly one word.

    Output one of:
      RELATED    — the user message extends, clarifies, refines, or replies to the active task. If the assistant's last reply was a clarifying question (e.g. "which option?", "which stage?", "do you want X or Y?"), the user's reply is ALWAYS RELATED — even when it's terse like a single name, status, number, "yes", or "the second one".
      DONE       — the user wants to STOP / CLOSE / CANCEL / PAUSE the active task with NO follow-up. Requires an EXPLICIT termination verb: "stop", "cancel", "abort", "drop", "pause", "close", "no need", "ko cần", "đóng nhiệm vụ", "thôi", "quitter", "annule". Naming a status, stage, option, or value the assistant offered in its last reply is NEVER DONE — it's RELATED. Phrases like "switch to X" or "use Y" are NOT termination — they're choosing an option, RELATED.
      UNRELATED  — the user message proposes a DIFFERENT task to do instead — off-topic from the active task AND describes new work that would need different tools or different research. Pick this only when the user is genuinely pivoting to a new objective, not just closing the current one or answering a question.
      KNOWLEDGE  — the user message is a greeting, chitchat, identity question, or factual question a competent assistant can answer from its own training without any tool call (no live data, no current events, no user-specific lookup). Pick this regardless of how it relates to the active task whenever it applies. NOT KNOWLEDGE: any request that names the user's own data — "my email", "my calendar", "my account", "my files", "tài khoản của tôi", "lịch của tôi" (or the same in other languages) — even when it sounds simple. Possessive pronouns referring to the user's accounts or data flip the message out of KNOWLEDGE; classify RELATED or UNRELATED based on continuity with the active task instead.

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

  @doc """
  Classify a chain-start user message against a list of inactive tasks
  (`done` / `paused` / `cancelled`) in the same session. Returns
  `{:match, task_num} | :none | :error`.

  Single batched LLM call regardless of how many tasks the list
  contains. The list is capped upstream via
  `AgentSettings.task_resume_candidate_cap/0`.

  Used by chain-prep when no active anchor exists. On `:match` the
  runtime prepends a guidance hint to the user message in the LLM
  call, nudging the model toward `pickup_task(N)` instead of
  `create_task`. On `:none` the model decides between `create_task`,
  plain text (chitchat / knowledge), or follow-up via the existing
  intent matrix.

  Inactive task entries: `%{task_num: integer, task_title: string,
  task_spec: string}`. Spec is sliced to 120 chars in the prompt to
  cap classifier input size.
  """
  @spec classify_against_inactive(String.t(), [map()]) ::
          {:match, integer()} | :none | :error
  def classify_against_inactive(_user_msg, []), do: :none

  def classify_against_inactive(user_msg, inactive_tasks)
      when is_binary(user_msg) and user_msg != "" and is_list(inactive_tasks) do
    do_classify_against_inactive(user_msg, inactive_tasks)
  end

  def classify_against_inactive(_, _), do: :error

  defp do_classify_against_inactive(user_msg, inactive_tasks) do
    model = AgentSettings.swift_model()

    messages = [
      %{role: "system", content: classify_inactive_system_prompt()},
      %{role: "user",
        content: classify_inactive_user_prompt(user_msg, inactive_tasks)}
    ]

    trace = %{origin: "system", path: "Agent.Swift.classify_against_inactive",
              role: "SwiftInactiveMatch", phase: "classify"}

    case LLM.call(model, messages, options: %{temperature: 0}, trace: trace) do
      {:ok, text} when is_binary(text) ->
        parse_inactive_verdict(text, inactive_tasks)

      {:ok, {:tool_calls, _}} ->
        :error

      {:error, reason} ->
        Logger.warning("[Swift] classify_against_inactive error: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.error("[Swift] classify_against_inactive raised: #{Exception.message(e)}")
      :error
  end

  defp classify_inactive_system_prompt do
    """
    You decide whether a user's chain-start message is a substantive follow-up to one of a session's inactive tasks. Output exactly one token.

    Reply with the task NUMBER (e.g. "3") if the user message is extending, fixing, retrying, or asking about the state of a specific listed task.

    Reply "none" when:
      - The user message is chitchat, an acknowledgment, or a greeting ("thanks", "ok", "got it", "hi").
      - The user message is a knowledge question with no link to any listed task.
      - The user message is a short reply that doesn't determine intent ("yes", "no").
      - The user message is a brand-new objective unrelated to any listed task.

    Reply with EXACTLY one token: a task number, or "none". No punctuation, no explanation.
    """
  end

  defp classify_inactive_user_prompt(user_msg, inactive_tasks) do
    bullets =
      inactive_tasks
      |> Enum.map(fn t ->
        num    = Map.get(t, :task_num) || Map.get(t, "task_num")
        title  = Map.get(t, :task_title) || Map.get(t, "task_title") || "(untitled)"
        spec   = Map.get(t, :task_spec)  || Map.get(t, "task_spec")  || ""
        snippet = spec |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)
        "- (#{num}) #{title} — #{snippet}"
      end)
      |> Enum.join("\n")

    """
    User message: #{user_msg}

    Inactive tasks:
    #{bullets}
    """
  end

  defp parse_inactive_verdict(text, inactive_tasks) do
    valid_nums = MapSet.new(Enum.map(inactive_tasks, &(Map.get(&1, :task_num) || Map.get(&1, "task_num"))))

    norm =
      text
      |> String.trim()
      |> String.split(~r/\W+/, trim: true)
      |> List.first()
      |> Kernel.||("")
      |> String.downcase()

    cond do
      norm == "none" ->
        :none

      String.match?(norm, ~r/^\d+$/) ->
        {n, _} = Integer.parse(norm)

        if MapSet.member?(valid_nums, n) do
          {:match, n}
        else
          Logger.warning("[Swift] classify_against_inactive returned unknown task_num=#{n}")
          :none
        end

      true ->
        Logger.warning("[Swift] classify_against_inactive unparseable: #{inspect(String.slice(text, 0, 80))}")
        :error
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
        Logger.warning("[Swift] unparseable verdict: #{inspect(String.slice(text, 0, 80))}")
        :error
    end
  end

  # ── localize ──────────────────────────────────────────────────────────

  @doc """
  Express `message` in the user's language, inferred from
  `user_input`. Returns one short sentence in plain text. On any
  error / empty reply, falls back to `message` verbatim — a flaky
  Swift never strands the user with no ack.

  `user_input` is the language signal. Strong for inline text (the
  text itself); weak for paths/URLs (Swift defaults to English,
  which is fine for path-shaped commands).
  """
  @spec localize(String.t(), String.t()) :: String.t()
  def localize(message, user_input)
      when is_binary(message) and is_binary(user_input) do
    msgs = [
      %{role: "system", content: localize_system_prompt()},
      %{role: "user",   content: "User input: #{user_input}\nMessage to express: #{message}"}
    ]

    trace = %{origin: "system", path: "Agent.Swift.localize", role: "SwiftLocalize", phase: "localize"}

    case LLM.call(AgentSettings.swift_model(), msgs, options: %{temperature: 0}, trace: trace) do
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
      Logger.warning("[Swift] localize raised: #{Exception.message(e)}")
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
