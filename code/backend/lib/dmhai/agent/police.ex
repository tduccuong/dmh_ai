# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Police do
  @moduledoc """
  Path-safety gate for tool calls plus task-discipline and
  tool-call-shape enforcement. The model has broad tool freedom,
  so Police only intervenes where the runtime MUST enforce an
  invariant (sandbox escape, task wrapper, duplicate calls,
  silent-turn scope).

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

  # Execution-class tools: must be preceded by a `pickup_task` in the
  # current turn. Anything not in this list is unconditionally allowed
  # — including the task-management verbs themselves (create_task /
  # pickup_task / complete_task / pause_task / cancel_task / fetch_task —
  # how the model complies) and trivial utilities (datetime, calculator).
  #
  # Creds tools and `connect_mcp` ARE gated: they're always fetched
  # / set up in service of a user-facing objective, so they sit under
  # the task wrapper like any other execution tool. Without the gate,
  # a mid-chain "stop the task" has nothing to bind to, and the chat
  # timeline shows execution work that isn't tied to a tracked task.
  @gated_tools [
    "run_script",
    "web_fetch",
    "web_search",
    "extract_content",
    "read_file",
    "write_file",
    "spawn_task",
    "lookup_creds",
    "save_creds",
    "delete_creds",
    "request_input",
    "connect_mcp",
    "provision_ssh_identity"
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
  Per-tool-call gate: every user-initiated chain must `pickup_task` an
  explicit task_id before it runs any gated execution tool. Forces the
  verb-lifecycle `create_task → pickup_task → exec tools → complete_task`
  and enforces "each new user ask = its OWN task" (prior rule was
  session-scoped and got shielded by long-lived periodic tasks in the
  same session).

  Rule skips in these cases:

    * Tool isn't in `@gated_tools` (task-management verbs, credential
      tools, calculator — never blocked).
    * `ctx` carries no `:session_id` (non-session callers bypass).
    * `ctx` carries `:silent_turn_task_id` — silent chain. The scheduler
      already fired for a specific task; `mark_ongoing` is applied in
      `run_assistant_silent`. Model doesn't need to re-pickup the same
      task. Police rule #9 (silent-turn-scope) governs cross-task
      misuse instead.
    * `prior_messages` (the in-chain accumulator) already contains a
      `pickup_task` tool-call. Model has explicitly picked up a task
      this chain — gated tools can run.

  Otherwise reject with a nudge teaching the lifecycle.
  """
  @spec check_task_discipline(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_task_discipline(name, ctx, prior_messages)
      when is_binary(name) and is_map(ctx) and is_list(prior_messages) do
    cond do
      name not in @gated_tools ->
        :ok

      not Map.has_key?(ctx, :session_id) ->
        :ok

      Map.has_key?(ctx, :silent_turn_task_id) ->
        :ok

      # Anchor is already set for this chain — the runtime resolved an
      # active task at chain start (prior chain left one ongoing, or
      # the user is mid-exchange on a multi-chain task where the model
      # asked a clarifying question last chain). The task wrapper is
      # satisfied; no in-chain `create_task` / `pickup_task` is needed.
      is_integer(Map.get(ctx, :anchor_task_num)) ->
        :ok

      has_pickup_task_in_chain?(prior_messages) ->
        :ok

      true ->
        reason =
          "Error: you haven't started a task in THIS chain, so `#{name}` " <>
            "is rejected. Every user ask needs an active task. Two paths:\n" <>
            "  (a) NEW objective → `create_task(...)`. This both registers " <>
            "AND starts the task (auto-pickup) — your next call can be " <>
            "`#{name}` directly. No separate `pickup_task` needed.\n" <>
            "  (b) RESUMING an existing task from the Task list (done / " <>
            "paused / cancelled, or ongoing but context was lost) → " <>
            "`pickup_task(task_num: N)`.\n" <>
            "Then retry `#{name}`. When finished, `complete_task(task_num: " <>
            "N, task_result: ...)`."

        Logger.warning("[Police] REJECTED task_discipline: tool=#{name} session=#{inspect(ctx[:session_id])}")
        Dmhai.SysLog.log("[POLICE] REJECTED task_discipline: tool=#{name} session=#{inspect(ctx[:session_id])}")
        {:rejected, {:task_discipline, reason}}
    end
  end
  # Old 2-arity arity kept for any residual caller; forwards with empty prior_messages.
  def check_task_discipline(name, ctx) when is_binary(name) and is_map(ctx),
    do: check_task_discipline(name, ctx, [])

  # True if any assistant message in the in-chain accumulator carries a
  # `pickup_task` OR `create_task` tool_call. `create_task` auto-picks
  # up (tasks start at `ongoing` and the runtime advances
  # `ctx.anchor_task_num` to match), so a chain that called
  # `create_task` has already "picked up" its new task — requiring a
  # separate `pickup_task` after it would be redundant. `pickup_task`
  # remains valid for RESUMING a task already in the list; both
  # satisfy the discipline gate.
  defp has_pickup_task_in_chain?(messages) do
    Enum.any?(messages, fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) do
        Enum.any?(calls, fn c ->
          fn_map = c["function"] || c[:function] || %{}
          name   = fn_map["name"] || fn_map[:name]
          name in ["pickup_task", "create_task"]
        end)
      else
        false
      end
    end)
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

  @doc """
  Per-tool-call gate: reject when the emitted `name` doesn't correspond to
  a registered tool. Guards against model output malformation where the
  model stuffs garbled or hallucinated content into `function.name`
  (we've seen ~1000-char blobs, including entire natural-language
  responses glued together with LRM separators, as the name field).

  The rejection message enumerates the valid tool names so the next-turn
  corrective tool_result gives the model the concrete vocabulary to
  recover with. Same silent-to-user handling as task_discipline —
  the progress row is never written for an unknown-tool rejection.
  """
  @spec check_tool_known(String.t()) :: :ok | {:rejected, {atom(), String.t()}}
  def check_tool_known(name) when is_binary(name), do: check_tool_known(name, nil, nil)

  def check_tool_known(_),
    do: {:rejected, {:unknown_tool_name, "Error: tool_call `function.name` must be a string."}}

  @doc """
  Task-aware variant. Includes the MCP tools attached to the user's
  current anchor task in the validity check so `<alias>.<tool>`
  names registered via `connect_mcp` are accepted while their
  task is alive, and rejected once it closes.
  """
  @spec check_tool_known(String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_tool_known(name, user_id, task_id) when is_binary(name) do
    if Dmhai.Tools.Registry.known?(name, user_id, task_id) do
      :ok
    else
      name_preview = String.slice(name, 0, 120)

      valid_names = Dmhai.Tools.Registry.names(user_id, task_id)

      reason = unknown_tool_name_reason(name_preview, valid_names)

      Logger.warning("[Police] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      Dmhai.SysLog.log("[POLICE] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      {:rejected, {:unknown_tool_name, reason}}
    end
  end

  def check_tool_known(_, _, _),
    do: {:rejected, {:unknown_tool_name, "Error: tool_call `function.name` must be a string."}}

  # MCP-attached tools live under `<alias>.<tool>`. When a name has
  # that shape but isn't in the catalog, the most likely cause is
  # the model is reaching for a service it used in a previous task
  # but hasn't attached to the current one — `connect_mcp` per
  # task is the contract. Lead with that hint instead of the bare
  # tool list, which won't help if the right tool genuinely needs
  # to be brought in via attachment.
  defp unknown_tool_name_reason(name_preview, valid_names) do
    case String.split(name_preview, ".", parts: 2) do
      [alias_, _tool] when alias_ != "" ->
        "Error: `#{name_preview}` is not currently attached to this task. Namespaced tools " <>
          "(`<alias>.<tool>`) come from external services attached via `connect_mcp`. " <>
          "If you want to use `#{alias_}` here, call `connect_mcp` first with the server's " <>
          "URL — even if you've connected it in a previous task, attachments are per-task and " <>
          "must be re-established.\n\n" <>
          "Tools currently available: " <> Enum.join(valid_names, ", ") <> "."

      _ ->
        "Error: `#{name_preview}` is not a valid tool name. Pick one of: " <>
          Enum.join(valid_names, ", ") <>
          ". Each tool_call must have a plain tool name in the `function.name` field and the " <>
          "arguments as a JSON object in `function.arguments`. Retry with the correct structure."
    end
  end

  @doc """
  Guard on the TEXT turn's final content. Catches the failure mode
  where a model emits what it MEANT to be a tool_call as the assistant
  message's content field — e.g. the entire content is just the string
  `"complete_task"` or `"create_task(...)"` — so the chain ends without
  actually calling the tool and the task stays stuck in `ongoing`.

  Conservative detector: fires only when the trimmed text is EXACTLY a
  registered tool name, OR has the shape `tool_name(…)` where `tool_name`
  is registered. Never fires on legitimate short replies like "Done.",
  "Yes", or any multi-word text that happens to contain a tool name
  somewhere.

  On rejection the chain loop injects a corrective user-role message
  and recurses one more turn; the bad text is never persisted.
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
            "(1) if you meant to close / cancel / pause a task, emit a " <>
            "REAL `tool_call` to `complete_task` / `cancel_task` / " <>
            "`pause_task` with the right arguments — do NOT paraphrase " <>
            "it in text; " <>
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
  combination has already been invoked earlier in THIS chain. Prevents
  the "model creates two identical tasks in a row for one follow-up" /
  "model re-extracts the same PDF twice" misbehaviour that appears on
  weaker models.

  `prior_messages` is the in-chain message accumulator — a list containing
  every assistant-role message with `tool_calls` emitted earlier in this
  chain (either in a prior turn, OR earlier in the CURRENT batch of
  tool_calls from one LLM response). Cross-chain repeats are NOT flagged
  here — those are addressed by the `Recently-extracted files` prompt
  block and the `[newly attached]` marker logic.

  Significance key per tool:

    * `create_task`     → `task_title` (downcased + trimmed)
    * `extract_content` → `path` (case-sensitive; Linux FS)
    * `web_search`      → `query` (downcased + trimmed)
    * `run_script`      → `script` normalised (comment lines stripped,
                          whitespace runs collapsed) — catches loops
                          where the model only varies a comment

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
              "(#{describe_key(name)}=#{inspect(key)}) earlier in THIS chain. " <>
              "Duplicate calls aren't useful — the earlier call's result is " <>
              "already in your context as a `role: \"tool\"` message. Either " <>
              "answer the user from the earlier result, or call a DIFFERENT " <>
              "tool to move the task forward. Do not repeat yourself."

          Logger.warning(
            "[Police] REJECTED duplicate_tool_call_in_chain: tool=#{name} key=#{inspect(key)}"
          )

          Dmhai.SysLog.log(
            "[POLICE] REJECTED duplicate_tool_call_in_chain: tool=#{name} key=#{inspect(key)}"
          )

          {:rejected, {:duplicate_tool_call_in_chain, reason}}
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

  # pickup/complete/pause/cancel_task all key on `task_num` — two
  # calls to the same verb on the same task_num within a chain is
  # always wrong (either a redundant retry of a successful call or
  # the model looping on itself; either way the second is waste).
  # `pickup_task` is the one edge-case: it IS intentionally
  # idempotent when already-ongoing. But calling it twice in a single
  # chain is still a duplicate by the "same name + same key" rule —
  # the tool would no-op the second time. Catching it at Police level
  # surfaces the redundancy to the model as a nudge instead of
  # silently succeeding and wasting a turn.
  defp significant_key(v, args) when v in ~w(pickup_task complete_task pause_task cancel_task) do
    case coerce_num(args["task_num"]) do
      n when is_integer(n) -> n
      _                     -> nil
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

  # `run_script` keys on the script text NORMALISED — comment lines (`#`-
  # prefixed) stripped, whitespace runs collapsed to single spaces.
  # Catches the common misbehaviour where a model loops on the same curl
  # / shell command and only varies the leading comment ("# Try again",
  # "# With correct syntax"). The actual underlying command stays
  # identical → wasted turn. Different operations / URLs / args / flags
  # produce a different normalised key and pass through. See
  # architecture.md §Police gate #6.
  defp significant_key("run_script", args) do
    case args["script"] do
      s when is_binary(s) and s != "" ->
        normalised =
          s
          |> String.split("\n")
          |> Enum.reject(&(&1 |> String.trim() |> String.starts_with?("#")))
          |> Enum.join(" ")
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        if normalised == "", do: nil, else: normalised

      _ ->
        nil
    end
  end

  defp significant_key(_, _), do: nil

  defp describe_key("create_task"),     do: "task_title"
  defp describe_key(v) when v in ~w(pickup_task complete_task pause_task cancel_task),
    do: "task_num"
  defp describe_key("extract_content"), do: "path"
  defp describe_key("web_search"),      do: "query"
  defp describe_key("run_script"),      do: "normalized script"
  defp describe_key(_),                 do: "arg"

  # Integer-or-stringified-integer → integer | nil. Used by
  # `significant_key/2` for verb dedup and by silent-turn scope.
  defp coerce_num(n) when is_integer(n), do: n
  defp coerce_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _        -> nil
    end
  end
  defp coerce_num(_), do: nil

  # Walk the prior messages, extract every assistant-role tool_call's
  # (name, significant_key), return true if any match the current pair.
  defp already_called?(name, key, prior_messages) do
    Enum.any?(prior_messages, fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) do
        Enum.any?(calls, fn c ->
          # Skip calls Police itself rejected upstream. A rejection
          # means the call never ran, so the next attempt with the
          # same args is a retry — not a duplicate. `execute_tools`
          # tags the call dict with `_rejected: true` when its
          # tool_msg carried a rejection marker.
          rejected? = c["_rejected"] || c[:_rejected] || false

          if rejected? do
            false
          else
            fn_map    = c["function"] || c[:function] || %{}
            call_name = fn_map["name"] || fn_map[:name] || ""
            raw_args  = fn_map["arguments"] || fn_map[:arguments] || %{}
            call_args = if is_binary(raw_args), do: decode_or_empty(raw_args), else: raw_args

            call_name == name and significant_key(call_name, call_args) == key
          end
        end)
      else
        false
      end
    end)
  end

  # Task-management verbs whose `task_num` argument MUST target the
  # silent turn's pickup task. Other tools — execution (`run_script`,
  # `web_fetch`, …), read-only (`fetch_task`), and `create_task`
  # (rejected separately under rule #9) — are NOT in this list.
  @silent_turn_scoped_verbs ~w(pickup_task complete_task pause_task cancel_task)

  @doc """
  Per-tool-call gate enforcing silent-turn scope: a scheduler-triggered
  pickup is for ONE specific task only. The model must not use the
  trigger to do other work. Reject:

    * `create_task` — new task creation requires a user message, not a
      silent-turn opportunity.
    * `pickup_task` / `complete_task` / `pause_task` / `cancel_task`
      targeting a `task_id` that is NOT the one the silent turn fired
      for — progressing / cancelling / modifying any OTHER task during
      a silent turn hijacks the pickup's scope.

  `fetch_task` is allowed (read-only inspection) and every execution
  tool (`run_script`, `web_fetch`, etc.) is allowed — the model needs
  those to produce the task's output.

  `ctx[:silent_turn_task_id]` is set only in `run_assistant_silent`
  (scheduler-triggered silent turns). User-initiated turns never set
  it, so this gate is a no-op there.

  Each off-scope call shows up as a verb against a different
  `task_id` → this gate rejects it with a specific nudge pointing
  back to the pickup's task_id.
  """
  @spec check_silent_turn_scope(String.t(), map(), map()) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_silent_turn_scope(name, args, ctx)
      when is_binary(name) and is_map(args) and is_map(ctx) do
    # Scope check compares task_num against the silent-turn anchor's
    # task_num (Map.get(ctx, :anchor_task_num)). The anchor is
    # MUTABLE — after the model calls complete / cancel / pause on the
    # silent-pickup task, the anchor flips to its back-reference (or
    # nil if exhausted). When the anchor is nil in a silent turn, NO
    # further tool calls are allowed — the chain must end with text.
    # See architecture.md §Anchor mutation via back_to_when_done
    # back-stack.
    pickup_tid = Map.get(ctx, :silent_turn_task_id)
    pickup_num = Map.get(ctx, :anchor_task_num)

    case pickup_tid do
      nil ->
        :ok

      _ when is_nil(pickup_num) ->
        # Silent turn, pickup task closed, back-stack exhausted → free
        # mode. The chain's scope is gone; any further tool call is
        # out of scope. Model must emit final user-facing text.
        reason =
          "Error: you are inside a SILENT pickup turn, the task you " <>
            "picked up has been closed (complete / cancel / pause), " <>
            "and its back-reference chain has exhausted — no other " <>
            "active task to return to. **The chain's work is done.** " <>
            "Emit your final user-facing text now and end the turn. " <>
            "Do NOT start fresh tool calls: even if some other task " <>
            "in the session is still `ongoing`, progressing it isn't " <>
            "your job in THIS silent turn. If the user wants that " <>
            "work, they'll ask on their next message."

        Logger.warning("[Police] REJECTED silent_turn_pickup_closed: tool=#{name}")
        Dmhai.SysLog.log("[POLICE] REJECTED silent_turn_pickup_closed: tool=#{name}")

        {:rejected, {:silent_turn_pickup_closed, reason}}

      _ ->
        cond do
          name == "create_task" ->
            reason =
              "Error: you are inside a SILENT pickup turn for task " <>
                "(#{inspect(pickup_num)}) — the scheduler fired this turn to " <>
                "progress that one task and nothing else. `create_task` is " <>
                "forbidden here: creating a new task in a scheduler-triggered " <>
                "turn would hijack the pickup's scope. If a user asked for a " <>
                "new task in an earlier conversational turn, they will re-ask " <>
                "on their next message — wait for that. Right now, produce the " <>
                "pickup's output via execution tools, then call " <>
                "`complete_task(task_num: #{inspect(pickup_num)}, " <>
                "task_result: \"…\")` and emit your final text."

            Logger.warning(
              "[Police] REJECTED silent_turn_create_task: pickup_num=#{inspect(pickup_num)}"
            )

            Dmhai.SysLog.log(
              "[POLICE] REJECTED silent_turn_create_task: pickup_num=#{inspect(pickup_num)}"
            )

            {:rejected, {:silent_turn_create_task, reason}}

          name in @silent_turn_scoped_verbs ->
            called_num = coerce_num(args["task_num"])

            if is_integer(called_num) and is_integer(pickup_num) and called_num != pickup_num do
              reason =
                "Error: you are inside a SILENT pickup turn for task " <>
                  "(#{pickup_num}), but this `#{name}` call targets a " <>
                  "DIFFERENT task (#{called_num}). A silent turn may " <>
                  "progress ONLY the task that triggered it. Modifying " <>
                  "another task mid-pickup (cancelling it to free a slot, " <>
                  "bulk-closing other rows, pausing a sibling) is out of " <>
                  "scope and requires the user to initiate in a normal " <>
                  "conversational turn. Retry with `#{name}(task_num: " <>
                  "#{pickup_num}, ...)` — targeting the task this pickup " <>
                  "actually fired for — or drop the call entirely."

              Logger.warning(
                "[Police] REJECTED silent_turn_other_task_verb: " <>
                  "pickup_num=#{pickup_num} called_num=#{called_num} verb=#{name}"
              )

              Dmhai.SysLog.log(
                "[POLICE] REJECTED silent_turn_other_task_verb: " <>
                  "pickup_num=#{pickup_num} called_num=#{called_num} verb=#{name}"
              )

              {:rejected, {:silent_turn_other_task_verb, reason}}
            else
              :ok
            end

          true ->
            :ok
        end
    end
  end
  def check_silent_turn_scope(_, _, _), do: :ok

  # Tools whose semantics are inherently tied to managing/closing the
  # active anchor task or to feeding/clarifying it. Exempt from the
  # `:unrelated` branch of `check_pivot/3` — a model who's been told
  # to confirm the pivot must still be ABLE to call pause/cancel/etc.
  # to follow through. The `:knowledge` branch has NO exemption — a
  # knowledge question never warrants any tool, not even task-mgmt.
  @pivot_unrelated_exempt MapSet.new(~w(
    pause_task cancel_task complete_task pickup_task fetch_task request_input
  ))

  @doc """
  Per-tool-call gate backed by the Oracle classifier. Reads
  `ctx.oracle_task` (a `Task` struct kicked off at chain start in
  `run_assistant`) and decides:

    * `:related`   → pass.
    * `:unrelated` → reject UNLESS `name` is in
      `@pivot_unrelated_exempt`. The nudge tells the model to confirm
      with the user (pause / cancel / stop the anchor) before doing
      tool work for the new ask.
    * `:knowledge` → reject ALL tool names. Nudge: "this is a
      knowledge / chitchat question — answer from your training in
      plain text, no tool call."
    * `:error` (timeout / classifier failure) → pass (soft fail; we
      never block legitimate work on a flaky classifier).

  Cache: the verdict is awaited at most once per chain. The first
  call to this gate awaits, parks the verdict in the process
  dictionary, and subsequent calls in the same chain read from
  there. The Oracle Task is shut down right after the await so it
  doesn't outlive its usefulness.

  Pending-pivot stashing happens INSIDE the Oracle Task itself
  (see `Dmhai.Agent.UserAgent.maybe_start_oracle/3`) — fired as a
  side effect when the verdict resolves to `:unrelated`. That way
  the stash happens whether or not Police's gate ever runs (e.g.
  the model went text-only on the off-topic chain), so the
  auto-create-task hook fires correctly when the user later
  confirms with `pause_task` / `cancel_task`.
  """
  @spec check_pivot(String.t(), map(), map()) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_pivot(name, args, ctx)
      when is_binary(name) and is_map(args) and is_map(ctx) do
    case oracle_verdict(ctx) do
      :related ->
        :ok

      :error ->
        :ok

      :knowledge ->
        reject_knowledge(name)

      :unrelated ->
        if MapSet.member?(@pivot_unrelated_exempt, name) do
          :ok
        else
          reject_unrelated(name, ctx)
        end
    end
  end
  def check_pivot(_, _, _), do: :ok

  @oracle_await_ms 3_000

  defp oracle_verdict(ctx) do
    case Process.get(:dmhai_oracle_verdict_cached) do
      {:resolved, v} ->
        v

      _ ->
        v = await_oracle(Map.get(ctx, :oracle_task))
        Process.put(:dmhai_oracle_verdict_cached, {:resolved, v})
        v
    end
  end

  defp await_oracle(nil), do: :related
  defp await_oracle(%Task{} = task) do
    case Task.yield(task, @oracle_await_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, v} when v in [:related, :unrelated, :knowledge, :error] -> v
      _ -> :error
    end
  end
  defp await_oracle(_), do: :error

  defp reject_unrelated(name, ctx) do
    anchor_num = Map.get(ctx, :anchor_task_num)

    reason =
      "Error: the user's latest message is OFF-TOPIC from active anchor task " <>
        "(#{anchor_num}). Calling `#{name}` for it would silently abandon " <>
        "(#{anchor_num}) — the user is still expecting an outcome there.\n\n" <>
        "Your ONLY action this turn is plain text. Ask the user (no tool call):\n" <>
        "  \"I'm currently on task (#{anchor_num}). Want me to pause/cancel/stop it " <>
        "and handle your new request first, or finish (#{anchor_num}) before " <>
        "getting to it?\"\n\n" <>
        "Then end the turn and wait for their answer. When they confirm with " <>
        "pause/cancel/stop, the runtime will create the new task automatically " <>
        "from their original message — you won't need to call `create_task` " <>
        "yourself; just proceed with whatever tool the new ask actually needs."

    Logger.warning("[Police] REJECTED pivot_unrelated: tool=#{name} anchor=#{inspect(anchor_num)}")
    Dmhai.SysLog.log("[POLICE] REJECTED pivot_unrelated: tool=#{name} anchor=#{inspect(anchor_num)}")

    {:rejected, {:pivot_unrelated, reason}}
  end

  defp reject_knowledge(name) do
    reason =
      "Error: the user's latest message is a knowledge / chitchat / greeting " <>
        "question — answerable from your own training, no tool call needed. " <>
        "Calling `#{name}` for it is overkill and slows the response.\n\n" <>
        "Reply directly in plain text. Use the language the user wrote in. " <>
        "If you genuinely don't know the answer, say so — don't try to web_search " <>
        "your way around a casual question."

    Logger.warning("[Police] REJECTED pivot_knowledge: tool=#{name}")
    Dmhai.SysLog.log("[POLICE] REJECTED pivot_knowledge: tool=#{name}")

    {:rejected, {:pivot_knowledge, reason}}
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
      "task (#{num}) — #{title}. " <>
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
      "(this happens during a `[Task due: ...]` pickup), use the " <>
      "verb API against the existing (N): `pickup_task(task_num: #{num})` " <>
      "→ produce output via execution tools → " <>
      "`complete_task(task_num: #{num}, task_result: \"…\")`. " <>
      "Do NOT call `create_task`. A second periodic row is always a bug."
  end

  @doc """
  Per-tool-call gate: reject a `web_search` call when the immediately-
  preceding tool call in this chain was ALSO `web_search`.

  Rationale: one `web_search` already fans out 2-3 parallel search
  queries in the BE (see `Dmhai.Web.Search.generate_queries`), so a
  second consecutive call is redundant — the model should either answer
  from what it already has OR reach for a DIFFERENT tool
  (`run_script` with a direct API call when the question targets a
  named service, `web_fetch` when it has a specific URL in mind).

  Alternating is fine: `web_search` → `run_script` → `web_search` is
  allowed when each step has a legitimate role. The gate only fires on
  TWO web_searches with nothing between them.

  `prior_messages` — the in-chain message accumulator (same shape as
  `check_no_duplicate_tool_call/3`). Intra-batch duplicates AND
  inter-turn repeats are both covered because `execute_tools/3`
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

  @doc """
  Per-tool-call gate: cap `run_script` at `AgentSettings.run_script_probe_budget()`
  per chain (default 5). The (N+1)th `run_script` is rejected with a
  nudge that teaches the model to either compose the rest into ONE more
  script OR end the chain by asking the user the specific question
  probes can't answer.

  Counts ALL `run_script` calls in `prior_messages`, not just consecutive
  ones — once the model is on a probing trajectory, mixing in
  `web_fetch` / `read_file` / etc. doesn't reset the count.

  Rationale: weaker models default to a small-batch loop (1-3 curls per
  `run_script`, fire, read, fire 2-3 more, repeat) accumulating 10-20
  turns to do work that ONE composed script plus ONE clarification
  could finish. The gate is the runtime backstop for the prompt rule
  "Three probe-batches max" in §Working with external APIs.

  Returns `:ok` or `{:rejected, {:run_script_probe_budget, reason}}`.
  """
  @spec check_run_script_probe_budget(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_run_script_probe_budget("run_script", _args, prior_messages)
      when is_list(prior_messages) do
    budget = Dmhai.Agent.AgentSettings.run_script_probe_budget()
    count  = count_run_script_calls(prior_messages)

    if count >= budget do
      reason =
        "Error: you've probed enough — #{count} `run_script` call#{if count == 1, do: "", else: "s"} " <>
          "already done on this chain. You've got ONLY one more chance: either combine everything " <>
          "you still want to do into ONE single script (chain values with bash variables — " <>
          "`X=$(curl ...); Y=$(echo \"$X\" | jq ...); curl ... -d \"$Y\"`), OR ask the user the " <>
          "specific question your probes can't answer (which scope to widen, which alternative " <>
          "to accept, which existing field to use). After that, no more probing — text only."

      Logger.warning("[Police] REJECTED run_script_probe_budget: chain count=#{count}")
      Dmhai.SysLog.log("[POLICE] REJECTED run_script_probe_budget: chain count=#{count}")
      {:rejected, {:run_script_probe_budget, reason}}
    else
      :ok
    end
  end

  def check_run_script_probe_budget(_, _, _), do: :ok

  # Count assistant tool_calls named "run_script" across the prior-messages
  # accumulator. Both atom-key and string-key shapes accepted (the chain
  # loop builds atom-key maps; LLM responses replayed from history use
  # string keys). Intra-batch counting is automatic — each tool_call in
  # one assistant message contributes independently.
  defp count_run_script_calls(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs)         -> tcs
      %{"role" => "assistant", "tool_calls" => tcs} when is_list(tcs) -> tcs
      _ -> []
    end)
    |> Enum.count(fn tc ->
      case tc do
        %{function: %{name: "run_script"}}                  -> true
        %{"function" => %{"name" => "run_script"}}          -> true
        _                                                    -> false
      end
    end)
  end

  # Walk `prior_messages` newest-to-oldest, find the last assistant-role
  # message that carries a non-empty `tool_calls` list, return the name
  # of its LAST tool_call. The "last call in the last batch" is the
  # correct signal for consecutivity — task-bookkeeping calls
  # (create_task / pickup_task / complete_task / pause_task /
  # cancel_task) emitted between web_searches are still tool calls
  # and break the sequence by design (if the model is transitioning
  # tasks, it's probably a different search intent).
  defp last_tool_call_name(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      role  = msg[:role] || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      if role == "assistant" and is_list(calls) and calls != [] do
        # Skip Police-rejected calls — they never actually ran, so
        # they shouldn't count as "the prior call" for chaining
        # checks like consecutive_web_search.
        live_calls = Enum.reject(calls, &(&1["_rejected"] || &1[:_rejected] || false))

        case List.last(live_calls) do
          nil -> nil
          last_call ->
            fn_map = last_call["function"] || last_call[:function] || %{}
            fn_map["name"] || fn_map[:name]
        end
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
