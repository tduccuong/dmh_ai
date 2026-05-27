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

  # ── localize ──────────────────────────────────────────────────────────

  @doc """
  Express `message` in the user's language, inferred from
  `user_input`. Returns one short sentence in plain text. On any
  error / empty reply, falls back to `message` verbatim — a flaky
  Swift never strands the user with no ack.

  `user_input` is the language signal. Strong for inline text (the
  text itself); weak for paths/URLs (Swift defaults to English,
  which is fine for path-shaped commands).

  `meta` (optional) carries `session_id` + `user_id` so the LLM call
  is metered against the right `(session, user)` token-stats row.
  Missing keys → the credit lands on the per-user sentinel row
  (still counted in `get_global_stats/1`).
  """
  @spec localize(String.t(), String.t(), map()) :: String.t()
  def localize(message, user_input, meta \\ %{})

  def localize(message, user_input, meta)
      when is_binary(message) and is_binary(user_input) and is_map(meta) do
    msgs = [
      %{role: "system", content: localize_system_prompt()},
      %{role: "user",   content: "<user_input>#{user_input}</user_input>\n<message_to_express>#{message}</message_to_express>"}
    ]

    trace = %{
      origin: "system",
      path: "Agent.Swift.localize",
      role: "SwiftLocalize",
      phase: "localize",
      session_id: Map.get(meta, :session_id),
      user_id:    Map.get(meta, :user_id),
      tier:       :swift
    }

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

  def localize(message, _, _), do: message

  defp localize_system_prompt do
    """
    You translate a short runtime message into the user's language. Detect the language from the user's input. Inputs arrive in XML tags — `<user_input>` (the language signal) and `<message_to_express>` (the message to translate).

    Hard rules:
      - If the user's input is in English (or the language is unclear), return the message VERBATIM. Do not rephrase, paraphrase, shorten, or "improve" it. Pass it through unchanged.
      - Otherwise, translate into the user's input language while preserving meaning EXACTLY.
      - Preserve the speaker. If the message has the assistant as subject (e.g. "I will confirm…", "I indexed your input"), the translation must keep the assistant as subject — NEVER swap to a request the user has to act on (e.g. "let me know…").
      - Do not translate proper nouns, paths, URLs, file names, or code. Preserve any backticks, single-quoted strings, and angle-bracket placeholders already in the message.

    Output ONE short sentence in plain text. No quotes around the reply, no markdown, no preamble, no explanation.
    """
  end
end
