# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.Registry do
  require Logger

  @moduledoc """
  Lists tool definitions and dispatches execute calls by name.

  The catalog has two layers:

    * **Built-in tools** — the static `@tools` list below. Same set
      for every user, every session, every turn.
    * **MCP-attached tools** — per-user authorization, **per-task
      attachment**. Sourced from
      `Dmhai.MCP.Registry.tools_for_task/2`: returns the tools of
      services the current anchor task has bound. Empty when no
      anchor task or no attachments. Names are namespaced
      `<alias>.<tool>`; dispatch routes them to
      `Dmhai.MCP.Client.call_tool/4`.

  Functions come in task-aware and unaware overloads. The unaware
  ones return only built-ins (used by the static HTTP catalog and
  by the assistant-text guard, which can't see ctx). The task-aware
  ones consult the active task's attachments and are used by the
  agent's per-turn tool dispatch.
  """

  @tools [
    Dmhai.Tools.CreateTask,
    Dmhai.Tools.PickupTask,
    Dmhai.Tools.CompleteTask,
    Dmhai.Tools.PauseTask,
    Dmhai.Tools.CancelTask,
    Dmhai.Tools.FetchTask,
    Dmhai.Tools.WebSearch,
    Dmhai.Tools.WebFetch,
    Dmhai.Tools.RunScript,
    Dmhai.Tools.ReadFile,
    Dmhai.Tools.WriteFile,
    Dmhai.Tools.Calculator,
    Dmhai.Tools.ExtractContent,
    Dmhai.Tools.SpawnTask,
    Dmhai.Tools.SaveCreds,
    Dmhai.Tools.LookupCreds,
    Dmhai.Tools.DeleteCreds,
    Dmhai.Tools.RequestInput,
    Dmhai.Tools.ConnectService,
    Dmhai.Tools.ProvisionSshIdentity
  ]

  # Tools whose semantics are inherently tied to managing/closing the
  # active anchor task (or asking the user for input that progresses
  # it). They never need a `relevant` self-attestation because the gate
  # they would otherwise feed (`Police.check_relevance/3`) is meaningless
  # for them — there's no "unrelated to anchor" interpretation. The
  # schema injection in `with_relevance_field/1` skips these, and
  # `Police` skips them in its gate.
  @relevance_exempt MapSet.new(~w(
    complete_task cancel_task pause_task pickup_task fetch_task request_input
  ))

  @doc """
  True when `name` is exempt from the anchor-relevance attestation
  rule. Police consults this before enforcing the gate; the schema
  injection consults it before adding the `relevant` field. Single
  source of truth.
  """
  @spec relevance_exempt?(String.t()) :: boolean()
  def relevance_exempt?(name) when is_binary(name), do: MapSet.member?(@relevance_exempt, name)
  def relevance_exempt?(_), do: false

  # ── definitions ───────────────────────────────────────────────────────

  @doc "Built-in tool definitions only. For static catalog endpoints."
  @spec all_definitions() :: [map()]
  def all_definitions do
    @tools |> Enum.map(& &1.definition()) |> Enum.map(&with_relevance_field/1)
  end

  @doc """
  Built-in tool definitions plus the MCP tools attached to the
  current anchor task. `task_id` is the internal task UUID
  (`Dmhai.Agent.Tasks.resolve_num/2`); `nil` means no anchor task,
  in which case only built-ins are returned.
  """
  @spec all_definitions(String.t() | nil, String.t() | nil) :: [map()]
  def all_definitions(nil, _task_id), do: all_definitions()

  def all_definitions(user_id, task_id) when is_binary(user_id) do
    all_definitions() ++ Enum.map(mcp_definitions(user_id, task_id), &with_relevance_field/1)
  end

  defp mcp_definitions(user_id, task_id) do
    user_id
    |> Dmhai.MCP.Registry.tools_for_task(task_id)
    |> Enum.map(fn t ->
      %{
        name:        t.name,
        description: t.description,
        parameters:  t.inputSchema || %{type: "object", properties: %{}}
      }
    end)
  end

  # Inject the `relevant` boolean as a required parameter on every
  # non-exempt tool. Police's anchor-relevance gate
  # (`check_relevance/3`) reads it; tool implementations don't.
  #
  # Built-in tool definitions use atom keys; MCP `inputSchema` arrives
  # as a JSON-decoded map with string keys. Both are accepted on read;
  # the rewritten map normalises to atom keys so Police's schema check
  # (`schema[:parameters][:properties]`) works uniformly afterwards.
  defp with_relevance_field(%{name: name} = def_) when is_binary(name) do
    if relevance_exempt?(name) do
      def_
    else
      params_raw = Map.get(def_, :parameters) || %{}

      props    = Map.get(params_raw, :properties) || Map.get(params_raw, "properties") || %{}
      required = Map.get(params_raw, :required)   || Map.get(params_raw, "required")   || []
      type_    = Map.get(params_raw, :type)       || Map.get(params_raw, "type")       || "object"

      new_props =
        Map.put(props, :relevant, %{
          type: "boolean",
          description:
            "Set true ONLY when this call advances the ACTIVE anchor task's spec. " <>
              "Set false when you'd be using this call for something unrelated to the anchor — " <>
              "the runtime then rejects the call and prompts you to confirm the pivot with the user " <>
              "first (or `pause_task` the anchor before continuing). When no anchor task exists this " <>
              "field is ignored; pass true."
        })

      required_strs = Enum.map(required, &to_string/1)
      new_required  = if "relevant" in required_strs, do: required_strs, else: required_strs ++ ["relevant"]

      new_params =
        params_raw
        |> Map.drop(["properties", "required", "type"])
        |> Map.put(:properties, new_props)
        |> Map.put(:required, new_required)
        |> Map.put(:type, type_)

      Map.put(def_, :parameters, new_params)
    end
  end

  defp with_relevance_field(def_), do: def_

  # ── names ─────────────────────────────────────────────────────────────

  @doc "Built-in tool names only."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1.name())

  @doc "Built-in plus MCP tool names attached to the given task."
  @spec names(String.t() | nil, String.t() | nil) :: [String.t()]
  def names(nil, _task_id), do: names()

  def names(user_id, task_id) when is_binary(user_id) do
    names() ++ Enum.map(Dmhai.MCP.Registry.tools_for_task(user_id, task_id), & &1.name)
  end

  # ── known? ────────────────────────────────────────────────────────────

  @doc "True if `name` is a built-in tool."
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name), do: name in names()
  def known?(_), do: false

  @doc "True if `name` is a built-in or attached to the given anchor task."
  @spec known?(String.t(), String.t() | nil, String.t() | nil) :: boolean()
  def known?(name, nil, _), do: known?(name)

  def known?(name, user_id, task_id) when is_binary(name) and is_binary(user_id) do
    if name in names() do
      true
    else
      Enum.any?(Dmhai.MCP.Registry.tools_for_task(user_id, task_id), &(&1.name == name))
    end
  end

  def known?(_, _, _), do: false

  # ── definition_for ────────────────────────────────────────────────────

  @doc """
  Return the function-calling definition for `name`, or `nil` when
  unknown. Used by Police's schema-validation check. Goes through
  `with_relevance_field/1` so Police sees the same shape the LLM did,
  including the injected `relevant` field on non-exempt tools.
  """
  @spec definition_for(String.t()) :: map() | nil
  def definition_for(name) when is_binary(name) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil  -> nil
      tool -> with_relevance_field(tool.definition())
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
        case Enum.find(Dmhai.MCP.Registry.tools_for_task(user_id, task_id), &(&1.name == name)) do
          nil -> nil
          t ->
            with_relevance_field(%{
              name:        t.name,
              description: t.description,
              parameters:  t.inputSchema || %{type: "object", properties: %{}}
            })
        end
    end
  end

  def definition_for(_, _, _), do: nil

  # ── execute ───────────────────────────────────────────────────────────

  @doc """
  Dispatch a tool invocation. `ctx` carries `:user_id` so namespaced
  MCP tool names (`<alias>.<tool>`) route to
  `Dmhai.MCP.Client.call_tool/4`. Built-ins fall through to their
  module's `execute/2`. Returns `{:ok, result}` or `{:error, reason}`.

  Tool implementations are isolated by `try/rescue` — any raised
  exception is reported back as `{:error, reason}` so a tool fault
  cannot kill the chain task or leave its progress row hanging.
  """
  def execute(name, args, ctx) when is_binary(name) do
    do_execute(name, args, ctx)
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
        case Enum.find(@tools, &(&1.name() == name)) do
          nil ->
            user_id = Map.get(ctx, :user_id) || Map.get(ctx, "user_id")
            if is_binary(user_id) do
              Dmhai.MCP.Client.call_tool(user_id, alias_, tool_name, args || %{})
            else
              {:error, "MCP tool dispatch requires user_id in context"}
            end

          tool ->
            tool.execute(args, ctx)
        end

      _ ->
        case Enum.find(@tools, &(&1.name() == name)) do
          nil  -> {:error, "Unknown tool: #{inspect(name)}"}
          tool -> tool.execute(args, ctx)
        end
    end
  end
end
