# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Registry do
  require Logger

  @moduledoc """
  Lists tool definitions and dispatches execute calls by name.

  The catalog has two layers:

    * **Built-in tools** — the static `@tools` list below. Same set
      for every user, every session, every turn.
    * **MCP-attached tools** — per-user authorization, **per-task
      attachment**. Sourced from
      `DmhAi.MCP.Registry.tools_for_task/2`: returns the tools of
      services the current anchor task has bound. Empty when no
      anchor task or no attachments. Names are namespaced
      `<alias>.<tool>`; dispatch routes them to
      `DmhAi.MCP.Client.call_tool/4`.

  Functions come in task-aware and unaware overloads. The unaware
  ones return only built-ins (used by the static HTTP catalog and
  by the assistant-text guard, which can't see ctx). The task-aware
  ones consult the active task's attachments and are used by the
  agent's per-turn tool dispatch.
  """

  @tools [
    DmhAi.Tools.CreateTask,
    DmhAi.Tools.PickupTask,
    DmhAi.Tools.CompleteTask,
    DmhAi.Tools.PauseTask,
    DmhAi.Tools.CancelTask,
    DmhAi.Tools.FetchTask,
    DmhAi.Tools.WebSearch,
    DmhAi.Tools.WebFetch,
    DmhAi.Tools.WebCrawl,
    DmhAi.Tools.RunScript,
    DmhAi.Tools.ReadFile,
    DmhAi.Tools.WriteFile,
    DmhAi.Tools.Calculator,
    DmhAi.Tools.ExtractContent,
    DmhAi.Tools.SpawnTask,
    DmhAi.Tools.SaveCreds,
    DmhAi.Tools.LookupCreds,
    DmhAi.Tools.DeleteCreds,
    DmhAi.Tools.RequestInput,
    DmhAi.Tools.ConnectMcp,
    DmhAi.Tools.ProvisionSshIdentity,
    DmhAi.Tools.FetchIndex,
    DmhAi.Tools.FetchMemo,
    DmhAi.Tools.AuthorizeService,
    DmhAi.Tools.MkDownloadLink,
    DmhAi.Tools.UpsertWorkflow,
    DmhAi.Tools.ArmWorkflow,
    DmhAi.Tools.DisarmWorkflow,
    DmhAi.Tools.InvokeWorkflow
  ]

  # Save tools — runtime-only (invoked by `/index` and `/memo` commands
  # via VectorDB.ingest, NOT by the LLM). They're known to the
  # dispatcher (see `all_local_tools/0`) so direct calls work, but
  # never advertised in any LLM catalog. This eliminates the risk of
  # a hallucinated write from the model. See specs/commands.md.
  @save_only_tools [
    DmhAi.Tools.SaveMemo
  ]

  # ── definitions ───────────────────────────────────────────────────────

  @doc "Built-in tool definitions only. For static catalog endpoints."
  @spec all_definitions() :: [map()]
  def all_definitions, do: Enum.map(@tools, & &1.definition())

  @doc """
  Built-in tool definitions plus the MCP tools attached to the
  current anchor task. `task_id` is the internal task UUID
  (`DmhAi.Agent.Tasks.resolve_num/2`); `nil` means no anchor task,
  in which case only built-ins are returned.

  `fetch_index` is dropped from the returned list when the global
  index has no chunks yet — saves the model from being tempted to
  call it when there's nothing to look up, and saves the schema's
  worth of tokens on every turn until the operator `/index`s
  something.
  """
  @spec all_definitions(String.t() | nil, String.t() | nil) :: [map()]
  def all_definitions(nil, _task_id), do: all_definitions() |> drop_empty_wiki(default_org_id())

  def all_definitions(user_id, task_id) when is_binary(user_id) do
    org_id = org_for_user(user_id)
    (all_definitions() |> drop_empty_wiki(org_id)) ++ mcp_definitions(user_id, task_id)
  end

  defp drop_empty_wiki(defs, org_id) do
    if wiki_empty?(org_id) do
      Enum.reject(defs, fn d -> d.name == "fetch_index" end)
    else
      defs
    end
  end

  defp wiki_empty?(org_id) do
    case DmhAi.VectorDB.count(:knowledge, org_id) do
      {:ok, 0} -> true
      _        -> false
    end
  rescue
    _ -> false
  end

  defp org_for_user(user_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]

    case query!(DmhAi.Repo, "SELECT org_id FROM users WHERE id=?", [user_id]).rows do
      [[org_id]] when is_binary(org_id) -> org_id
      _ -> default_org_id()
    end
  rescue
    _ -> default_org_id()
  end

  defp default_org_id, do: DmhAi.Constants.default_org_id()

  defp mcp_definitions(user_id, task_id) do
    user_id
    |> DmhAi.MCP.Registry.tools_for_task(task_id)
    |> Enum.map(fn t ->
      %{
        name:        t.name,
        description: t.description,
        parameters:  t.inputSchema || %{type: "object", properties: %{}}
      }
    end)
  end

  # ── names ─────────────────────────────────────────────────────────────

  @doc "Built-in tool names only."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1.name())

  # Includes save-only tools — used by `known?` and `execute` so the
  # runtime command path (`/index`, `/memo`) can dispatch SaveWiki /
  # SaveMemo even though they're not in any LLM catalog.
  defp all_local_tools, do: @tools ++ @save_only_tools

  @doc "Built-in plus MCP tool names attached to the given task."
  @spec names(String.t() | nil, String.t() | nil) :: [String.t()]
  def names(nil, _task_id), do: names()

  def names(user_id, task_id) when is_binary(user_id) do
    names() ++
      Enum.map(DmhAi.MCP.Registry.tools_for_task(user_id, task_id), & &1.name) ++
      connector_function_names()
  end

  # Primitive 0.3 — Universal-Region connector functions registered with
  # the Dispatcher are valid tool names regardless of task scope (no
  # tools_for_task gating; the connector catalog is org-wide). Joins
  # the connector slug + function path with a dot:
  # `hubspot.contact.find`, `hubspot.deal.create`, etc.
  defp connector_function_names do
    Enum.flat_map(DmhAi.Tools.Dispatcher.connectors(), fn slug ->
      case DmhAi.Tools.Dispatcher.lookup(slug) do
        {:ok, %{manifest: %{functions: functions}}} ->
          Enum.map(functions, fn {path, _} -> slug <> "." <> path end)

        _ ->
          []
      end
    end)
  end

  defp connector_function?(name) do
    case String.split(name, ".", parts: 2) do
      [slug, path] when slug != "" and path != "" ->
        case DmhAi.Tools.Dispatcher.lookup(slug) do
          {:ok, %{manifest: %{functions: functions}}} -> Map.has_key?(functions, path)
          _ -> false
        end

      _ ->
        false
    end
  end

  # ── known? ────────────────────────────────────────────────────────────

  @doc "True if `name` is a built-in OR memo tool."
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name),
    do: Enum.any?(all_local_tools(), &(&1.name() == name))
  def known?(_), do: false

  @doc "True if `name` is a built-in or attached to the given anchor task."
  @spec known?(String.t(), String.t() | nil, String.t() | nil) :: boolean()
  def known?(name, nil, _), do: known?(name)

  def known?(name, user_id, task_id) when is_binary(name) and is_binary(user_id) do
    # `known?/1` already checks built-ins + memo tools; this branch
    # adds MCP tools attached to the current anchor task PLUS
    # Universal-Region connector functions registered with the Dispatcher.
    cond do
      known?(name) ->
        true

      Enum.any?(DmhAi.MCP.Registry.tools_for_task(user_id, task_id), &(&1.name == name)) ->
        true

      connector_function?(name) ->
        true

      true ->
        false
    end
  end

  def known?(_, _, _), do: false

  # ── definition_for ────────────────────────────────────────────────────

  @doc """
  Return the function-calling definition for `name`, or `nil` when
  unknown. Used by Police's schema-validation check.
  """
  @spec definition_for(String.t()) :: map() | nil
  def definition_for(name) when is_binary(name) do
    case Enum.find(all_local_tools(), &(&1.name() == name)) do
      nil  -> nil
      tool -> tool.definition()
    end
  end

  def definition_for(_), do: nil

  @doc """
  Task-aware variant. When `name` is a namespaced MCP tool attached
  to the task, returns a definition synthesized from the cached
  catalog so Police can inspect schema fields the same way as for
  built-ins.
  """
  @spec definition_for(String.t(), String.t() | nil, String.t() | nil) :: map() | nil
  def definition_for(name, nil, _), do: definition_for(name)

  def definition_for(name, user_id, task_id) when is_binary(name) and is_binary(user_id) do
    case definition_for(name) do
      %{} = def_ ->
        def_

      nil ->
        case Enum.find(DmhAi.MCP.Registry.tools_for_task(user_id, task_id), &(&1.name == name)) do
          nil -> nil
          t ->
            %{
              name:        t.name,
              description: t.description,
              parameters:  t.inputSchema || %{type: "object", properties: %{}}
            }
        end
    end
  end

  def definition_for(_, _, _), do: nil

  # ── execute ───────────────────────────────────────────────────────────

  @doc """
  Dispatch a tool invocation. `ctx` carries `:user_id` so namespaced
  MCP tool names (`<alias>.<tool>`) route to
  `DmhAi.MCP.Client.call_tool/4`. Built-ins fall through to their
  module's `execute/2`. Returns `{:ok, result}` or `{:error, reason}`.

  Tool implementations are isolated by `try/rescue` — any raised
  exception is reported back as `{:error, reason}` so a tool fault
  cannot kill the chain task or leave its progress row hanging.
  """
  def execute(name, args, ctx) when is_binary(name) do
    # Test hook: Application.put_env(:dmh_ai, :__tool_execute_stub__, fn name, args, ctx -> ... end)
    # Stub must return {:ok, result} | {:error, reason} — same shape as the real path.
    # When a stub returns `:passthrough`, dispatch falls through to the real tool — lets
    # a test fake just one tool (e.g. run_script) while letting bookkeeping functions
    # (create_task / pickup_task) hit the real Registry path.
    case Application.get_env(:dmh_ai, :__tool_execute_stub__) do
      nil ->
        do_execute(name, args, ctx)

      stub when is_function(stub, 3) ->
        case stub.(name, args, ctx) do
          :passthrough -> do_execute(name, args, ctx)
          other        -> other
        end
    end
  rescue
    e ->
      Logger.error("[Tools.Registry] tool=#{name} raised: #{Exception.format(:error, e, __STACKTRACE__)}")
      {:error, "tool '#{name}' raised an exception: #{Exception.message(e)}"}
  end

  def execute(name, _args, _ctx), do: {:error, "Tool name must be a string, got: #{inspect(name)}"}

  defp do_execute(name, args, ctx) do
    case String.split(name, ".", parts: 2) do
      [alias_, tool_name] when alias_ != "" and tool_name != "" ->
        # Could collide with a built-in carrying a literal "." in its
        # name — none currently do, but defensively check first.
        case Enum.find(all_local_tools(), &(&1.name() == name)) do
          nil ->
            # Primitive 0.3 — if the namespace prefix is a registered
            # connector, route through the Dispatcher (which enforces
            # the 4 rules: permission · write-requires-task ·
            # idempotency_key · per-user credentials). Otherwise fall
            # back to the legacy MCP client path used by the
            # pre-Phase-C tools/list flow.
            case DmhAi.Tools.Dispatcher.lookup(alias_) do
              {:ok, _entry} ->
                DmhAi.Tools.Dispatcher.call(name, args || %{}, ctx)

              :not_found ->
                user_id = Map.get(ctx, :user_id) || Map.get(ctx, "user_id")
                if is_binary(user_id) do
                  DmhAi.MCP.Client.call_tool(user_id, alias_, tool_name, args || %{})
                else
                  {:error, "MCP tool dispatch requires user_id in context"}
                end
            end

          tool ->
            tool.execute(args, ctx)
        end

      _ ->
        case Enum.find(all_local_tools(), &(&1.name() == name)) do
          nil  -> {:error, "Unknown tool: #{inspect(name)}"}
          tool -> tool.execute(args, ctx)
        end
    end
  end
end
