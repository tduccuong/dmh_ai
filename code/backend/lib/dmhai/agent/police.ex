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
  """

  require Logger

  # Patterns that indicate the model is reproducing internal markers as plain text.
  @mimicry_patterns [
    ~r/\[used:\s*\w+/,
    ~r/\[result:\w/,
    ~r/\[called tools:/
  ]

  # Tools allowed to repeat with the same args (scheduling/utility tools are intentional).
  @repeatable_tools MapSet.new(["spawn_task"])

  # Path tools that only READ — allowed anywhere within session_root.
  @read_path_tools ["read_file", "list_dir", "describe_image", "describe_video", "parse_document"]
  # Path tools that WRITE — restricted to workspace_dir.
  @write_path_tools ["write_file"]

  @doc "Rejection message to inject, including the specific violation reason."
  def rejection_msg(reason) do
    "REJECTED (#{reason}): Fix this specific violation before continuing. Do not repeat the same mistake."
  end

  @doc """
  Validate a worker's submitted plan for policy violations.
  Returns `:ok` or `{:rejected, reason_string}`.
  """
  @spec check_plan(String.t(), map()) :: :ok | {:rejected, String.t()}
  def check_plan(plan_text, _ctx) when is_binary(plan_text) do

    if dangerous_plan?(plan_text) do
      Logger.warning("[Police] dangerous_plan detected")
      Dmhai.SysLog.log("[POLICE] REJECTED dangerous_plan")
      {:rejected, "plan contains dangerous operations (e.g. unrestricted deletion or system-wide destructive commands)"}
    else
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
