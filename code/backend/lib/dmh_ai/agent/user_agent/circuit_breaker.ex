# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.CircuitBreaker do
  @moduledoc """
  Per-chain nudge counters + Police-rejection ISSUE-marker handling.

  When a Police gate rejects a tool result, it prefixes the result body
  with `[[ISSUE:<atom>:<tool>]]\\n…`. `bump_nudge_counters/2` strips
  those markers, accumulates one counter per issue class on ctx, and
  remembers the most recent SUBSTANTIVE (non-Police) tool error so an
  eventual abort can tell the user WHY the chain stopped.

  When a counter exceeds its per-class limit,
  `maybe_abort_on_model_behavior_issue/2` posts a user-facing
  circuit-breaker message and signals the chain to end.
  """

  require Logger

  alias DmhAi.Agent.{StreamBuffer, ThinkingBuffer}
  alias DmhAi.Agent.UserAgent.SessionIO

  # Default cap on how many same-class Police rejections may accrue in a
  # single chain before the safety-abort kicks in.
  @model_behavior_nudge_limit 3

  # Per-class overrides. `:duplicate_tool_call_in_chain` aborts on the
  # FIRST occurrence — a literal repeat is a strong signal the model is
  # spinning on a failed assumption rather than pivoting strategy, so we
  # don't give it three chances. Other classes inherit the default.
  @per_issue_nudge_limit %{
    duplicate_tool_call_in_chain: 1,
    write_failure_budget:         1
  }

  # Cap on how much of the underlying error we splice into the
  # user-facing circuit-breaker message — the gist, not the whole
  # remediation paragraph.
  @abort_error_excerpt_chars 200

  @doc """
  Walk the just-executed tool results, strip ISSUE markers, increment
  ctx.nudges per class, and remember the most recent real tool error.
  Returns `{updated_ctx, cleaned_tool_msgs}`.
  """
  def bump_nudge_counters(ctx, tool_result_msgs) do
    existing  = Map.get(ctx, :nudges, %{})
    prior_err = Map.get(ctx, :last_substantive_error)
    marker_re = ~r/^\[\[ISSUE:([a-z_]+):([^\]]*)\]\]\n?/u

    role  = Map.get(ctx, :role, "assistant")
    model = Map.get(ctx, :model, "unknown")

    {clean_msgs, {nudges_after, last_err}} =
      Enum.map_reduce(tool_result_msgs, {existing, prior_err}, fn msg, {acc, last} ->
        raw = msg[:content] || msg["content"] || ""

        case Regex.run(marker_re, raw) do
          [full, atom_name, tool_name] ->
            key = String.to_atom(atom_name)
            new_acc = Map.update(acc, key, 1, &(&1 + 1))
            DmhAi.Agent.ModelBehaviorStats.record(role, model, atom_name, tool_name)
            cleaned = String.replace_prefix(raw, full, "")
            {Map.put(msg, :content, cleaned), {new_acc, last}}

          _ ->
            # A tool result with no ISSUE marker is a real tool/validator
            # outcome, not a Police meta-rejection. Remember the most
            # recent ERROR among them so an eventual circuit-break can
            # tell the user what actually blocked the chain. It rides on
            # ctx (not the message list) so the rolling tool-result flush
            # can't erase it before the abort message is built.
            {msg, {acc, latest_tool_error(raw, last)}}
        end
      end)

    ctx =
      ctx
      |> Map.put(:nudges, nudges_after)
      |> Map.put(:last_substantive_error, last_err)

    {ctx, clean_msgs}
  end

  @doc "Track latest substantive (non-Police) tool error binary."
  def latest_tool_error(content, last) when is_binary(content) do
    if String.starts_with?(content, "Error:"), do: String.trim(content), else: last
  end
  def latest_tool_error(_content, last), do: last

  @doc """
  Wrap a Police rejection reason as a user-role "runtime correction"
  message the model sees and continues from.
  """
  def wrap_runtime_correction(reason) do
    "[ Runtime correction - Apply the below and continue your current chain ]\n\n" <> reason
  end

  @doc """
  Increment ctx.nudges for a non-tool issue (assistant-text reject,
  fresh-attachment miss, phantom outcome) and record the stat.
  """
  def record_non_tool_issue(ctx, issue_atom) do
    role  = Map.get(ctx, :role, "assistant")
    model = Map.get(ctx, :model, "unknown")

    DmhAi.Agent.ModelBehaviorStats.record(role, model, Atom.to_string(issue_atom), "")

    nudges =
      ctx
      |> Map.get(:nudges, %{})
      |> Map.update(issue_atom, 1, &(&1 + 1))

    Map.put(ctx, :nudges, nudges)
  end

  @doc """
  Check whether any per-class nudge counter is at-or-over its limit.
  When it is, log the abort, post a user-facing circuit-breaker
  message, and return `:aborted`. Otherwise `:continue`.
  """
  def maybe_abort_on_model_behavior_issue(ctx, model) do
    nudges = Map.get(ctx, :nudges, %{})

    over =
      Enum.find(nudges, fn {k, count} ->
        limit = Map.get(@per_issue_nudge_limit, k, @model_behavior_nudge_limit)
        count >= limit
      end)

    case over do
      nil ->
        :continue

      {issue, count} ->
        role = Map.get(ctx, :role, "assistant")
        Logger.error(
          "[ModelBehaviorIssue] type=#{issue} model=#{model} session=#{ctx.session_id} count=#{count} — aborting turn"
        )
        DmhAi.SysLog.log(
          "[CRITICAL] ModelBehaviorIssue type=#{issue} model=#{model} session=#{ctx.session_id} count=#{count}"
        )
        DmhAi.Agent.ModelBehaviorStats.record(role, model, "escalated_#{issue}", "")

        user_msg = circuit_breaker_message(issue, error_gist(Map.get(ctx, :last_substantive_error)))
        StreamBuffer.clear(ctx.session_id, ctx.user_id)
        ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
        {:ok, _} = SessionIO.append_session_message(ctx.session_id, ctx.user_id,
                                                    %{role: "assistant", content: user_msg})
        :aborted
    end
  end

  # Error/repeat classes fold in the actual blocker (the last real
  # tool error, captured on ctx) so the user learns WHY the chain
  # stopped instead of a generic "rephrase". Budget/empty classes
  # have no underlying tool error worth surfacing.
  defp circuit_breaker_message(:duplicate_tool_call_in_chain, gist),
    do: with_blocker("I couldn't finish this — I kept repeating the same step instead of correcting it", gist)

  defp circuit_breaker_message(:repeated_tool_error, gist),
    do: with_blocker("I kept hitting the same error and couldn't make progress", gist)

  defp circuit_breaker_message(:tool_call_schema, gist),
    do: with_blocker("I kept calling one of my tools with the wrong arguments", gist)

  defp circuit_breaker_message(:run_script_probe_budget, _gist),
    do: "I ran out of tool-call budget. Please split this into smaller steps."

  defp circuit_breaker_message(:no_consecutive_web_search, _gist),
    do: "I ran out of search budget. Please narrow down what you're looking for."

  defp circuit_breaker_message(:empty_response, _gist),
    do: "I tried to reply and produced nothing several times in a row. Please retry."

  defp circuit_breaker_message(_other, _gist),
    do: "I hit an internal safety limit on this task. Please rephrase or try again."

  defp error_gist(nil), do: nil

  defp error_gist(err) when is_binary(err) do
    err
    |> String.replace_prefix("Error: ", "")
    |> String.split(~r/\.\s/, parts: 2)
    |> List.first()
    |> String.slice(0, @abort_error_excerpt_chars)
    |> String.trim()
  end

  defp with_blocker(lead, nil),
    do: lead <> ". Please rephrase the request or add a detail I can act on differently."

  defp with_blocker(lead, gist),
    do:
      lead <>
        ". The blocker was: " <>
        gist <> ". You can confirm those details or rephrase it, and I'll try a different approach."
end
