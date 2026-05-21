# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Catalog do
  @moduledoc """
  Primitive 0.10 — the unified callable registry.

  Every callable in the system — internal primitives (`web_search`,
  `fetch_kb`, `compute`, `org.user.get`, `approval_request`, …),
  external connector functions (`hubspot.lead.assign`,
  `google_workspace.gmail.send`, …), and LLM synthetics
  (`llm.compose`) — is reachable through ONE module with ONE
  manifest shape:

      Tools.Catalog.lookup(name) :: {:ok, manifest()} | {:error, :unknown}
      Tools.Catalog.call(name, args, ctx) :: {:ok, emit} | {:error, envelope}
      Tools.Catalog.list(ctx) :: [manifest()]

  ## The genericity contract (G1–G5)

  Compiler, executor, dispatcher, and the MCP `tools/list` endpoint
  all read from this module. The SINGLE `case category` branch in
  the whole codebase outside this module is the executor's
  LLM-synthetic carve-out — every other consumer goes through
  `call/3`.

  ## Manifest shape

      %{
        name:                 "fetch_kb",            # canonical, namespaced
        category:             :internal | :external_connector | :llm_synthetic,
        args_schema:          %{...},                 # JSON-schema-shape map
        emits_schema:         %{...},                 # what call/3 returns on success
        permission:           :read_kb,               # input to Permissions.can?/3
        permission_target_fn: fn args, ctx -> "kb:*" end,
        callable_from:        [:chat, :task, :workflow],
        needs_user_ctx:       true,
        identity_lookup:      nil | "<slug>.<function>",
        write_class:          :read | :write,
        idempotency:          :inferred | :required | :unsafe,
        source:               {module(), :internal | :connector | :synthetic}
      }

  ## Internal vs connector vs synthetic — by source

    * `:internal` — registered Elixir tool module under
      `DmhAi.Tools.*` (implements `DmhAi.Tools.Behaviour`).
      `call/3` delegates to `Tools.Registry.execute/3`.
    * `:external_connector` — registered connector module with a
      `Manifest`. `call/3` delegates to `Tools.Dispatcher.call/3`.
    * `:llm_synthetic` — name marked as synthetic in the static
      `@synthetic_names` list. `call/3` refuses to dispatch (the
      workflow executor invokes the LLM directly per G5);
      `{:error, :llm_synthetic_via_executor}` is the typed refusal.
  """

  alias DmhAi.Tools.{Dispatcher, Manifest, Registry}
  require Logger

  # ── LLM-synthetic entries ──────────────────────────────────────────────

  # These names are reserved for the workflow Executor to invoke
  # the LLM directly (compose-only role). Catalog.call/3 refuses
  # them so any non-executor caller learns immediately it's
  # holding the wrong tool.
  @synthetic_names ["llm.compose", "llm.summarise"]

  @synthetic_manifests %{
    "llm.compose" => %{
      name:        "llm.compose",
      description:
        "Compose-only LLM call for workflow IR. Two args, no others. " <>
          "`template` is a string with `{{key}}` placeholders. `context` " <>
          "is a map whose KEYS MUST MATCH the placeholders in `template` " <>
          "and whose VALUES are the resolved bindings (literals or " <>
          "`{{T.…}}` / `{{<node>.<field>}}` references). EVERY `{{key}}` " <>
          "in `template` must have a corresponding `key` in `context`, " <>
          "otherwise the placeholder renders to an empty string. Emits " <>
          "`{subject, body, rendered}` — `body` is the rendered template " <>
          "(same as `rendered`); `subject` is empty in v1. Downstream " <>
          "nodes bind to `{{<this-node-id>.body}}` to use the result.",
      args_schema: %{
        "template" => %{type: :string, required: true},
        "context"  => %{type: :object, required: true}
      },
      emits_schema:    %{subject: :string, body: :string, rendered: :string},
      permission:      :read_kb,
      callable_from:   [:workflow],
      needs_user_ctx:  true,
      identity_lookup: nil,
      write_class:     :read,
      idempotency:     :unsafe
    },
    "llm.summarise" => %{
      name:        "llm.summarise",
      description:
        "Compress a long string into a one-paragraph summary. " <>
          "Emits `{summary}` — bind downstream as `{{<this-node-id>.summary}}`.",
      args_schema: %{
        "text"      => %{type: :string, required: true},
        "max_words" => %{type: :integer, required: false}
      },
      emits_schema:    %{summary: :string},
      permission:      :read_kb,
      callable_from:   [:workflow],
      needs_user_ctx:  false,
      identity_lookup: nil,
      write_class:     :read,
      idempotency:     :unsafe
    }
  }

  # Closures can't live in module attributes; build the target fn
  # at lookup time. Synthetics never act on a connector cred, so
  # their permission target is `kb:*` (trivially passes `:read_kb`).
  defp synthetic_target_fn, do: fn _args, _ctx -> "kb:*" end

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Look up the manifest for any callable name. Returns
  `{:ok, manifest}` or `{:error, :unknown}`.

  Order of resolution:

    1. Internal tool modules (Registry).
    2. LLM synthetics (`@synthetic_names`).
    3. External connector functions (Dispatcher), namespaced
       `<slug>.<function_path>`.
  """
  @spec lookup(String.t()) :: {:ok, map()} | {:error, :unknown}
  def lookup(name) when is_binary(name) do
    cond do
      manifest = internal_manifest(name) -> {:ok, manifest}
      manifest = synthetic_manifest(name) -> {:ok, manifest}
      manifest = connector_manifest(name) -> {:ok, manifest}
      true -> {:error, :unknown}
    end
  end

  def lookup(_), do: {:error, :unknown}

  @doc """
  Same as `lookup/1` but raises on unknown name. Use only at
  callsites that have already validated the name (workflow IR
  was compiled against the catalog).
  """
  @spec lookup!(String.t()) :: map()
  def lookup!(name) do
    case lookup(name) do
      {:ok, m} -> m
      _ -> raise ArgumentError, "Tools.Catalog: unknown name #{inspect(name)}"
    end
  end

  @doc """
  Dispatch a call by canonical name. Routes by manifest category;
  the LLM-synthetic carve-out (G5) refuses synthetics — the
  workflow Executor invokes the LLM directly for those.

  Permission gate fires before dispatch via `Permissions.can?/3`;
  on denial the returned envelope embeds the `%Permissions.Denial{}`
  struct.

  `ctx` requires at minimum `%{user_id: <binary>}` for any function
  with `needs_user_ctx: true`. Workflow runs additionally pass
  `:act_as_user_id` which overrides the cred-holder in the
  permission target derivation for `:act_as_creds` actions.
  """
  @spec call(String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  def call(name, args, ctx) when is_binary(name) do
    with {:ok, manifest} <- lookup(name) do
      # The ONE `case category` outside this module's siblings —
      # the executor's LLM-synthetic carve-out has its own. Every
      # other caller goes through call/3.
      case manifest.category do
        :llm_synthetic ->
          {:error, :llm_synthetic_via_executor}

        :internal ->
          Registry.execute(name, args, ctx)

        :external_connector ->
          Dispatcher.call(name, args, ctx)
      end
    end
  end

  def call(name, _args, _ctx),
    do: {:error, %{error: "bad_name", got: inspect(name)}}

  @doc """
  Enumerate every callable visible to `caller_ctx`.

    * No ctx → only built-in internal tools + synthetics.
    * With `%{user_id, task_id}` → adds attached MCP tools +
      connector functions registered with the Dispatcher.

  Returns manifest maps; callers (compiler, MCP tools/list, FE
  catalog) project to the fields they need.
  """
  @spec list(map() | nil) :: [map()]
  def list(ctx \\ nil)

  def list(nil) do
    internal_manifests() ++ Enum.map(@synthetic_names, &synthetic_manifest/1)
  end

  def list(%{user_id: user_id} = ctx) when is_binary(user_id) do
    task_id = Map.get(ctx, :task_id)

    internal_manifests() ++
      Enum.map(@synthetic_names, &synthetic_manifest/1) ++
      connector_manifests() ++
      mcp_attached_manifests(user_id, task_id)
  end

  def list(_), do: list(nil)

  # ── Internal tools ─────────────────────────────────────────────────────

  defp internal_manifest(name) when is_binary(name) do
    case Enum.find(Registry.tool_modules(), &(safe_name(&1) == name)) do
      nil -> nil
      mod -> derive_internal_manifest(mod)
    end
  end

  defp internal_manifests do
    Registry.tool_modules()
    |> Enum.map(&derive_internal_manifest/1)
    |> Enum.reject(&is_nil/1)
  end

  defp derive_internal_manifest(mod) do
    name      = safe_name(mod)
    desc      = safe_call(mod, :description, [], "")
    defn      = safe_call(mod, :definition,  [], %{})
    params    = Map.get(defn, :parameters, %{}) |> coerce_args_schema()

    overrides =
      if function_exported?(mod, :catalog_manifest, 0) do
        try do
          mod.catalog_manifest()
        rescue
          _ -> %{}
        end
      else
        %{}
      end

    base = %{
      name:                 name,
      description:          desc,
      category:             :internal,
      args_schema:          params,
      emits_schema:         %{},
      permission:           :read_kb,
      permission_target_fn: fn _args, _ctx -> "kb:*" end,
      callable_from:        [:chat, :task, :workflow],
      needs_user_ctx:       true,
      identity_lookup:      nil,
      write_class:          :read,
      idempotency:          :inferred,
      source:               {mod, :internal}
    }

    Map.merge(base, overrides)
  end

  defp coerce_args_schema(%{} = m), do: m
  defp coerce_args_schema(_),       do: %{}

  defp safe_name(mod) do
    safe_call(mod, :name, [], to_string(mod))
  end

  defp safe_call(mod, fun, args, default) do
    arity = length(args)
    # `function_exported?/3` returns false for un-loaded modules, so
    # ensure the BEAM file is loaded first — otherwise tools that
    # haven't been touched yet in this process look like they don't
    # export `name/0` and the catalog returns the wrong default.
    Code.ensure_loaded(mod)

    if function_exported?(mod, fun, arity) do
      try do
        apply(mod, fun, args)
      rescue
        _ -> default
      end
    else
      default
    end
  end

  # ── LLM synthetics ─────────────────────────────────────────────────────

  defp synthetic_manifest(name) when is_binary(name) do
    case Map.get(@synthetic_manifests, name) do
      nil -> nil
      m   ->
        Map.merge(m, %{
          category:             :llm_synthetic,
          permission_target_fn: synthetic_target_fn(),
          source:               {nil, :synthetic}
        })
    end
  end

  # ── Connector functions ────────────────────────────────────────────────

  defp connector_manifest(name) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [slug, path] when slug != "" and path != "" ->
        case Dispatcher.lookup(slug) do
          {:ok, %{module: mod, manifest: %Manifest{functions: functions}}} ->
            case Map.get(functions, path) do
              %Manifest.Function{} = f -> derive_connector_manifest(slug, path, mod, f)
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp connector_manifests do
    Dispatcher.connectors()
    |> Enum.flat_map(fn slug ->
      case Dispatcher.lookup(slug) do
        {:ok, %{module: mod, manifest: %Manifest{functions: functions}}} ->
          Enum.map(functions, fn {path, f} -> derive_connector_manifest(slug, path, mod, f) end)

        _ ->
          []
      end
    end)
  end

  defp derive_connector_manifest(slug, path, mod, %Manifest.Function{} = f) do
    name = slug <> "." <> path

    {action, target_fn} =
      case f.permission do
        :admin ->
          {:write_settings, fn _args, _ctx -> "org_settings" end}

        _ ->
          # Default for connector function calls — uses the
          # caller's OAuth creds (or `act_as_user_id` override per
          # workflow step). Permissions.can?/3 self-pass means
          # this is always allowed for the caller's own creds; the
          # gate fires when act_as_user_id differs.
          {:act_as_creds,
           fn _args, ctx ->
             target_user =
               Map.get(ctx, :act_as_user_id) ||
                 Map.get(ctx, "act_as_user_id") ||
                 Map.get(ctx, :user_id) ||
                 Map.get(ctx, "user_id")

             "creds:#{slug}:#{target_user}"
           end}
      end

    identity_lookup_fn =
      cond do
        function_exported?(mod, :identity_lookup, 0) ->
          case mod.identity_lookup() do
            %{function: fname} -> fname
            _ -> nil
          end

        true ->
          nil
      end

    %{
      name:                 name,
      description:          "",
      category:             :external_connector,
      args_schema:          coerce_args_schema(f.args),
      emits_schema:         coerce_args_schema(f.returns),
      permission:           action,
      permission_target_fn: target_fn,
      callable_from:        f.callable_from || [:chat, :task],
      needs_user_ctx:       true,
      identity_lookup:      identity_lookup_fn,
      write_class:          if(f.permission == :write, do: :write, else: :read),
      idempotency:          f.idempotency_key || :inferred,
      source:               {mod, :connector}
    }
  end

  # ── MCP tools attached to the caller's task ───────────────────────────

  defp mcp_attached_manifests(user_id, task_id) do
    user_id
    |> DmhAi.MCP.Registry.tools_for_task(task_id)
    |> Enum.map(fn t ->
      %{
        name:                 t.name,
        description:          t.description,
        category:             :external_connector,
        args_schema:          t.inputSchema || %{},
        emits_schema:         %{},
        permission:           :act_as_creds,
        permission_target_fn: fn _args, ctx ->
          target_user = Map.get(ctx, :act_as_user_id) || Map.get(ctx, :user_id)
          slug = t.name |> String.split(".") |> List.first()
          "creds:#{slug}:#{target_user}"
        end,
        callable_from:        [:chat, :task],
        needs_user_ctx:       true,
        identity_lookup:      nil,
        write_class:          :read,
        idempotency:          :inferred,
        source:               {nil, :mcp_attached}
      }
    end)
  end
end
