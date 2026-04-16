# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Police do
  @moduledoc """
  Detects bad worker model behavior and returns a rejection nudge
  to be injected into the conversation before the next LLM call.

  Bad behaviors detected:
    1. Text mimicry — model writes tool calls as plain text (e.g. `[used: bash(...)]`)
       instead of using the tool-calling mechanism.
    2. No tool call in periodic mode — model returned plain text when it should
       always be scheduling the next cycle via tools.
    3. Repeated identical tool calls — model calls the same tool with the same
       arguments as a previous iteration, indicating an infinite loop.
  """

  require Logger

  @rejection_msg "REJECTED: You VIOLATED the rules. Read the rules again and follow STRICTLY."

  # Patterns that indicate the model is reproducing internal markers as plain text.
  @mimicry_patterns [
    ~r/\[used:\s*\w+/,
    ~r/\[result:\w/,
    ~r/\[called tools:/
  ]

  # Tools allowed to repeat with the same args (periodic scheduling is intentional).
  @repeatable_tools MapSet.new(["spawn_task", "declare_periodic", "midjob_notify", "datetime"])

  @doc "Rejection message to inject."
  def rejection_msg, do: @rejection_msg

  @doc """
  Check a text response for bad behavior.
  Returns `:ok` or `{:rejected, reason_string}`.
  """
  @spec check_text(String.t(), map()) :: :ok | {:rejected, String.t()}
  def check_text(text, ctx) do
    cond do
      text_mimicry?(text) ->
        Logger.warning("[Police] text_mimicry detected: #{String.slice(text, 0, 120)}")
        Dmhai.SysLog.log("[POLICE] REJECTED text_mimicry: #{String.slice(text, 0, 200)}")
        {:rejected, "text_mimicry"}

      periodic_no_tool?(text, ctx) ->
        Logger.warning("[Police] no_tool_in_periodic: model returned text in periodic mode")
        Dmhai.SysLog.log("[POLICE] REJECTED no_tool_in_periodic: #{String.slice(text, 0, 200)}")
        {:rejected, "no_tool_in_periodic"}

      true ->
        :ok
    end
  end

  @doc """
  Check tool calls for repeated identical calls against prior history.
  `messages` is the full history *before* this iteration's tool calls are appended.
  Returns `:ok` or `{:rejected, reason_string}`.
  """
  @spec check_tool_calls(list(), list()) :: :ok | {:rejected, String.t()}
  def check_tool_calls(calls, messages) do
    if repeated_identical_calls?(calls, messages) do
      names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
      Logger.warning("[Police] repeated_identical_tool_calls: #{names}")
      Dmhai.SysLog.log("[POLICE] REJECTED repeated_identical_tool_calls: #{names}")
      {:rejected, "repeated_identical_tool_calls"}
    else
      :ok
    end
  end

  # ── private ──────────────────────────────────────────────────────────────────

  defp text_mimicry?(text) do
    Enum.any?(@mimicry_patterns, fn pat -> Regex.match?(pat, text) end)
  end

  # In periodic mode the model should ALWAYS call tools (spawn_task / midjob_notify).
  # A short text response (< 300 chars) strongly indicates the model drifted.
  # Long text (>= 300 chars) might be a legitimate mid-cycle summary — allow it.
  defp periodic_no_tool?(text, ctx) do
    Map.get(ctx, :periodic, false) and String.length(text) < 300
  end

  # For each current call that is NOT in @repeatable_tools, check whether the
  # same (name, args) signature appeared in any prior assistant turn's tool_calls.
  defp repeated_identical_calls?(calls, messages) do
    prev_signatures = build_prev_signatures(messages)

    Enum.any?(calls, fn call ->
      name = get_in(call, ["function", "name"]) || ""
      if MapSet.member?(@repeatable_tools, name) do
        false
      else
        args = get_in(call, ["function", "arguments"]) || %{}
        sig  = {name, normalize_args(args)}
        MapSet.member?(prev_signatures, sig)
      end
    end)
  end

  defp build_prev_signatures(messages) do
    messages
    |> Enum.filter(fn m -> (m[:role] || m["role"]) == "assistant" end)
    |> Enum.flat_map(fn m -> m[:tool_calls] || m["tool_calls"] || [] end)
    |> MapSet.new(fn c ->
      name = get_in(c, ["function", "name"]) || ""
      args = get_in(c, ["function", "arguments"]) || %{}
      {name, normalize_args(args)}
    end)
  end

  defp normalize_args(args) when is_map(args) do
    args
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new()
    |> Jason.encode!()
  end

  defp normalize_args(args) when is_binary(args), do: args
  defp normalize_args(_), do: ""
end
