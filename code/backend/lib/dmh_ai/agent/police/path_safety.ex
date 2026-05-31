# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police.PathSafety do
  @moduledoc """
  Path-safety + LAN-destination gate for a batch of tool calls.

  Read tools (`read_file`, `list_dir`, `extract_content`) must resolve
  to a path the session is allowed to read. Write tools (`write_file`)
  must land inside the session workspace. Shell tools (`run_script`)
  are inspected for absolute paths outside the session root, deletion
  scope, and redirect / tee / mkdir / touch / truncate targets that
  escape the workspace.

  Skipped entirely when `ctx` doesn't carry a `:session_root`
  (non-loop callers).

  `decode_or_empty/1` is exposed because other Police sub-modules
  (e.g. chain-state walkers that decode JSON-encoded
  `function.arguments`) need the same forgiving JSON decode.
  """

  require Logger

  @read_path_tools ["read_file", "list_dir", "extract_content"]
  @write_path_tools ["write_file"]
  @shell_tools ["run_script"]

  @abs_path_regex ~r{(?:^|\s|[=<>|;`'"(])(/[^\s"'`;&|<>()\$\\]+)}
  @redirect_regex ~r{>>?\s+(/[^\s"'`;&|<>()\$\\]+)}
  @write_cmd_regex ~r{\b(?:tee|touch|mkdir|truncate)\s+(?:-\S+\s+)*(/[^\s"'`;&|<>()\$\\]+)}

  @doc """
  Check a batch of tool calls against path-safety rules + the LAN-
  destination gate. Skipped entirely when `ctx` doesn't carry a
  `:session_root` (non-loop callers).
  """
  @spec check_path_safety(list(), list(), map()) :: :ok | {:rejected, String.t()}
  def check_path_safety(calls, _messages, ctx \\ %{}) do
    cond do
      reason = path_violation(calls, ctx) ->
        Logger.warning("[Police] path_violation: #{reason}")
        DmhAi.SysLog.log("[POLICE] REJECTED path_violation: #{reason}")
        {:rejected, "path_violation: #{reason}"}

      hit = DmhAi.Permissions.LanBlock.check(calls, ctx) ->
        {tool, host, detail} = hit
        full = "#{tool}: #{detail}"
        Logger.warning("[Police] lan_blocked: #{full}")
        DmhAi.SysLog.log("[POLICE] REJECTED lan_blocked: tool=#{tool} host=#{host}")
        {:rejected, "lan_blocked: #{full}"}

      true ->
        :ok
    end
  end

  @doc "Rejection message shown back to the model when a tool call is refused."
  def rejection_msg("path_violation: " <> detail) do
    "REJECTED (path_violation): #{detail}. Use a path under the session's workspace/ or data/ directory and try again."
  end
  def rejection_msg("lan_blocked: " <> detail) do
    "REJECTED (lan_blocked): #{detail}. Local-network destinations (RFC1918, loopback, link-local) are not reachable from the assistant. Use a public URL, or ask the user to share the data directly."
  end
  def rejection_msg(reason) do
    "REJECTED (#{reason}): Fix this specific violation before continuing. Do not repeat the same mistake."
  end

  @doc """
  Forgiving JSON decode for `function.arguments` strings: returns the
  decoded map on success, `%{}` on any failure. Used by both path
  safety (walks tool calls in batches) and chain-state checks that
  scan prior messages whose argument shapes may be string-encoded.
  """
  @spec decode_or_empty(binary()) :: map()
  def decode_or_empty(binary) do
    case Jason.decode(binary) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
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

  defp check_path_arg_read(args, ctx, _session_root) do
    case Map.get(args, "path") do
      p when is_binary(p) ->
        case DmhAi.Util.Path.resolve(p, ctx) do
          {:ok, _abs} -> nil
          {:error, reason} -> reason
        end
      _ -> nil
    end
  end

  defp check_resolved_path(args, ctx, boundary, label) do
    case Map.get(args, "path") do
      p when is_binary(p) ->
        case DmhAi.Util.Path.resolve(p, ctx) do
          {:ok, abs} ->
            if DmhAi.Util.Path.within?(abs, boundary) do
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
      not DmhAi.Util.Path.within?(expanded, workspace_dir)
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
          not DmhAi.Util.Path.within?(expanded, session_root)
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

    DmhAi.Util.Path.within?(expanded, workspace)
  end
end
