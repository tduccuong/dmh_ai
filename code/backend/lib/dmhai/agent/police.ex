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

  # Execution-class tools: must be preceded by an active create_task in
  # the session. Anything not in this list is unconditionally allowed —
  # including create_task / update_task / fetch_task themselves (how the
  # model complies), credential tools (read-only wrt task state), and
  # trivial utilities (datetime, calculator).
  @gated_tools [
    "run_script",
    "web_fetch",
    "web_search",
    "extract_content",
    "read_file",
    "write_file",
    "parse_document",
    "spawn_task"
  ]

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

  @doc """
  Per-tool-call gate enforced at execution time (inside `execute_tools`).
  Rejects an execution-class tool call when the session has no active
  (pending/ongoing) task row — i.e. when the model has forgotten the
  "every substantive action needs create_task first" rule from
  `system_prompt.ex`. The rejection comes back to the model as a
  tool-result error string, which the model reads in its next round and
  self-corrects by calling create_task.

  Tools outside `@gated_tools` (create_task/update_task/fetch_task,
  credential tools, datetime, calculator) bypass this gate.

  `ctx` must carry `:session_id` — non-session callers bypass.
  """
  @spec check_task_discipline(String.t(), map()) :: :ok | {:rejected, String.t()}
  def check_task_discipline(name, ctx) when is_binary(name) do
    cond do
      name not in @gated_tools ->
        :ok

      not Map.has_key?(ctx, :session_id) ->
        :ok

      has_active_task?(ctx[:session_id]) ->
        :ok

      true ->
        reason =
          "Error: you must call create_task first before using `#{name}`. " <>
          "Every substantive action in Assistant mode needs its own task row. " <>
          "Call create_task(task_title, task_spec, task_type: \"one_off\", language: ...) " <>
          "first — the new task row is created with status=ongoing automatically — " <>
          "then retry `#{name}`. When finished, call " <>
          "update_task(task_id, status: \"done\", task_result: \"<summary>\")."

        Logger.warning("[Police] REJECTED task_discipline: tool=#{name} session=#{inspect(ctx[:session_id])}")
        Dmhai.SysLog.log("[POLICE] REJECTED task_discipline: tool=#{name} session=#{inspect(ctx[:session_id])}")
        {:rejected, reason}
    end
  end

  defp has_active_task?(session_id) when is_binary(session_id) do
    session_id
    |> Dmhai.Agent.Tasks.active_for_session()
    |> Enum.any?(fn t -> t.task_status in ["pending", "ongoing"] end)
  end
  defp has_active_task?(_), do: true

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

  @doc """
  Per-tool-call gate: reject when the emitted `name` doesn't correspond to
  a registered tool. Guards against model output malformation where the
  model stuffs garbled or hallucinated content into `function.name`
  (we've seen ~1000-char blobs, including entire natural-language
  responses glued together with LRM separators, as the name field).

  The rejection message enumerates the valid tool names so the next-round
  corrective tool_result gives the model the concrete vocabulary to
  recover with. Same silent-to-user handling as task_discipline —
  the progress row is never written for an unknown-tool rejection.
  """
  @spec check_tool_known(String.t()) :: :ok | {:rejected, String.t()}
  def check_tool_known(name) when is_binary(name) do
    if Dmhai.Tools.Registry.known?(name) do
      :ok
    else
      name_preview = String.slice(name, 0, 120)

      reason =
        "Error: `#{name_preview}` is not a valid tool name. " <>
          "Pick one of: " <>
          Enum.join(Dmhai.Tools.Registry.names(), ", ") <>
          ". Each tool_call must have a plain tool name in the `function.name` " <>
          "field and the arguments as a JSON object in `function.arguments`. " <>
          "Retry with the correct structure."

      Logger.warning("[Police] REJECTED tool_unknown: name=#{inspect(String.slice(name, 0, 200))}")
      Dmhai.SysLog.log("[POLICE] REJECTED tool_unknown: name=#{inspect(String.slice(name, 0, 200))}")
      {:rejected, reason}
    end
  end
  def check_tool_known(_), do: {:rejected, "Error: tool_call `function.name` must be a string."}

  @doc """
  Guard on the TEXT round's final content. Catches the failure mode where
  a model (devstral-small-2:24b, in particular) emits what it MEANT to be
  a tool_call as the assistant message's content field — e.g. the entire
  content is just the string `"update_task"` or `"create_task(...)"` — so
  the turn ends without actually calling the tool and the task stays
  stuck in `ongoing`.

  Conservative detector: fires only when the trimmed text is EXACTLY a
  registered tool name, OR has the shape `tool_name(…)` where `tool_name`
  is registered. Never fires on legitimate short replies like "Done.",
  "Yes", or any multi-word text that happens to contain a tool name
  somewhere.

  On rejection the session loop injects a corrective user-role message
  and recurses one more round; the bad text is never persisted.
  """
  @spec check_assistant_text(String.t()) :: :ok | {:rejected, String.t()}
  def check_assistant_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    names = Dmhai.Tools.Registry.names()

    exact_match = trimmed in names

    call_shape_match =
      case Regex.run(~r/^([a-z_][a-z0-9_]*)\s*\(/iu, trimmed, capture: :all_but_first) do
        [prefix] -> prefix in names
        _ -> false
      end

    if exact_match or call_shape_match do
      reason =
        "Your response was the text `#{String.slice(trimmed, 0, 120)}` which " <>
          "looks like a tool invocation emitted as plain text. Tool actions " <>
          "must live in the `tool_calls` array of your response, not in " <>
          "message content. If you meant to call a tool, retry with the " <>
          "proper tool_call structure. Otherwise, write a real reply."

      Logger.warning("[Police] REJECTED assistant_text: #{inspect(String.slice(trimmed, 0, 200))}")
      Dmhai.SysLog.log("[POLICE] REJECTED assistant_text: #{inspect(String.slice(trimmed, 0, 200))}")
      {:rejected, reason}
    else
      :ok
    end
  end
  def check_assistant_text(_), do: :ok
end
