# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police.AssistantText do
  @moduledoc """
  Guard on the TEXT turn's final content. Catches three failure modes:

    * Empty response — model returned no text AND no tool calls.
    * Tool-as-plain-text — model emitted what it MEANT to be a
      tool_call as the assistant message's content field (the entire
      content is a registered tool name, or has the shape
      `tool_name(…)`).
    * Bookkeeping annotations — the model embeds pseudo-tool-call
      decorations like `[used: …]` / `[via: …]` / `[called: …]` /
      `[tool: …]` in its prose.

  Conservative detector: never fires on legitimate short replies like
  "Done.", "Yes", or multi-word text that happens to contain a tool
  name somewhere. On rejection the chain loop injects a corrective
  user-role message and recurses one more turn; the bad text is never
  persisted.
  """

  require Logger

  alias DmhAi.Tools.Registry

  @doc """
  Check the assistant's final text. Returns `:ok` or
  `{:rejected, {atom(), reason}}` with one of three rejection codes:
  `:empty_response`, `:tool_as_plain_text`, `:assistant_text_bookkeeping`.
  """
  @spec check_assistant_text(String.t()) :: :ok | {:rejected, {atom(), String.t()}}
  def check_assistant_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    names = Registry.names()

    exact_match = trimmed in names

    call_shape_match =
      case Regex.run(~r/^([a-z_][a-z0-9_]*)\s*\(/iu, trimmed, capture: :all_but_first) do
        [prefix] -> prefix in names
        _ -> false
      end

    # Detect pseudo-tool-call annotations the model embeds in its text.
    # Shape: `[used: <tool_name>(...)]`, `[via: ...]`, `[called: ...]`,
    # `[tool: ...]`. The regex only has to match the opening; the
    # bracket can be anywhere (prefix / middle / suffix). On rejection
    # the session loop injects a nudge and recurses — the model retries
    # with clean text and real tool_calls for any updates it intended
    # to make.
    bookkeeping_match =
      Regex.match?(~r/\[(used|via|called|tool)\s*:/u, trimmed)

    cond do
      trimmed == "" ->
        # Model returned no text AND no tool calls. Same reject-and-
        # nudge mechanic as other Police rejections — ask the model
        # itself to surface root cause + options instead of silently
        # ending the chain. The 3-strike circuit-breaker in
        # user_agent.ex caps runaway empty-loops.
        reason =
          "Your previous response was empty — no text and no tool calls. " <>
            "Reply now with: (1) the most likely reason on your side that you " <>
            "produced no output (conflicting context, ambiguous request, " <>
            "missing information, hit a token / budget limit, an internal " <>
            "constraint, etc.); and (2) two or three concrete options the " <>
            "user can choose from to move forward. Speak in the user's " <>
            "language. Do not return empty again."

        Logger.warning("[Police] REJECTED empty_response")
        DmhAi.SysLog.log("[POLICE] REJECTED empty_response")
        {:rejected, {:empty_response, reason}}

      exact_match or call_shape_match ->
        reason =
          "Your response was the text `#{String.slice(trimmed, 0, 120)}` which " <>
            "looks like a tool invocation emitted as plain text. Tool actions " <>
            "must live in the `tool_calls` array of your response, not in " <>
            "message content. If you meant to call a tool, retry with the " <>
            "proper tool_call structure. Otherwise, write a real reply."

        Logger.warning("[Police] REJECTED tool_as_plain_text: #{inspect(String.slice(trimmed, 0, 200))}")
        DmhAi.SysLog.log("[POLICE] REJECTED tool_as_plain_text: #{inspect(String.slice(trimmed, 0, 200))}")
        {:rejected, {:tool_as_plain_text, reason}}

      bookkeeping_match ->
        reason =
          "Your response contains a pseudo-tool-call annotation of the " <>
            "form `[used: ...]` / `[via: ...]` / `[called: ...]` / " <>
            "`[tool: ...]`. These are text decorations — the tool was " <>
            "NOT actually called, and the user would see this junk in " <>
            "their chat. The user-facing reply must be plain prose in " <>
            "the user's language, with NO `[...]` tool annotations and " <>
            "NO tool-name mentions."

        Logger.warning("[Police] REJECTED assistant_text_bookkeeping: #{inspect(String.slice(trimmed, 0, 200))}")
        DmhAi.SysLog.log("[POLICE] REJECTED assistant_text_bookkeeping: #{inspect(String.slice(trimmed, 0, 200))}")
        {:rejected, {:assistant_text_bookkeeping, reason}}

      true ->
        :ok
    end
  end
  def check_assistant_text(_), do: :ok
end
