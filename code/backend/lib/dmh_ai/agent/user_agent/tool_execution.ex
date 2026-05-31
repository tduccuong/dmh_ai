# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.ToolExecution do
  @moduledoc """
  Per-turn tool dispatch + result formatting for the Assistant chain.

  `execute_tools/3` runs each tool call from the model's turn through
  Police gates, calls `Tools.Registry.execute`, tallies write/outcome
  budgets, augments auto-activated-profile manifests, and returns the
  list of `role: "tool"` messages to append, the tagged call list, and
  the raw exec results (preserved for `extract_form_from_results`).
  Pure function — takes ctx in, returns ctx out.
  """

  require Logger

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Agent.UserAgent.ProfileResolution

  @doc """
  Dispatch the turn's tool calls. Returns
  `{tool_msgs, tagged_calls, exec_results, final_ctx}`.
  """
  def execute_tools(calls, messages, ctx) do
    chain_start_idx = Map.get(ctx, :chain_start_idx, 0)
    in_chain_prior  = Enum.drop(messages, chain_start_idx)

    {triples, {_final_prior, final_ctx}} =
      Enum.flat_map_reduce(calls, {in_chain_prior, ctx}, fn call, {prior_acc, ctx} ->
        name         = get_in(call, ["function", "name"]) || ""
        args         = get_in(call, ["function", "arguments"]) || %{}
        tool_call_id = call["id"] || ""

        progress_ctx = %{session_id: ctx.session_id, user_id: ctx.user_id}

        # Dependency resolution: a tool call naming a tool from a
        # known-but-inactive profile auto-activates that profile and
        # proceeds — no reject, no wasted turn. When activation fires,
        # the profile's manifest is injected into the {:ok, result}
        # envelope below so the model sees the rest of that profile's
        # tools immediately, not only on the next turn. See
        # `arch_wiki/dmh_ai/architecture.md` §Tool profiles.
        {ctx, auto_activated_profile} = ProfileResolution.resolve_profile_dependency(name, ctx)

        {tool_msg, exec_result} =
          with :ok <- DmhAi.Agent.Police.check_tool_name_validity(name, ctx.user_id),
               :ok <- DmhAi.Agent.Police.check_tool_call_schema(name, args),
               :ok <- DmhAi.Agent.Police.check_no_duplicate_tool_call(name, args, prior_acc),
               :ok <- DmhAi.Agent.Police.check_workflow_build_continuity(name, prior_acc),
               :ok <- DmhAi.Agent.Police.check_no_consecutive_web_search(name, args, prior_acc),
               :ok <- DmhAi.Agent.Police.check_run_script_probe_budget(name, args, prior_acc),
               :ok <- DmhAi.Agent.Police.check_write_failure_budget(name, Map.get(ctx, :write_failures, 0), AgentSettings.write_failure_budget_per_chain()) do
            progress_label = DmhAi.Agent.ProgressLabel.format(name, args)
            {:ok, row} = DmhAi.Agent.SessionProgress.append(progress_ctx, "tool", progress_label,
                                                            status: "pending")

            args_log = args |> Jason.encode!() |> String.slice(0, 600)
            DmhAi.SysLog.log("[ASSISTANT] tool=#{name} args=#{args_log}")

            tool_ctx =
              ctx
              |> Map.put(:progress_row_id, row.id)
              |> Map.put(:tool_call_id, tool_call_id)
              |> Map.put(:step_seq, tool_call_id)

            exec_started_ms = System.system_time(:millisecond)
            exec_result = DmhAi.Tools.Registry.execute(name, args, tool_ctx)
            duration_ms = System.system_time(:millisecond) - exec_started_ms

            if DmhAi.Agent.AgentSettings.log_trace() do
              DmhAi.Agent.LogTrace.write_tool(
                %{origin: "assistant", path: "UserAgent.execute_tools", role: "ToolExec"},
                name, args, exec_result, duration_ms
              )
            end

            content =
              case exec_result do
                {:ok, result} ->
                  DmhAi.Agent.SessionProgress.mark_tool_done(row.id, duration_ms)
                  result
                  |> ProfileResolution.augment_with_profile_manifest(auto_activated_profile, ctx)
                  |> format_tool_result()

                {:error, reason} ->
                  DmhAi.Agent.SessionProgress.mark_tool_done(row.id, duration_ms)
                  "Error: " <> format_tool_result(reason)
              end

            content =
              case DmhAi.Agent.Police.consecutive_run_script_advisory(name, prior_acc) do
                nil       -> content
                advisory  -> advisory <> content
              end

            content =
              case exec_result do
                {:error, _} ->
                  case DmhAi.Agent.Police.check_repeated_tool_error(name, content, prior_acc) do
                    {:rejected, {issue_atom, nudge_reason}} ->
                      "[[ISSUE:#{issue_atom}:#{name}]]\n" <> nudge_reason <> "\n\n" <> content

                    :ok ->
                      content
                  end

                _ ->
                  content
              end

            {%{role: "tool", name: name, content: content, tool_call_id: tool_call_id}, exec_result}
          else
            {:rejected, reason} = rej when is_binary(reason) ->
              {%{role: "tool", name: name, content: reason, tool_call_id: tool_call_id}, rej}

            {:rejected, {issue_atom, reason}} = rej when is_atom(issue_atom) ->
              marker = "[[ISSUE:#{issue_atom}:#{name}]]\n"
              {%{role: "tool", name: name, content: marker <> reason, tool_call_id: tool_call_id}, rej}
          end

        rejected? = match?({:rejected, _}, exec_result)
        tagged_call = if rejected?, do: Map.put(call, "_rejected", true), else: call

        # Tally write-class outcomes into ctx counters. These are what
        # the write-failure-budget + phantom-outcome checks read — NOT
        # message text, because the rolling tool-result flush rewrites
        # old result bodies to a success-looking placeholder and would
        # erase the failure signal. Only tools that ACTUALLY RAN count
        # (a Police rejection never executed → neither attempt nor
        # failure).
        ctx =
          if not rejected? and DmhAi.Agent.Police.write_class?(name) do
            failed_inc = if match?({:error, _}, exec_result), do: 1, else: 0

            ctx =
              ctx
              |> Map.update(:write_attempts, 1, &(&1 + 1))
              |> Map.update(:write_failures, failed_inc, &(&1 + failed_inc))

            # Outcome tally is the subset the phantom-outcome guard
            # reads: setup/connection writes (`outcome_write: false`,
            # e.g. connect_mcp) are excluded so an incidental success
            # can't mask a chain whose real action never landed.
            if DmhAi.Agent.Police.outcome_write?(name) do
              ctx
              |> Map.update(:outcome_attempts, 1, &(&1 + 1))
              |> Map.update(:outcome_failures, failed_inc, &(&1 + failed_inc))
            else
              ctx
            end
          else
            ctx
          end

        pseudo = %{"role" => "assistant", "tool_calls" => [tagged_call]}

        {[{tool_msg, tagged_call, exec_result}], {prior_acc ++ [pseudo], ctx}}
      end)

    tool_msgs    = Enum.map(triples, fn {m, _, _} -> m end)
    tagged_calls = Enum.map(triples, fn {_, c, _} -> c end)
    exec_results = Enum.map(triples, fn {_, _, r} -> r end)

    {tool_msgs, tagged_calls, exec_results, final_ctx}
  end

  @doc """
  Normalise a tool's return value into the binary the LLM sees in the
  `tool` message body. Binaries pass through verbatim; maps/lists become
  pretty JSON; primitives stringify; atoms emit their name; tuples
  serialize as lists. Never uses `inspect/1` — that would leak Elixir
  syntax into the model's context.
  """
  def format_tool_result(result) when is_binary(result), do: result
  def format_tool_result(%{envelope: env}) when is_binary(env), do: env
  def format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(normalise_json(result), pretty: true)
  def format_tool_result(result) when is_number(result) or is_boolean(result),
    do: to_string(result)
  def format_tool_result(nil), do: ""
  def format_tool_result(atom) when is_atom(atom), do: Atom.to_string(atom)
  def format_tool_result(other), do: Jason.encode!(normalise_json(other))

  defp normalise_json(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {json_key(k), normalise_json(val)} end)
  end
  defp normalise_json(v) when is_list(v), do: Enum.map(v, &normalise_json/1)
  defp normalise_json(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&normalise_json/1)
  defp normalise_json(v) when is_atom(v) and not is_boolean(v) and v != nil,
    do: Atom.to_string(v)
  defp normalise_json(v), do: v

  defp json_key(k) when is_atom(k), do: Atom.to_string(k)
  defp json_key(k) when is_binary(k), do: k
  defp json_key(k), do: to_string(k)
end
