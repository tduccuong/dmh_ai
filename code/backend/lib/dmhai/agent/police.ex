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
    2. Repeated identical tool calls — model calls the same tool with the same
       arguments as a previous iteration, indicating an infinite loop.
    3. Path safety — explicit-path tool calls must stay under the session root;
       bash/spawn_task deletion commands (`rm`/`rmdir`/`unlink`) must stay
       within the job's workspace directory.
    4. Plan step count — fewer than planMinSteps or more than planMaxSteps steps.
    5. signal batching — step_signal and job_signal must each be called alone; batching
       either with other tool calls is rejected so all work completes before signalling.
    6. job_done_missing_result — job_signal(JOB_DONE) must carry a non-empty result
       field containing the final report compiled by the worker for the user.
  """

  alias Dmhai.Agent.AgentSettings
  require Logger

  # Patterns that indicate the model is reproducing internal markers as plain text.
  @mimicry_patterns [
    ~r/\[used:\s*\w+/,
    ~r/\[result:\w/,
    ~r/\[called tools:/
  ]

  # Tools always allowed to repeat with same args (fire-and-forget scheduling).
  # step_signal STEP_BLOCKED is separately exempted in repeatable_call?/1 because
  # retrying a blocked step legitimately re-sends the same args.
  @repeatable_tools MapSet.new(["spawn_task"])

  # Path tools that only READ — allowed anywhere within session_root.
  @read_path_tools ["read_file", "list_dir", "describe_image", "describe_video", "parse_document", "extract_content"]
  # Path tools that WRITE — restricted to workspace_dir.
  @write_path_tools ["write_file"]

  @doc "Rejection message to inject, including the specific violation reason."
  def rejection_msg("job_done_missing_result") do
    "REJECTED (job_done_missing_result): job_signal(JOB_DONE) requires a non-empty 'result' field. " <>
    "Compile the final report/answer for the user and include it as the result before signalling JOB_DONE."
  end
  def rejection_msg("step_signal_batched") do
    "REJECTED (step_signal_batched): step_signal must be called alone. " <>
    "Complete your tool work first, then call step_signal in a separate turn."
  end
  def rejection_msg("job_signal_batched") do
    "REJECTED (job_signal_batched): job_signal must be called alone. " <>
    "Do not combine it with other tool calls."
  end
  def rejection_msg(reason) do
    "REJECTED (#{reason}): Fix this specific violation before continuing. Do not repeat the same mistake."
  end

  @doc """
  Validate a worker's submitted plan for policy violations.
  Returns `:ok` or `{:rejected, reason_string}`.
  """
  @spec check_plan(String.t(), map()) :: :ok | {:rejected, String.t()}
  def check_plan(plan_text, ctx) when is_binary(plan_text) do
    step_count = Map.get(ctx, :plan_step_count)
    min_steps  = AgentSettings.plan_min_steps()
    max_steps  = AgentSettings.plan_max_steps()

    cond do
      is_integer(step_count) and step_count < min_steps ->
        msg = "plan must have at least #{min_steps} steps, got #{step_count}"
        Logger.warning("[Police] plan_step_count_too_low: #{step_count}")
        Dmhai.SysLog.log("[POLICE] REJECTED plan_step_count_too_low: #{step_count}")
        {:rejected, msg}

      is_integer(step_count) and step_count > max_steps ->
        msg = "plan must have at most #{max_steps} steps, got #{step_count}"
        Logger.warning("[Police] plan_step_count_too_high: #{step_count}")
        Dmhai.SysLog.log("[POLICE] REJECTED plan_step_count_too_high: #{step_count}")
        {:rejected, msg}

      dangerous_plan?(plan_text) ->
        Logger.warning("[Police] dangerous_plan detected")
        Dmhai.SysLog.log("[POLICE] REJECTED dangerous_plan")
        {:rejected, "plan contains dangerous operations (e.g. unrestricted deletion or system-wide destructive commands)"}

      true ->
        :ok
    end
  end

  def check_plan(_plan_text, _ctx), do: :ok

  @doc """
  Check a text response for bad behavior.
  Returns `:ok` or `{:rejected, reason_string}`.
  """
  @spec check_text(String.t(), map()) :: :ok | {:rejected, String.t()}
  def check_text(text, _ctx) do
    cond do
      text_mimicry?(text) ->
        Logger.warning("[Police] text_mimicry detected: #{String.slice(text, 0, 120)}")
        Dmhai.SysLog.log("[POLICE] REJECTED text_mimicry: #{String.slice(text, 0, 200)}")
        {:rejected, "text_mimicry"}

      true ->
        :ok
    end
  end

  @doc """
  Check tool calls for repeated identical calls against prior history,
  path-safety violations, and deletion scope.

  `messages` is the full history *before* this iteration's tool calls are appended.
  `ctx` carries `:session_root` / `:workspace_dir` for path checks; if absent,
  path checks are skipped.

  Returns `:ok` or `{:rejected, reason_string}`.
  """
  @spec check_tool_calls(list(), list(), map()) :: :ok | {:rejected, String.t()}
  def check_tool_calls(calls, messages, ctx \\ %{}) do
    cond do
      job_done_missing_result?(calls) ->
        Logger.warning("[Police] job_done_missing_result")
        Dmhai.SysLog.log("[POLICE] REJECTED job_done_missing_result")
        {:rejected, "job_done_missing_result"}

      step_signal_batched?(calls) ->
        Logger.warning("[Police] step_signal_batched with #{length(calls)} tools")
        Dmhai.SysLog.log("[POLICE] REJECTED step_signal_batched")
        {:rejected, "step_signal_batched"}

      job_signal_batched?(calls) ->
        Logger.warning("[Police] job_signal_batched with #{length(calls)} tools")
        Dmhai.SysLog.log("[POLICE] REJECTED job_signal_batched")
        {:rejected, "job_signal_batched"}

      repeated_identical_calls?(calls, messages) ->
        names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
        Logger.warning("[Police] repeated_identical_tool_calls: #{names}")
        Dmhai.SysLog.log("[POLICE] REJECTED repeated_identical_tool_calls: #{names}")
        {:rejected, "repeated_identical_tool_calls"}

      (reason = path_violation(calls, ctx)) != nil ->
        Logger.warning("[Police] path_violation: #{reason}")
        Dmhai.SysLog.log("[POLICE] REJECTED path_violation: #{reason}")
        {:rejected, "path_violation: #{reason}"}

      true ->
        :ok
    end
  end

  # ── private ──────────────────────────────────────────────────────────────────

  # Patterns that indicate the plan describes operations that should be blocked.
  @dangerous_plan_patterns [
    ~r/\brm\s+-rf\s+\//,           # rm -rf /
    ~r/\brm\s+-rf\s+~/,            # rm -rf ~
    ~r/\bdd\b.*\bof=\/dev\//,      # dd to raw device
    ~r/:\(\)\{.*:\|:&\}/,          # fork bomb
    ~r/\/etc\/passwd/,             # writing to system files
    ~r/\/etc\/shadow/
  ]

  defp dangerous_plan?(text) do
    Enum.any?(@dangerous_plan_patterns, fn pat -> Regex.match?(pat, text) end)
  end

  defp text_mimicry?(text) do
    Enum.any?(@mimicry_patterns, fn pat -> Regex.match?(pat, text) end)
  end

  # job_signal(JOB_DONE) must carry a non-empty (non-whitespace) result.
  defp job_done_missing_result?(calls) do
    Enum.any?(calls, fn c ->
      if get_in(c, ["function", "name"]) == "job_signal" do
        args = get_in(c, ["function", "arguments"]) || %{}
        args = if is_binary(args), do: decode_or_empty(args), else: args
        (args["status"] || "") |> String.upcase() == "JOB_DONE" and
          (args["result"] || "") |> String.trim() == ""
      else
        false
      end
    end)
  end

  # step_signal must be the only tool call in its turn.
  defp step_signal_batched?(calls) when length(calls) > 1 do
    Enum.any?(calls, fn c -> get_in(c, ["function", "name"]) == "step_signal" end)
  end
  defp step_signal_batched?(_), do: false

  # job_signal must be the only tool call in its turn.
  defp job_signal_batched?(calls) when length(calls) > 1 do
    Enum.any?(calls, fn c -> get_in(c, ["function", "name"]) == "job_signal" end)
  end
  defp job_signal_batched?(_), do: false

  # For each current call, check whether it is allowed to repeat (by name or by
  # status). STEP_BLOCKED and PLAN_REVISE retries are exempt because they
  # legitimately resend the same args. STEP_DONE with same args is a loop bug.
  defp repeatable_call?(call) do
    name = get_in(call, ["function", "name"]) || ""
    cond do
      MapSet.member?(@repeatable_tools, name) ->
        true
      name == "step_signal" ->
        args = get_in(call, ["function", "arguments"]) || %{}
        args = if is_binary(args), do: decode_or_empty(args), else: args
        String.upcase(to_string(args["status"] || "")) in ["STEP_BLOCKED", "PLAN_REVISE"]
      true ->
        false
    end
  end

  # For each current call that is not repeatable, check whether the same
  # (name, args) signature appeared in any prior assistant turn's tool_calls.
  defp repeated_identical_calls?(calls, messages) do
    prev_signatures = build_prev_signatures(messages)

    Enum.any?(calls, fn call ->
      if repeatable_call?(call) do
        false
      else
        name = get_in(call, ["function", "name"]) || ""
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

  # ── path safety ─────────────────────────────────────────────────────────


  # Tools whose `command` arg is a shell script — we scan for rm/rmdir/unlink.
  @shell_tools ["bash", "spawn_task"]

  # Returns a reason string if any call in the batch violates path rules,
  # else nil. Skips all checks if ctx doesn't carry a session_root
  # (non-worker callers / legacy paths).
  defp path_violation(calls, ctx) do
    session_root  = Map.get(ctx, :session_root)
    workspace_dir = Map.get(ctx, :workspace_dir)

    cond do
      is_nil(session_root) -> nil
      true ->
        Enum.find_value(calls, nil, fn call ->
          name = get_in(call, ["function", "name"]) || ""
          args = get_in(call, ["function", "arguments"]) || %{}
          args = if is_binary(args), do: decode_or_empty(args), else: args

          cond do
            name in @read_path_tools  -> check_path_arg_read(args, ctx, session_root)
            name in @write_path_tools -> check_path_arg_write(args, ctx, workspace_dir)
            name in @shell_tools      -> check_shell_command(name, args, workspace_dir, session_root)
            true -> nil
          end
        end)
    end
  end

  # Read tools: path must be within session_root.
  defp check_path_arg_read(args, ctx, session_root) do
    check_resolved_path(args, ctx, session_root, "session root")
  end

  # Write tools: path must be within workspace_dir (stricter).
  defp check_path_arg_write(args, ctx, workspace_dir) do
    check_resolved_path(args, ctx, workspace_dir, "job workspace")
  end

  defp check_resolved_path(args, ctx, boundary, label) do
    case Map.get(args, "path") do
      p when is_binary(p) ->
        case Dmhai.Util.Path.resolve(p, ctx) do
          {:ok, abs} ->
            if Dmhai.Util.Path.within?(abs, boundary) do
              nil
            else
              "path '#{p}' escapes the #{label} (#{boundary})"
            end
          {:error, reason} -> reason
        end
      _ -> nil
    end
  end

  # Regex to extract literal absolute path tokens from a shell command.
  # Matches /... tokens that appear after whitespace, shell operators, or quotes.
  @abs_path_regex ~r{(?:^|\s|[=<>|;`'"(])(/[^\s"'`;&|<>()\$\\]+)}

  # Shell output redirect targets: `> path` and `>> path`.
  @redirect_regex ~r{>>?\s+(/[^\s"'`;&|<>()\$\\]+)}

  # Write-like commands whose first non-flag argument is a write target.
  @write_cmd_regex ~r{\b(?:tee|touch|mkdir|truncate)\s+(?:-\S+\s+)*(/[^\s"'`;&|<>()\$\\]+)}

  defp check_shell_command(_name, args, workspace_dir, session_root) do
    case Map.get(args, "command") do
      cmd when is_binary(cmd) ->
        check_absolute_paths(cmd, session_root)
        || check_deletion_scope(cmd, workspace_dir)
        || check_write_targets(cmd, workspace_dir)
      _ ->
        nil
    end
  end

  defp check_write_targets(cmd, workspace_dir) do
    targets =
      (Regex.scan(@redirect_regex, cmd, capture: :all_but_first) ++
       Regex.scan(@write_cmd_regex, cmd, capture: :all_but_first))
      |> List.flatten()

    bad = Enum.find(targets, fn p ->
      expanded = Path.expand(p)
      not Dmhai.Util.Path.within?(expanded, workspace_dir)
    end)

    if bad, do: "write operation targets '#{bad}' outside the job workspace (#{workspace_dir})"
  end

  defp check_deletion_scope(cmd, workspace_dir) do
    case extract_deletion_targets(cmd) do
      [] -> nil
      targets ->
        bad = Enum.find(targets, fn t -> not looks_inside_workspace?(t, workspace_dir) end)
        if bad, do: "destructive command targets '#{bad}' outside the job workspace (#{workspace_dir})"
    end
  end

  defp check_absolute_paths(_cmd, nil), do: nil
  defp check_absolute_paths(cmd, session_root) do
    bad =
      @abs_path_regex
      |> Regex.scan(cmd, capture: :all_but_first)
      |> List.flatten()
      |> Enum.find(fn p ->
        expanded = Path.expand(p)
        not Dmhai.Util.Path.within?(expanded, session_root)
      end)

    if bad, do: "bash command references path '#{bad}' outside the session root (#{session_root})"
  end

  # Heuristic: find tokens after `rm`, `rmdir`, `unlink`, or `del` that look
  # like paths (ignoring shell flags). Not airtight — a determined model could
  # hide deletions behind eval/variable expansion. Catches the common cases.
  defp extract_deletion_targets(cmd) do
    pattern = ~r/\b(?:rm|rmdir|unlink|del)\b([^&|;<>\n]*)/
    Regex.scan(pattern, cmd, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn tail ->
      tail
      |> String.split(~r/\s+/)
      |> Enum.reject(fn t -> t == "" or String.starts_with?(t, "-") end)
    end)
  end

  # Accept bare relative paths (model likely means workspace-relative) and
  # absolute paths under the workspace. Reject absolute paths outside.
  defp looks_inside_workspace?(_target, nil), do: true  # no workspace context → don't block
  defp looks_inside_workspace?(target, workspace) do
    expanded =
      if String.starts_with?(target, "/") do
        Path.expand(target)
      else
        Path.expand(Path.join(workspace, target))
      end

    Dmhai.Util.Path.within?(expanded, workspace)
  end

  defp decode_or_empty(binary) do
    case Jason.decode(binary) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end
end
