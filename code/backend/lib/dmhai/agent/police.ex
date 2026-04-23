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

    - Reads via `read_file` / `list_dir` /
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

  @read_path_tools ["read_file", "list_dir", "extract_content"]
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
    "spawn_task"
  ]

  @abs_path_regex ~r{(?:^|\s|[=<>|;`'"(])(/[^\s"'`;&|<>()\$\\]+)}
  @redirect_regex ~r{>>?\s+(/[^\s"'`;&|<>()\$\\]+)}
  @write_cmd_regex ~r{\b(?:tee|touch|mkdir|truncate)\s+(?:-\S+\s+)*(/[^\s"'`;&|<>()\$\\]+)}

  @doc """
  Validate a tool call's arguments against the tool's own declared
  schema (`Tools.Registry.definition_for/1`). Generic — no per-tool
  pattern rules. Catches:

    * missing required arguments
    * wrong argument types (loose: string / integer / array / boolean)

  Returns `:ok` or `{:rejected, {:tool_call_schema, reason}}` where
  `reason` is a schema-driven nudge showing the correct call shape
  built from the tool's own property descriptions.
  """
  @spec check_tool_call_schema(String.t(), map()) :: :ok | {:rejected, {:tool_call_schema, String.t()}}
  def check_tool_call_schema(name, args) when is_binary(name) and is_map(args) do
    case Dmhai.Tools.Registry.definition_for(name) do
      nil ->
        :ok

      schema ->
        params    = schema[:parameters] || %{}
        props     = params[:properties] || %{}
        required  = params[:required] || []

        missing = Enum.reject(required, fn k -> present_and_non_empty?(args[to_string(k)]) end)

        type_errs =
          Enum.flat_map(props, fn {key, prop} ->
            expected = prop[:type]
            actual   = args[to_string(key)]

            cond do
              is_nil(actual) -> []
              type_ok?(expected, actual) -> []
              true -> [%{field: to_string(key), expected: expected, got: actual_type(actual)}]
            end
          end)

        if missing == [] and type_errs == [] do
          :ok
        else
          reason = build_schema_nudge(name, schema, missing, type_errs)
          Logger.warning("[Police] REJECTED tool_call_schema: tool=#{name} missing=#{inspect(missing)} type_errs=#{inspect(type_errs)}")
          Dmhai.SysLog.log("[POLICE] REJECTED tool_call_schema: tool=#{name} missing=#{inspect(missing)} type_errs=#{inspect(type_errs)}")
          {:rejected, {:tool_call_schema, reason}}
        end
    end
  end
  def check_tool_call_schema(_, _), do: :ok

  # ── private helpers for schema check ────────────────────────────────────

  defp present_and_non_empty?(nil), do: false
  defp present_and_non_empty?(""),  do: false
  defp present_and_non_empty?([]),  do: false
  defp present_and_non_empty?(_),   do: true

  defp type_ok?("string",  v), do: is_binary(v)
  defp type_ok?("integer", v), do: is_integer(v) or (is_binary(v) and match?({_, ""}, Integer.parse(v)))
  defp type_ok?("number",  v), do: is_number(v)
  defp type_ok?("boolean", v), do: is_boolean(v)
  defp type_ok?("array",   v), do: is_list(v)
  defp type_ok?("object",  v), do: is_map(v)
  defp type_ok?(_, _),         do: true

  defp actual_type(v) when is_binary(v),  do: "string"
  defp actual_type(v) when is_integer(v), do: "integer"
  defp actual_type(v) when is_number(v),  do: "number"
  defp actual_type(v) when is_boolean(v), do: "boolean"
  defp actual_type(v) when is_list(v),    do: "array"
  defp actual_type(v) when is_map(v),     do: "object"
  defp actual_type(_),                    do: "unknown"

  defp build_schema_nudge(name, schema, missing, type_errs) do
    props    = get_in(schema, [:parameters, :properties]) || %{}
    required = get_in(schema, [:parameters, :required])   || []

    complaint =
      cond do
        missing != [] and type_errs != [] ->
          "missing required field(s): #{Enum.join(missing, ", ")}; wrong type(s): " <>
            (Enum.map_join(type_errs, ", ", fn e ->
              "#{e.field} expected #{e.expected} got #{e.got}"
            end))

        missing != [] ->
          "missing required field(s): #{Enum.join(missing, ", ")}"

        true ->
          "wrong type(s): " <>
            Enum.map_join(type_errs, ", ", fn e ->
              "#{e.field} expected #{e.expected} got #{e.got}"
            end)
      end

    example = render_schema_example(name, props, required)

    "Malformed tool_call for `#{name}`: #{complaint}.\n\n" <>
      "Correct shape (placeholders show types; fill in real values):\n\n" <>
      example <>
      "\n\nRetry the call with every required field present and correctly typed."
  end

  defp render_schema_example(name, props, required) do
    lines =
      Enum.map_join(props, "\n", fn {key, prop} ->
        expected_type = prop[:type] || "string"
        desc          = prop[:description] || ""
        req?          = to_string(key) in Enum.map(required, &to_string/1)
        marker        = if req?, do: "(required)", else: "(optional)"
        placeholder   = type_placeholder(expected_type)
        "  \"#{key}\": #{placeholder},  // #{marker} #{desc}"
      end)

    "#{name}({\n#{lines}\n})"
  end

  defp type_placeholder("string"),  do: "\"<string>\""
  defp type_placeholder("integer"), do: "<integer>"
  defp type_placeholder("number"),  do: "<number>"
  defp type_placeholder("boolean"), do: "<true|false>"
  defp type_placeholder("array"),   do: "[\"<string>\", …]"
  defp type_placeholder("object"),  do: "{…}"
  defp type_placeholder(_),         do: "<value>"

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
  @spec check_task_discipline(String.t(), map()) :: :ok | {:rejected, {atom(), String.t()}}
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
        {:rejected, {:task_discipline, reason}}
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
  @spec check_tool_known(String.t()) :: :ok | {:rejected, {atom(), String.t()}}
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

      Logger.warning("[Police] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      Dmhai.SysLog.log("[POLICE] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      {:rejected, {:unknown_tool_name, reason}}
    end
  end
  def check_tool_known(_),
    do: {:rejected, {:unknown_tool_name, "Error: tool_call `function.name` must be a string."}}

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
  @spec check_assistant_text(String.t()) :: :ok | {:rejected, {atom(), String.t()}}
  def check_assistant_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    names = Dmhai.Tools.Registry.names()

    exact_match = trimmed in names

    call_shape_match =
      case Regex.run(~r/^([a-z_][a-z0-9_]*)\s*\(/iu, trimmed, capture: :all_but_first) do
        [prefix] -> prefix in names
        _ -> false
      end

    # Detect pseudo-tool-call annotations the model embeds in its text —
    # the misbehaviour we saw with gemini-flash that led to empty answers.
    # Shape: `[used: <tool_name>(...)]`, `[via: ...]`, `[called: ...]`,
    # `[tool: ...]`. The regex only has to match the opening; the
    # bracket can be anywhere (prefix / middle / suffix). On rejection
    # the session loop injects a nudge and recurses — the model retries
    # with a clean text AND (hopefully) real tool_calls for any
    # updates it intended to make.
    bookkeeping_match =
      Regex.match?(~r/\[(used|via|called|tool)\s*:/u, trimmed)

    cond do
      exact_match or call_shape_match ->
        reason =
          "Your response was the text `#{String.slice(trimmed, 0, 120)}` which " <>
            "looks like a tool invocation emitted as plain text. Tool actions " <>
            "must live in the `tool_calls` array of your response, not in " <>
            "message content. If you meant to call a tool, retry with the " <>
            "proper tool_call structure. Otherwise, write a real reply."

        Logger.warning("[Police] REJECTED tool_as_plain_text: #{inspect(String.slice(trimmed, 0, 200))}")
        Dmhai.SysLog.log("[POLICE] REJECTED tool_as_plain_text: #{inspect(String.slice(trimmed, 0, 200))}")
        {:rejected, {:tool_as_plain_text, reason}}

      bookkeeping_match ->
        reason =
          "Your response contains a pseudo-tool-call annotation of the " <>
            "form `[used: ...]` / `[via: ...]` / `[called: ...]` / " <>
            "`[tool: ...]`. These are text decorations — the tool was " <>
            "NOT actually called, and the user would see this junk in " <>
            "their chat. Retry with two clean outputs: " <>
            "(1) if you meant to update a task (status/title/result), " <>
            "emit a REAL `tool_call` to `update_task` with the right " <>
            "arguments — do NOT paraphrase it in text; " <>
            "(2) the user-facing reply must be plain prose in the " <>
            "user's language, with NO `[...]` tool annotations, NO " <>
            "task_id references, NO tool-name mentions."

        Logger.warning("[Police] REJECTED assistant_text_bookkeeping: #{inspect(String.slice(trimmed, 0, 200))}")
        Dmhai.SysLog.log("[POLICE] REJECTED assistant_text_bookkeeping: #{inspect(String.slice(trimmed, 0, 200))}")
        {:rejected, {:assistant_text_bookkeeping, reason}}

      true ->
        :ok
    end
  end
  def check_assistant_text(_), do: :ok

  @doc """
  Enforce that every `📎 ` path in the current turn's user message was
  passed to `extract_content` during this turn. Catches the model-
  compliance failure where the model acknowledges an attachment in
  prose ("I see the PDF you attached…") but never reads it — leaving
  it with no actual content to answer from.

  `fresh_paths` — the list of workspace paths the context builder
  injected the `[newly attached]` marker on for this turn (i.e. the
  `📎 ` paths from the last user message).

  `in_turn_messages` — the messages list accumulated inside
  `session_turn_loop` across tool rounds. Every assistant-role message
  with `tool_calls` is scanned; calls whose name is `"extract_content"`
  contribute their `path` argument to the "read" set.

  Returns `:ok` if every fresh path was read. Otherwise returns a
  rejection message listing the missed paths so the session loop can
  nudge the model to retry.
  """
  @spec check_fresh_attachments_read([String.t()], [map()]) :: :ok | {:rejected, {atom(), String.t()}}
  def check_fresh_attachments_read([], _messages), do: :ok
  def check_fresh_attachments_read(fresh_paths, messages) when is_list(fresh_paths) do
    read_paths = collect_extracted_paths(messages)
    missed     = Enum.reject(fresh_paths, &(&1 in read_paths))

    if missed == [] do
      :ok
    else
      joined = Enum.map_join(missed, "\n", fn p -> "  - `#{p}`" end)
      reason =
        "Error: you have `[newly attached]` attachments in the current user " <>
          "message that you didn't read this turn:\n#{joined}\n" <>
          "You must call `extract_content(path: <workspace/...>)` on each of " <>
          "them — the user re-attached them because they want another look. " <>
          "Retry the turn: if you haven't created a task yet, call `create_task` " <>
          "first, then `extract_content` per attachment, then produce your " <>
          "final answer."

      Logger.warning("[Police] REJECTED fresh_attachments_unread: missed=#{inspect(missed)}")
      Dmhai.SysLog.log("[POLICE] REJECTED fresh_attachments_unread: missed=#{inspect(missed)}")
      {:rejected, {:fresh_attachments_unread, reason}}
    end
  end
  def check_fresh_attachments_read(_, _), do: :ok

  @doc """
  Per-tool-call gate: reject when the same `(tool_name, significant_arg)`
  combination has already been invoked earlier in THIS turn. Prevents
  the "model creates two identical tasks in a row for one follow-up" /
  "model re-extracts the same PDF twice" misbehaviour we see on weaker
  models like gemini-3-flash.

  `prior_messages` is the in-turn message accumulator — a list containing
  every assistant-role message with `tool_calls` emitted earlier in this
  turn (either in a prior round, OR earlier in the CURRENT batch of
  tool_calls from one LLM response). Cross-turn repeats are NOT flagged
  here — those are addressed by the `Recently-extracted files` prompt
  block and the `[newly attached]` marker logic.

  Significance key per tool:

    * `create_task`     → `task_title` (downcased + trimmed)
    * `extract_content` → `path` (case-sensitive; Linux FS)
    * `web_search`      → `query` (downcased + trimmed)

  Tools outside this list bypass the check (no significance key defined).
  """
  @spec check_no_duplicate_tool_call(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_no_duplicate_tool_call(name, args, prior_messages)
      when is_binary(name) and is_map(args) and is_list(prior_messages) do
    case significant_key(name, args) do
      nil ->
        :ok

      key ->
        if already_called?(name, key, prior_messages) do
          reason =
            "Error: you already called `#{name}` with the same significant argument " <>
              "(#{describe_key(name)}=#{inspect(key)}) earlier in THIS turn. " <>
              "Duplicate calls aren't useful — the earlier call's result is " <>
              "already in your context as a `role: \"tool\"` message. Either " <>
              "answer the user from the earlier result, or call a DIFFERENT " <>
              "tool to move the task forward. Do not repeat yourself."

          Logger.warning(
            "[Police] REJECTED duplicate_tool_call_in_turn: tool=#{name} key=#{inspect(key)}"
          )

          Dmhai.SysLog.log(
            "[POLICE] REJECTED duplicate_tool_call_in_turn: tool=#{name} key=#{inspect(key)}"
          )

          {:rejected, {:duplicate_tool_call_in_turn, reason}}
        else
          :ok
        end
    end
  end
  def check_no_duplicate_tool_call(_, _, _), do: :ok

  # Pick the "significant argument" that defines a duplicate. Normalised
  # forms let "Explain X" / "explain x " be treated as the same title.
  defp significant_key("create_task", args) do
    case args["task_title"] do
      t when is_binary(t) ->
        n = t |> String.trim() |> String.downcase()
        if n == "", do: nil, else: n

      _ ->
        nil
    end
  end

  defp significant_key("extract_content", args) do
    case args["path"] do
      p when is_binary(p) and p != "" -> String.trim(p)
      _ -> nil
    end
  end

  defp significant_key("web_search", args) do
    case args["query"] do
      q when is_binary(q) ->
        n = q |> String.trim() |> String.downcase()
        if n == "", do: nil, else: n

      _ ->
        nil
    end
  end

  defp significant_key(_, _), do: nil

  defp describe_key("create_task"),     do: "task_title"
  defp describe_key("extract_content"), do: "path"
  defp describe_key("web_search"),      do: "query"
  defp describe_key(_),                 do: "arg"

  # Walk the prior messages, extract every assistant-role tool_call's
  # (name, significant_key), return true if any match the current pair.
  defp already_called?(name, key, prior_messages) do
    Enum.any?(prior_messages, fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) do
        Enum.any?(calls, fn c ->
          fn_map    = c["function"] || c[:function] || %{}
          call_name = fn_map["name"] || fn_map[:name] || ""
          raw_args  = fn_map["arguments"] || fn_map[:arguments] || %{}
          call_args = if is_binary(raw_args), do: decode_or_empty(raw_args), else: raw_args

          call_name == name and significant_key(call_name, call_args) == key
        end)
      else
        false
      end
    end)
  end

  @doc """
  Per-tool-call gate enforcing the "one periodic task per chat session"
  policy. Rejects `create_task(task_type: "periodic", ...)` when the
  session already has an ACTIVE periodic task (pending / ongoing /
  paused — any non-terminal state).

  The nudge is educational AND user-facing: it tells the model exactly
  what to say to the user, naming the existing periodic by its
  per-session `(N)` number + title so the reply is concrete. If the
  user genuinely wants a different periodic schedule, the model should
  propose cancelling the existing one first and wait for confirmation —
  no unilateral replacement.

  Only fires on `create_task` with `task_type: "periodic"`. All other
  tool calls bypass. `ctx[:session_id]` is required (non-session
  callers bypass).
  """
  @spec check_no_duplicate_periodic_task_in_session(String.t(), map(), map()) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_no_duplicate_periodic_task_in_session("create_task", args, ctx)
      when is_map(args) and is_map(ctx) do
    cond do
      args["task_type"] != "periodic" ->
        :ok

      not Map.has_key?(ctx, :session_id) ->
        :ok

      true ->
        case Dmhai.Agent.Tasks.session_active_periodic(ctx[:session_id]) do
          nil ->
            :ok

          existing ->
            reason = build_duplicate_periodic_reason(existing)

            Logger.warning(
              "[Police] REJECTED duplicate_periodic_task_in_session: " <>
                "session=#{inspect(ctx[:session_id])} existing=#{existing.task_id}"
            )

            Dmhai.SysLog.log(
              "[POLICE] REJECTED duplicate_periodic_task_in_session: " <>
                "session=#{inspect(ctx[:session_id])} existing=#{existing.task_id}"
            )

            {:rejected, {:duplicate_periodic_task_in_session, reason}}
        end
    end
  end
  def check_no_duplicate_periodic_task_in_session(_, _, _), do: :ok

  defp build_duplicate_periodic_reason(existing) do
    num = existing.task_num || "?"
    title = existing.task_title || "(untitled)"

    "Error: this chat session already has an active periodic task — " <>
      "task (#{num}) `#{existing.task_id}` — #{title}. " <>
      "DMH-AI supports at most ONE periodic task per chat session, " <>
      "so this `create_task(task_type: \"periodic\", ...)` is rejected.\n\n" <>
      "What to do next:\n" <>
      "  (a) If the user ASKED for a different periodic schedule, do NOT " <>
      "create a new one silently. Reply to them IN THEIR LANGUAGE with " <>
      "exactly this information: \"We already have task (#{num}) " <>
      "running periodically in this session. DMH-AI only supports 1 " <>
      "periodic task per chat session. I can cancel task (#{num}) first, " <>
      "then set up the new one — want me to do that?\" Then WAIT for " <>
      "their answer; do not act unilaterally.\n" <>
      "  (b) If the user is asking a regular question, call " <>
      "`create_task(task_type: \"one_off\", ...)` instead — not " <>
      "periodic.\n" <>
      "  (c) If you were trying to PROGRESS the existing periodic task " <>
      "(this happens during a `[Task due: ...]` pickup), use " <>
      "`update_task(task_id: \"#{existing.task_id}\", ...)` — do NOT " <>
      "call `create_task`. A second periodic row is always a bug."
  end

  @doc """
  Per-tool-call gate: reject a `web_search` call when the immediately-
  preceding tool call in this turn was ALSO `web_search`.

  Rationale: one `web_search` already fans out 2-3 parallel search
  queries in the BE (see `Dmhai.Web.Search.generate_queries`), so a
  second consecutive call is redundant — the model should either answer
  from what it already has OR reach for a DIFFERENT tool
  (`run_script` with a direct API call when the question targets a
  named service, `web_fetch` when it has a specific URL in mind).

  Alternating is fine: `web_search` → `run_script` → `web_search` is
  allowed when each step has a legitimate role. The gate only fires on
  TWO web_searches with nothing between them.

  `prior_messages` — the in-turn message accumulator (same shape as
  `check_no_duplicate_tool_call/3`). Intra-batch duplicates AND
  inter-round repeats are both covered because `execute_tools/3`
  appends a synthetic assistant message per tool_call as it iterates.
  """
  @spec check_no_consecutive_web_search(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_no_consecutive_web_search("web_search", _args, prior_messages)
      when is_list(prior_messages) do
    case last_tool_call_name(prior_messages) do
      "web_search" ->
        reason =
          "Error: your immediately-prior tool call was `web_search`, and one " <>
            "`web_search` already runs 2-3 parallel queries in the backend. " <>
            "Calling it again right now is wasted effort.\n\n" <>
            "The correct research loop is:\n" <>
            "  1. DIGEST what the first `web_search` already returned — read " <>
            "the snippets, identify names/URLs/terms that emerged.\n" <>
            "  2. DIG DEEPER with a DIFFERENT tool on those findings: " <>
            "`web_fetch` a specific URL the snippets mentioned; `run_script` " <>
            "with `curl`/`jq` against a named service's API; `extract_content` " <>
            "on a document you pulled down.\n" <>
            "  3. Once you have concrete findings, THEN — and only if a gap " <>
            "genuinely remains — consider another `web_search` with a query " <>
            "refined by what you just learned. This is when the alternating " <>
            "pattern `web_search` → (other tool) → `web_search` is legitimate.\n\n" <>
            "What not to do: chaining two `web_search` calls back-to-back with " <>
            "slightly reworded queries. The parallel fan-out of a single call " <>
            "already covers that variance, and repeating doesn't unlock new " <>
            "sources — it just burns tokens and stalls the turn."

        Logger.warning("[Police] REJECTED consecutive_web_search")
        Dmhai.SysLog.log("[POLICE] REJECTED consecutive_web_search")
        {:rejected, {:consecutive_web_search, reason}}

      _ ->
        :ok
    end
  end
  def check_no_consecutive_web_search(_, _, _), do: :ok

  # Walk `prior_messages` newest-to-oldest, find the last assistant-role
  # message that carries a non-empty `tool_calls` list, return the name
  # of its LAST tool_call. The "last call in the last batch" is the
  # correct signal for consecutivity — task-bookkeeping calls
  # (create_task / update_task) emitted between web_searches are still
  # tool calls and break the sequence by design (if the model is
  # transitioning tasks, it's probably a different search intent).
  defp last_tool_call_name(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) and calls != [] do
        last_call = List.last(calls)
        fn_map    = last_call["function"] || last_call[:function] || %{}
        fn_map["name"] || fn_map[:name]
      else
        nil
      end
    end)
  end

  @doc """
  Pull the set of `📎 [newly attached] <path>` paths from the last
  user-role message in a message array. Used at turn start to snapshot
  the "must be read this turn" set for
  `check_fresh_attachments_read/2`.
  """
  @spec extract_fresh_attachment_paths([map()]) :: [String.t()]
  def extract_fresh_attachment_paths(messages) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> (m[:role] || m["role"]) == "user" end)

    case last_user do
      nil -> []
      msg ->
        content = msg[:content] || msg["content"] || ""

        ~r/📎\s+\[newly attached\]\s+(\S+)/u
        |> Regex.scan(content, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&String.trim/1)
    end
  end

  # Scan the turn's message accumulator for `extract_content` tool_calls
  # and return the set of `path` argument values the model passed.
  defp collect_extracted_paths(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) do
        Enum.flat_map(calls, fn call ->
          name = get_in(call, ["function", "name"]) || ""
          args = get_in(call, ["function", "arguments"]) || %{}
          args = if is_binary(args), do: decode_or_empty(args), else: args

          if name == "extract_content" and is_binary(args["path"]) do
            [args["path"]]
          else
            []
          end
        end)
      else
        []
      end
    end)
    |> MapSet.new()
    |> MapSet.to_list()
  end
end
