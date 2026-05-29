# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Registry do
  require Logger

  @moduledoc """
  Lists tool definitions and dispatches execute calls by name.

  The catalog has two layers:

    * **Built-in tools** — sourced from `DmhAi.Tools.Profiles`,
      partitioned into `:core` / `:auth` / `:workflows`. Each LLM
      turn ships only `:core` plus whatever profiles the chain has
      activated; the static HTTP catalog ships every built-in flat
      for FE display.
    * **MCP-attached tools** — per-user authorization, **per-session
      attachment**. Sourced from
      `DmhAi.MCP.Registry.tools_for_session/2`: returns the tools of
      services the current session has bound. Empty when no
      attachments. Names are namespaced `<alias>.<tool>`; dispatch
      routes them to `DmhAi.MCP.Client.call_tool/4`. Grouped into
      `:connector:<slug>` synthetic profiles by the runtime.

  Functions come in three shapes:
    - `/0` — flat list of every built-in (static HTTP catalog).
    - `/3` taking `(user_id, session_id, active_profiles)` — what
      the per-turn LLM call ships; the active set is read from
      `session.context.active_profiles` by the caller.

  See `arch_wiki/dmh_ai/architecture.md` §Execution tools / §Tool
  profiles.
  """

  alias DmhAi.Tools.Profiles

  # Flat list of every built-in tool module, composed from the
  # profile registry at compile time. This is the catalog the
  # static HTTP endpoint + `known?` / `execute` / `definition_for`
  # paths use; per-turn LLM calls filter further through the
  # active profile set.
  @tools Profiles.all_built_in_modules()

  # Save tools — runtime-only (invoked by `/index` and `/memo` commands
  # via VectorDB.ingest, NOT by the LLM). They're known to the
  # dispatcher (see `all_local_tools/0`) so direct calls work, but
  # never advertised in any LLM catalog. This eliminates the risk of
  # a hallucinated write from the model. See specs/commands.md.
  @save_only_tools [
    DmhAi.Tools.SaveMemo
  ]

  # ── definitions ───────────────────────────────────────────────────────

  @doc """
  Primitive 0.10 — list every registered internal tool module.
  Consumed by `Tools.Catalog.list/1` to enumerate the internal
  category alongside connector functions and synthetics.
  """
  @spec tool_modules() :: [module()]
  def tool_modules, do: @tools

  @doc "Built-in tool definitions only. For static catalog endpoints."
  @spec all_definitions() :: [map()]
  def all_definitions, do: Enum.map(@tools, & &1.definition())

  @doc """
  Tool definitions visible on the current LLM turn: `:core` plus
  every profile in `active_profiles`, plus the MCP verbs scoped to
  whichever `connector:<slug>` entries the active set includes.

  `active_profiles` is the list of profile-name strings read from
  `session.context.active_profiles` — the caller (`Agent.UserAgent`)
  resolves it once per turn and passes it in. `:core` is implicit;
  passing it explicitly is harmless.

  `fetch_index` is dropped from the returned list when the global
  index has no chunks yet — saves the model from being tempted to
  call it when there's nothing to look up, and saves the schema's
  worth of tokens on every turn until the operator `/index`s
  something.
  """
  @spec all_definitions(String.t() | nil, String.t() | nil, [String.t()]) :: [map()]
  def all_definitions(nil, _session_id, _active_profiles) do
    Enum.map(Profiles.core_modules(), & &1.definition())
    |> drop_empty_wiki(default_org_id())
  end

  def all_definitions(user_id, session_id, active_profiles)
      when is_binary(user_id) and is_list(active_profiles) do
    org_id = org_for_user(user_id)

    built_in =
      core_and_profile_modules(active_profiles)
      |> Enum.map(& &1.definition())
      |> drop_empty_wiki(org_id)

    built_in ++ connector_definitions(active_profiles, user_id, session_id)
  end

  # Modules from :core plus every named built-in profile in
  # `active_profiles`. Unknown / connector entries are filtered
  # out — connector profiles contribute via
  # `connector_definitions/3`, not built-ins.
  defp core_and_profile_modules(active_profiles) do
    extras =
      active_profiles
      |> Enum.flat_map(fn
        "auth"      -> Profiles.built_in_modules_for(:auth)
        "workflows" -> Profiles.built_in_modules_for(:workflows)
        _           -> []
      end)

    Enum.uniq(Profiles.core_modules() ++ extras)
  end

  # Connector verbs to include for every `connector:<slug>` in the
  # active set. Pulls from both the per-session MCP attachment
  # (`MCP.Registry.tools_for_session`) and the Universal-Region
  # Dispatcher manifest, via `Profiles.connector_definitions_for`.
  defp connector_definitions(active_profiles, user_id, session_id) do
    Enum.flat_map(active_profiles, fn
      "connector:" <> slug ->
        Profiles.connector_definitions_for(slug, user_id, session_id)

      _ ->
        []
    end)
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

  # ── names ─────────────────────────────────────────────────────────────

  @doc "Built-in tool names only."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1.name())

  # Includes save-only tools — used by `known?` and `execute` so the
  # runtime command path (`/index`, `/memo`) can dispatch SaveWiki /
  # SaveMemo even though they're not in any LLM catalog.
  defp all_local_tools, do: @tools ++ @save_only_tools

  @doc "Built-in plus MCP tool names attached to the given session."
  @spec names(String.t() | nil) :: [String.t()]
  def names(nil), do: names()

  def names(user_id) when is_binary(user_id) do
    names() ++ connector_function_names()
  end

  @doc "Built-in plus MCP tool names attached to the given session."
  @spec names(String.t() | nil, String.t() | nil) :: [String.t()]
  def names(nil, _session_id), do: names()

  def names(user_id, session_id) when is_binary(user_id) do
    names() ++
      Enum.map(DmhAi.MCP.Registry.tools_for_session(user_id, session_id), & &1.name) ++
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

  @doc "True if `name` is a built-in or attached to the given session."
  @spec known?(String.t(), String.t() | nil) :: boolean()
  def known?(name, nil), do: known?(name)

  def known?(name, user_id) when is_binary(name) and is_binary(user_id) do
    # `known?/1` already checks built-ins + memo tools; this branch
    # adds Universal-Region connector functions registered with the
    # Dispatcher.
    cond do
      known?(name) ->
        true

      connector_function?(name) ->
        true

      true ->
        false
    end
  end

  def known?(_, _), do: false

  @doc "True if `name` is a built-in or attached to the given session."
  @spec known?(String.t(), String.t() | nil, String.t() | nil) :: boolean()
  def known?(name, nil, _), do: known?(name)

  def known?(name, user_id, session_id) when is_binary(name) and is_binary(user_id) do
    cond do
      known?(name) ->
        true

      Enum.any?(DmhAi.MCP.Registry.tools_for_session(user_id, session_id), &(&1.name == name)) ->
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
  Session-aware variant. When `name` is a namespaced MCP tool attached
  to the session, returns a definition synthesized from the cached
  catalog so Police can inspect schema fields the same way as for
  built-ins.
  """
  @spec definition_for(String.t(), String.t() | nil, String.t() | nil) :: map() | nil
  def definition_for(name, nil, _), do: definition_for(name)

  def definition_for(name, user_id, session_id) when is_binary(name) and is_binary(user_id) do
    case definition_for(name) do
      %{} = def_ ->
        def_

      nil ->
        case Enum.find(DmhAi.MCP.Registry.tools_for_session(user_id, session_id), &(&1.name == name)) do
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
    # a test fake just one tool (e.g. run_script) while letting every other tool hit
    # the real Registry path.
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
