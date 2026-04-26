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

  Model role: `oracleModel` (configurable via AgentSettings; default
  ministral-3:14b-cloud — small, fast, cheap).
  """

  require Logger
  alias Dmhai.Agent.{AgentSettings, LLM}

  @doc """
  Classify a user message against an anchor task spec. Returns one of
  `:related | :unrelated | :knowledge | :error`.

  When `anchor_task_spec` is `nil` or empty, the RELATED/UNRELATED
  axis is meaningless and we report `:related` (pass-through);
  KNOWLEDGE is still meaningful but the caller (Police) only fires
  the gate when an anchor exists, so this is fine.
  """
  @spec classify(String.t(), String.t() | nil) ::
          :related | :unrelated | :knowledge | :error
  def classify(user_msg, anchor_task_spec)
      when is_binary(user_msg) and (is_binary(anchor_task_spec) or is_nil(anchor_task_spec)) do
    spec = (anchor_task_spec || "") |> String.trim()

    if spec == "" do
      :related
    else
      do_classify(user_msg, spec)
    end
  end

  def classify(_, _), do: :error

  # ── private ───────────────────────────────────────────────────────────

  defp do_classify(user_msg, spec) do
    model = AgentSettings.oracle_model()

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: user_prompt(user_msg, spec)}
    ]

    case LLM.call(model, messages, options: %{temperature: 0}) do
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
    You are a classifier. You read a user message and an active task spec, then output exactly one word.

    Output one of:
      RELATED    — the user message extends, clarifies, refines, or replies to the active task.
      UNRELATED  — the user message is off-topic from the active task and would need different tools or different research to address.
      KNOWLEDGE  — the user message is a greeting, chitchat, identity question, or factual question a competent assistant can answer from its own training without any tool call (no live data, no current events, no user-specific lookup). Pick this regardless of how it relates to the active task whenever it applies.

    Priority when more than one fits: KNOWLEDGE > UNRELATED > RELATED.

    Reply with EXACTLY one word: RELATED, UNRELATED, or KNOWLEDGE. No punctuation, no explanation.
    """
  end

  defp user_prompt(user_msg, spec) do
    """
    Active task: #{spec}

    User message: #{user_msg}
    """
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
      "UNRELATED" -> :unrelated
      "KNOWLEDGE" -> :knowledge
      _ ->
        Logger.warning("[Oracle] unparseable verdict: #{inspect(String.slice(text, 0, 80))}")
        :error
    end
  end
end
