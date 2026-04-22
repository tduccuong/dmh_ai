# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Police do
  @moduledoc """
  Path-safety gate for tool calls. The #101 conversational architecture
  removed the signal-protocol rules (plan step count, repeated-call
  detection, signal batching, text mimicry) — the model has too much
  freedom now for rigid rules to work reliably, and modern models
  don't exhibit those failure modes at a rate that warrants an
  enforced protocol.

  What remains: file-system safety.

    - Reads via `read_file` / `list_dir` / `parse_document` /
      `extract_content` are permitted anywhere OUTSIDE `/data/` (system
      paths like `/usr/share`) or within the caller's own `session_root`
      (its workspace + data dir).
    - Writes via `write_file` are confined to `workspace_dir`.
    - Shell commands (`run_script`, `spawn_task`) are scanned for
      deletions and absolute paths; deletions must target inside
      `workspace_dir`; absolute paths under `/data/` must be within
      `session_root`.

  Returns `:ok` to let the tool call proceed, or `{:rejected, reason}`
  to surface an error back to the model (the runtime turns this into a
  tool-result with an error message that the model can correct on its
  next turn).
  """

  require Logger

  @read_path_tools ["read_file", "list_dir", "parse_document", "extract_content"]
  @write_path_tools ["write_file"]
  @shell_tools ["run_script", "spawn_task"]

  @abs_path_regex ~r{(?:^|\s|[=<>|;`'"(])(/[^\s"'`;&|<>()\$\\]+)}
  @redirect_regex ~r{>>?\s+(/[^\s"'`;&|<>()\$\\]+)}
  @write_cmd_regex ~r{\b(?:tee|touch|mkdir|truncate)\s+(?:-\S+\s+)*(/[^\s"'`;&|<>()\$\\]+)}

  @doc """
  Check a batch of tool calls against path-safety rules. Skipped entirely
  when `ctx` doesn't carry a `:session_root` (non-loop callers).
  """
  @spec check_tool_calls(list(), list(), map()) :: :ok | {:rejected, String.t()}
  def check_tool_calls(calls, _messages, ctx \\ %{}) do
    case path_violation(calls, ctx) do
      nil ->
        :ok

      reason ->
        Logger.warning("[Police] path_violation: #{reason}")
        Dmhai.SysLog.log("[POLICE] REJECTED path_violation: #{reason}")
        {:rejected, "path_violation: #{reason}"}
    end
  end

  @doc "Rejection message shown back to the model when a tool call is refused."
  def rejection_msg("path_violation: " <> detail) do
    "REJECTED (path_violation): #{detail}. Use a path under the session's workspace/ or data/ directory and try again."
  end
  def rejection_msg(reason) do
    "REJECTED (#{reason}): Fix this specific violation before continuing. Do not repeat the same mistake."
  end

  # ── path safety internals ──────────────────────────────────────────────

  defp path_violation(calls, ctx) do
    session_root  = Map.get(ctx, :session_root)
    workspace_dir = Map.get(ctx, :workspace_dir)

    if is_nil(session_root) do
      nil
    else
      Enum.find_value(calls, nil, fn call ->
        name = get_in(call, ["function", "name"]) || ""
        args = get_in(call, ["function", "arguments"]) || %{}
        args = if is_binary(args), do: decode_or_empty(args), else: args

        cond do
          name in @read_path_tools  -> check_path_arg_read(args, ctx, session_root)
          name in @write_path_tools -> check_resolved_path(args, ctx, workspace_dir, "session workspace")
          name in @shell_tools      -> check_shell_command(args, workspace_dir, session_root)
          true                       -> nil
        end
      end)
    end
  end

  defp check_path_arg_read(args, ctx, session_root) do
    case Map.get(args, "path") do
      p when is_binary(p) ->
        case Dmhai.Util.Path.resolve(p, ctx) do
          {:ok, abs} ->
            cond do
              not String.starts_with?(abs, "/data/") -> nil
              Dmhai.Util.Path.within?(abs, session_root) -> nil
              true -> "path '#{p}' escapes the session root (#{session_root})"
            end
          {:error, reason} -> reason
        end
      _ -> nil
    end
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

  defp check_shell_command(args, workspace_dir, session_root) do
    case Map.get(args, "script") || Map.get(args, "command") do
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

    if bad, do: "write operation targets '#{bad}' outside the session workspace (#{workspace_dir})"
  end

  defp check_deletion_scope(cmd, workspace_dir) do
    case extract_deletion_targets(cmd) do
      [] -> nil
      targets ->
        bad = Enum.find(targets, fn t -> not looks_inside_workspace?(t, workspace_dir) end)
        if bad, do: "destructive command targets '#{bad}' outside the session workspace (#{workspace_dir})"
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
        String.starts_with?(expanded, "/data/") and
          not Dmhai.Util.Path.within?(expanded, session_root)
      end)

    if bad, do: "bash command references path '#{bad}' outside the session root (#{session_root})"
  end

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

  defp looks_inside_workspace?(_target, nil), do: true
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
