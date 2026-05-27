# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police do
  @moduledoc """
  Tool-call gate. The model has broad tool freedom, so Police only
  intervenes where the runtime MUST enforce an invariant (sandbox
  escape, malformed call, duplicate calls within one chain, repeated
  errors, etc.).

  Returns `:ok` to let the tool call proceed, or `{:rejected, reason}`
  to surface an error back to the model (the runtime turns this into a
  tool-result with an error message that the model can correct on its
  next turn).
  """

  require Logger

  @read_path_tools ["read_file", "list_dir", "extract_content"]
  @write_path_tools ["write_file"]
  @shell_tools ["run_script"]

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
    case DmhAi.Tools.Registry.definition_for(name) do
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
          DmhAi.SysLog.log("[POLICE] REJECTED tool_call_schema: tool=#{name} missing=#{inspect(missing)} type_errs=#{inspect(type_errs)}")
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

  defp decode_or_empty(binary) do
    case Jason.decode(binary) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  @doc """
  Per-tool-call gate: reject when the emitted `name` doesn't correspond to
  a registered tool. Guards against model output malformation where the
  model stuffs garbled or hallucinated content into `function.name`.

  The rejection message enumerates the valid tool names so the next-turn
  corrective tool_result gives the model the concrete vocabulary to
  recover with.
  """
  @spec check_tool_name_validity(String.t()) :: :ok | {:rejected, {atom(), String.t()}}
  def check_tool_name_validity(name) when is_binary(name), do: check_tool_name_validity(name, nil)

  def check_tool_name_validity(_),
    do: {:rejected, {:unknown_tool_name, "Error: tool_call `function.name` must be a string."}}

  @doc """
  Includes the MCP tools attached to the user's current session in the
  validity check so `<alias>.<tool>` names registered via `connect_mcp`
  are accepted.
  """
  @spec check_tool_name_validity(String.t(), String.t() | nil) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_tool_name_validity(name, user_id) when is_binary(name) do
    if DmhAi.Tools.Registry.known?(name, user_id) do
      :ok
    else
      name_preview = String.slice(name, 0, 120)

      valid_names = DmhAi.Tools.Registry.names(user_id)

      reason = unknown_tool_name_reason(name_preview, valid_names)

      Logger.warning("[Police] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      DmhAi.SysLog.log("[POLICE] REJECTED unknown_tool_name: name=#{inspect(String.slice(name, 0, 200))}")
      {:rejected, {:unknown_tool_name, reason}}
    end
  end

  def check_tool_name_validity(_, _),
    do: {:rejected, {:unknown_tool_name, "Error: tool_call `function.name` must be a string."}}

  # MCP-attached tools live under `<alias>.<tool>`. When a name has
  # that shape but isn't in the catalog, the most likely cause is
  # the model is reaching for a service that hasn't been attached
  # yet. Lead with that hint instead of the bare tool list.
  defp unknown_tool_name_reason(name_preview, valid_names) do
    case String.split(name_preview, ".", parts: 2) do
      [alias_, _tool] when alias_ != "" ->
        "Error: `#{name_preview}` is not currently attached. Namespaced tools " <>
          "(`<alias>.<tool>`) come from external services attached via `connect_mcp`. " <>
          "If you want to use `#{alias_}` here, call `connect_mcp` first with the server's " <>
          "URL.\n\n" <>
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
  `"web_search"` or `"run_script(...)"` — so the chain ends without
  actually calling the tool.

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
    names = DmhAi.Tools.Registry.names()

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
      trimmed == "" ->
        # Model returned no text AND no tool calls. Same reject-and-
        # nudge mechanic as other Police rejections — ask the model
        # itself to surface root cause + options instead of silently
        # ending the chain. The 3-strike circuit-breaker in
        # user_agent.ex caps runaway empty-loops.
        reason =
          "Your previous response was empty — no text and no tool calls. " <>
            "Reply now with: (1) the most likely reason on your side that you " <>
            "produced no output (conflicting context, ambiguous request, " <>
            "missing information, hit a token / budget limit, an internal " <>
            "constraint, etc.); and (2) two or three concrete options the " <>
            "user can choose from to move forward. Speak in the user's " <>
            "language. Do not return empty again."

        Logger.warning("[Police] REJECTED empty_response")
        DmhAi.SysLog.log("[POLICE] REJECTED empty_response")
        {:rejected, {:empty_response, reason}}

      exact_match or call_shape_match ->
        reason =
          "Your response was the text `#{String.slice(trimmed, 0, 120)}` which " <>
            "looks like a tool invocation emitted as plain text. Tool actions " <>
            "must live in the `tool_calls` array of your response, not in " <>
            "message content. If you meant to call a tool, retry with the " <>
            "proper tool_call structure. Otherwise, write a real reply."

        Logger.warning("[Police] REJECTED tool_as_plain_text: #{inspect(String.slice(trimmed, 0, 200))}")
        DmhAi.SysLog.log("[POLICE] REJECTED tool_as_plain_text: #{inspect(String.slice(trimmed, 0, 200))}")
        {:rejected, {:tool_as_plain_text, reason}}

      bookkeeping_match ->
        reason =
          "Your response contains a pseudo-tool-call annotation of the " <>
            "form `[used: ...]` / `[via: ...]` / `[called: ...]` / " <>
            "`[tool: ...]`. These are text decorations — the tool was " <>
            "NOT actually called, and the user would see this junk in " <>
            "their chat. The user-facing reply must be plain prose in " <>
            "the user's language, with NO `[...]` tool annotations and " <>
            "NO tool-name mentions."

        Logger.warning("[Police] REJECTED assistant_text_bookkeeping: #{inspect(String.slice(trimmed, 0, 200))}")
        DmhAi.SysLog.log("[POLICE] REJECTED assistant_text_bookkeeping: #{inspect(String.slice(trimmed, 0, 200))}")
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
  `session_chain_loop` across tool rounds. Every assistant-role message
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
          "You must call `extract_content` once per attachment, passing the " <>
          "workspace path shown above — the user re-attached them because " <>
          "they want another look. Retry the turn: call `extract_content` " <>
          "per attachment, then produce your final answer."

      Logger.warning("[Police] REJECTED fresh_attachments_unread: missed=#{inspect(missed)}")
      DmhAi.SysLog.log("[POLICE] REJECTED fresh_attachments_unread: missed=#{inspect(missed)}")
      {:rejected, {:fresh_attachments_unread, reason}}
    end
  end
  def check_fresh_attachments_read(_, _), do: :ok

  @doc """
  Per-tool-call gate: reject when the same `(tool_name, significant_arg)`
  combination has already been invoked earlier in THIS chain. Prevents
  the "model re-extracts the same PDF twice" misbehaviour that appears
  on weaker models.

  `prior_messages` is the in-chain message accumulator — a list containing
  every assistant-role message with `tool_calls` emitted earlier in this
  chain (either in a prior turn, OR earlier in the CURRENT batch of
  tool_calls from one LLM response).

  Significance key per tool:

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
              "tool to move forward. Do not repeat yourself."

          Logger.warning(
            "[Police] REJECTED duplicate_tool_call_in_chain: tool=#{name} key=#{inspect(key)}"
          )

          DmhAi.SysLog.log(
            "[POLICE] REJECTED duplicate_tool_call_in_chain: tool=#{name} key=#{inspect(key)}"
          )

          {:rejected, {:duplicate_tool_call_in_chain, reason}}
        else
          :ok
        end
    end
  end
  def check_no_duplicate_tool_call(_, _, _), do: :ok

  @doc """
  Workflow-build continuity gate. When the model has attempted
  `upsert_workflow` earlier in the chain AND the most recent attempt
  did NOT successfully save, block any external connector tool call
  until the workflow lands.

  Background: a `request_input` issued during workflow compile is a
  pause to gather a VALUE for the IR, not a green light to run the
  underlying action. Smaller models occasionally lose the build
  context across the pause boundary and dispatch the connector
  function directly with the value the user supplied — producing a
  real side-effect (a deal, a contact, an email) instead of a saved
  workflow. This gate is the safety net for that class of failure.

  Skips when:
    * The tool isn't a connector function (`<slug>.<bare>` where
      `<slug>` is registered with `Connectors.Registry`).
    * No `upsert_workflow` attempt is recorded in `prior_messages`.
    * The most recent `upsert_workflow` tool result parses as a
      success envelope (`{name, version, url}`) — the workflow IS
      saved and the model is free to dispatch normally.
  """
  @spec check_workflow_build_continuity(String.t(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_workflow_build_continuity(name, prior_messages)
      when is_binary(name) and is_list(prior_messages) do
    if connector_function?(name) and workflow_build_pending?(prior_messages) do
      reason =
        "Error: you started a workflow build (called `upsert_workflow` earlier in this " <>
          "chain) but it hasn't saved yet. Calling `#{name}` directly would EXECUTE " <>
          "the operation in real life (create a deal, send an email, …) — not what the " <>
          "user asked for. The user asked for a workflow. Bake any new value the user " <>
          "just supplied into the IR (as a literal arg, or as a new trigger input the " <>
          "user supplies each run) and re-call `upsert_workflow`."

      Logger.warning(
        "[Police] REJECTED workflow_build_continuity: tool=#{name}"
      )

      DmhAi.SysLog.log(
        "[POLICE] REJECTED workflow_build_continuity: tool=#{name}"
      )

      {:rejected, {:workflow_build_continuity, reason}}
    else
      :ok
    end
  end

  def check_workflow_build_continuity(_, _), do: :ok

  defp connector_function?(name) do
    case String.split(name, ".", parts: 2) do
      [slug, _bare] when slug != "" ->
        not is_nil(DmhAi.Connectors.Registry.module_for_slug(slug))

      _ ->
        false
    end
  end

  # True when there's an `upsert_workflow` call in the recent
  # history AND the most-recent tool result for it wasn't a success.
  # "Success" is a tool message whose body decodes to a map
  # containing `name`, `version`, and `url` — the shape
  # `upsert_workflow` returns on a clean save.
  defp workflow_build_pending?(prior_messages) do
    prior_messages
    |> Enum.reverse()
    |> Enum.find_value(false, fn msg ->
      role    = Map.get(msg, :role)    || Map.get(msg, "role")
      name    = Map.get(msg, :name)    || Map.get(msg, "name")
      content = Map.get(msg, :content) || Map.get(msg, "content")

      if role == "tool" and name == "upsert_workflow" and is_binary(content) do
        {:found, content}
      else
        nil
      end
    end)
    |> case do
      {:found, content} -> not workflow_save_succeeded?(content)
      _ -> false
    end
  end

  defp workflow_save_succeeded?(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"name" => _, "version" => _, "url" => _}} -> true
      _ -> false
    end
  end

  defp workflow_save_succeeded?(_), do: false

  @doc """
  Detect tool-error loops: same tool returning the same error message
  twice in a row within one chain. Generic — no whitelist, no
  significance keys. Any tool whose runtime / validation produces an
  identical error twice in a row is by definition not making progress;
  Police rejects the SECOND occurrence and the existing rejection
  pipeline (nudge counter + 3-strike circuit breaker) handles
  escalation.

  Inputs:
    * `tool_name`   — the tool that just emitted `error_text`.
    * `error_text`  — the binary content of the tool result message.
                      Caller passes the raw string; Police trims +
                      compares as-is.
    * `prior_messages` — the in-chain accumulator. Police walks back
                         until it finds the previous role="tool" entry
                         whose `name == tool_name` and checks whether
                         its content equals `error_text` after trim.

  Returns `:ok` on first occurrence, `{:rejected, {:repeated_tool_error,
  reason}}` on the immediate repeat.
  """
  @spec check_repeated_tool_error(String.t(), String.t(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_repeated_tool_error(tool_name, error_text, prior_messages)
      when is_binary(tool_name) and is_binary(error_text) and is_list(prior_messages) do
    norm = String.trim(error_text)

    case prior_tool_error(tool_name, prior_messages) do
      ^norm ->
        reason =
          "Error: `#{tool_name}` just returned the IDENTICAL error to its previous " <>
            "call in this chain:\n\n#{ellipsize(norm, 400)}\n\n" <>
            "Retrying with the same shape will give the same error. STOP repeating " <>
            "and instead reply to the user with: (1) what the error actually means " <>
            "in the user's terms, (2) what you'd need from them to proceed " <>
            "(missing input, ambiguity, an external dependency, …), and (3) two " <>
            "or three concrete options they can pick from. Do NOT call `#{tool_name}` " <>
            "again until the user clarifies."

        Logger.warning(
          "[Police] REJECTED repeated_tool_error: tool=#{tool_name} text=#{inspect(String.slice(norm, 0, 120))}"
        )

        DmhAi.SysLog.log(
          "[POLICE] REJECTED repeated_tool_error: tool=#{tool_name}"
        )

        {:rejected, {:repeated_tool_error, reason}}

      _ ->
        :ok
    end
  end

  def check_repeated_tool_error(_, _, _), do: :ok

  # Walk `prior_messages` newest-first; return the trimmed content of
  # the most recent role="tool" message attributed to `tool_name`, or
  # nil if no prior tool-error from this tool exists in this chain.
  defp prior_tool_error(tool_name, messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "tool", name: ^tool_name, content: content} when is_binary(content) ->
        String.trim(content)

      %{"role" => "tool", "name" => ^tool_name, "content" => content}
      when is_binary(content) ->
        String.trim(content)

      _ ->
        nil
    end)
  end

  defp ellipsize(s, n) when byte_size(s) <= n, do: s
  defp ellipsize(s, n), do: String.slice(s, 0, n) <> "…"

  # Pick the "significant argument" that defines a duplicate. Normalised
  # forms let "Explain X" / "explain x " be treated as the same key.
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
  # "# With correct syntax").
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

  defp describe_key("extract_content"), do: "path"
  defp describe_key("web_search"),      do: "query"
  defp describe_key("run_script"),      do: "normalized script"
  defp describe_key(_),                 do: "arg"

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
          # same args is a retry — not a duplicate.
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

  @doc """
  Per-tool-call gate: reject a `web_search` call when the immediately-
  preceding tool call in this chain was ALSO `web_search`.

  Rationale: one `web_search` already fans out 2-3 parallel search
  queries in the BE (see `DmhAi.Web.Search.generate_queries`), so a
  second consecutive call is redundant — the model should either answer
  from what it already has OR reach for a DIFFERENT tool
  (`run_script` with a direct API call when the question targets a
  named service, `web_fetch` when it has a specific URL in mind).

  Alternating is fine: `web_search` → `run_script` → `web_search` is
  allowed when each step has a legitimate role. The gate only fires on
  TWO web_searches with nothing between them.
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
            "refined by what you just learned."

        Logger.warning("[Police] REJECTED consecutive_web_search")
        DmhAi.SysLog.log("[POLICE] REJECTED consecutive_web_search")
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

  Returns `:ok` or `{:rejected, {:run_script_probe_budget, reason}}`.
  """
  @spec check_run_script_probe_budget(String.t(), map(), [map()]) ::
          :ok | {:rejected, {atom(), String.t()}}
  def check_run_script_probe_budget("run_script", _args, prior_messages)
      when is_list(prior_messages) do
    budget = DmhAi.Agent.AgentSettings.run_script_probe_budget()
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
      DmhAi.SysLog.log("[POLICE] REJECTED run_script_probe_budget: chain count=#{count}")
      {:rejected, {:run_script_probe_budget, reason}}
    else
      :ok
    end
  end

  def check_run_script_probe_budget(_, _, _), do: :ok

  @doc """
  Soft post-execution nudge: when the assistant fires `run_script`
  back-to-back with the previous tool call also being `run_script`,
  return an educational note that the runtime prepends to the tool
  result. The script still runs and the model still gets its output
  — the note teaches it what a proper `run_script` looks like and
  how to recognise two distinct anti-patterns it might be falling
  into.

  Returns `nil` (no nudge) or a binary advisory the caller prepends
  to the tool result content.
  """
  @spec consecutive_run_script_advisory(String.t(), [map()]) :: String.t() | nil
  def consecutive_run_script_advisory("run_script", prior_messages)
      when is_list(prior_messages) do
    case last_tool_call_name(prior_messages) do
      "run_script" ->
        prior_count = count_run_script_calls(prior_messages)
        budget      = DmhAi.Agent.AgentSettings.run_script_probe_budget()

        if rem(prior_count, 2) != 1 do
          nil
        else
          Logger.info("[Police] NUDGE consecutive_run_script count=#{prior_count + 1}/#{budget}")
          DmhAi.SysLog.log("[POLICE] NUDGE consecutive_run_script count=#{prior_count + 1}/#{budget}")

          "[⚠ RUNTIME WARNING — Consecutive `run_script`s used. The next-after-cap is REJECTED.]\n\n" <>
          "Before probing again:\n\n" <>
          "  1. SCAN your context FIRST. Re-read prior tool results, the user's " <>
          "original ask, any docs you fetched. Most \"let me verify X\" is " <>
          "already answered above. Re-probing wastes turns — the user is " <>
          "waiting on the ANSWER, not on you re-checking known state.\n\n" <>
          "  2. You MUST COMPOSE. If you have enough to do the full operation " <>
          "in ONE multi-step script (bash-variables to chain values), stop " <>
          "probing and emit it now. Probe-then-execute should be 2 turns, not 5.\n\n" <>
          "  3. Previous script FAILED? Re-PLAN, don't re-PROBE the same shape. " <>
          "A wrong assumption + retry = same wrong answer.\n\n"
        end

      _ ->
        nil
    end
  end

  def consecutive_run_script_advisory(_, _), do: nil

  # Count assistant tool_calls named "run_script" across the prior-messages
  # accumulator. Both atom-key and string-key shapes accepted (the chain
  # loop builds atom-key maps; LLM responses replayed from history use
  # string keys).
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
  # of its LAST tool_call.
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
