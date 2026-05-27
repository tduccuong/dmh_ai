# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Dispatcher do
  @moduledoc """
  Primitive 0.3's single chokepoint for every connector function call.

  The agent surface (chat handler, task runner) hands a typed call
  `{function, args, caller_ctx}` and Dispatcher does:

    1. Resolve `function` (namespace.path → connector + function name).
    2. Load the connector manifest (validated at registration time).
    3. **Capability.** The connector's capability for this function
       must be enabled for the caller's org; otherwise typed
       `capability_disabled` envelope.
    4. **Permission.** `Permissions.can?(user, action, ...)`;
       deny → typed `permission_denied` envelope.
    5. **Idempotency.** For writes that mark `idempotency_key: :required`,
       compute `sha256(session_id ‖ step_seq ‖ function)` and pass it
       to the adapter as `__idempotency_key`.
    6. Forward to `MCPAdapter.<Connector>.call/3` (or in-process
       Elixir route, when we add internal connectors).
    7. Normalise the response via the adapter shim.

  Internal tools (`fetch_index`, `run_script`, …) are out-of-scope for
  the dispatcher's rules — they're not in any manifest. They keep their
  existing dispatch path through `DmhAi.Tools.Registry`.

  ## Connector registration

  At application boot, `Application.start/2` walks the configured
  connector modules, calls `manifest/0` on each, validates, and
  registers them into the dispatcher's in-memory table (ETS, keyed
  by connector slug). A manifest that fails `Manifest.validate/1`
  logs a `manifest_violation` and is NOT registered — the functions
  become unreachable until the manifest is fixed.
  """

  alias DmhAi.Tools.Manifest
  alias DmhAi.{Orgs, Permissions}
  require Logger

  @table :dmh_ai_dispatcher_registry

  # ─── Registration ─────────────────────────────────────────────────────────

  @doc "Initialise the ETS registry. Idempotent."
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      _ -> :ok
    end

    :ok
  end

  @doc """
  Register a connector by module name. The module must export
  `manifest/0` returning a `Manifest` struct.
  """
  @spec register(module()) :: :ok | {:error, term()}
  def register(mod) when is_atom(mod) do
    init()

    try do
      manifest = mod.manifest()

      case Manifest.validate(manifest) do
        :ok ->
          :ets.insert(@table, {manifest.connector, %{module: mod, manifest: manifest}})
          Logger.info("[Dispatcher] registered connector=#{manifest.connector} functions=#{map_size(manifest.functions)}")
          :ok

        {:error, {:manifest_violation, _conn, reason}} = err ->
          Logger.error("[Dispatcher] manifest_violation for #{inspect(mod)}: #{reason}")
          err
      end
    rescue
      e ->
        Logger.error("[Dispatcher] register/1 for #{inspect(mod)} crashed: #{Exception.message(e)}")
        {:error, {:registration_crash, Exception.message(e)}}
    end
  end

  @doc "Reset the registry (test fixture)."
  @spec reset() :: :ok
  def reset do
    init()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "List every registered connector slug."
  @spec connectors() :: [String.t()]
  def connectors do
    init()
    :ets.tab2list(@table) |> Enum.map(fn {slug, _} -> slug end) |> Enum.sort()
  end

  @doc "Look up a connector entry by slug."
  @spec lookup(String.t()) :: {:ok, map()} | :not_found
  def lookup(slug) when is_binary(slug) do
    init()

    case :ets.lookup(@table, slug) do
      [{^slug, entry}] -> {:ok, entry}
      _ -> :not_found
    end
  end

  # ─── Dispatch ─────────────────────────────────────────────────────────────

  @doc """
  Dispatch a function call. `function` is `"<connector>.<path>"` (e.g.
  `"hubspot.contact.find"`). `args` is the function's argument map.
  `caller_ctx` carries `:user_id` (required), `:session_id` (optional —
  used by the idempotency-key hash for writes), `:step_seq` (optional —
  workflow step ordinal for the same hash).

  Returns `{:ok, result}` or `{:error, envelope}`.
  """
  @spec call(String.t(), map(), map()) :: {:ok, term()} | {:error, map()}
  def call(function_name, args, caller_ctx) when is_binary(function_name) do
    # `function_name` (outer) is the FULL `"<connector>.<path>"` form
    # the caller passed. `function_path` (inner, after parse_function_name) is
    # just the path part — what the connector's manifest keys on.
    # Error envelopes embed the FULL `function_name` so the caller can
    # cite back the exact string they invoked.
    with {:ok, connector_slug, function_path} <- parse_function_name(function_name),
         {:ok, entry}                         <- get_entry(connector_slug),
         {:ok, function}                      <- get_function(entry, function_path, function_name),
         :ok                                  <- check_capability_enabled(connector_slug, function_path, function_name, caller_ctx),
         :ok                                  <- check_permission(function, caller_ctx, function_name),
         {:ok, args2}                         <- maybe_inject_idempotency(function, args, caller_ctx, function_name) do
      entry.module.call(function_path, args2, caller_ctx)
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp parse_function_name(function) do
    case String.split(function, ".", parts: 2) do
      [connector, path] when connector != "" and path != "" ->
        {:ok, connector, path}

      _ ->
        {:error, error_envelope(:unknown_function, function: function)}
    end
  end

  defp get_entry(slug) do
    case lookup(slug) do
      {:ok, entry} -> {:ok, entry}
      :not_found -> {:error, error_envelope(:connector_not_registered, connector: slug)}
    end
  end

  defp get_function(entry, function_path, _function_name) do
    case entry.manifest.functions[function_path] do
      %Manifest.Function{} = v -> {:ok, v}
      _ -> {:error, error_envelope(:unknown_function, function: function_path)}
    end
  end

  # Layer 3 of the 3-layer admin-policy enforcement. Even if a
  # stale tool catalog or a hallucinated function name reaches the
  # dispatcher, the call is refused with a typed envelope unless the
  # admin's `enabled_capabilities` covers this function. Capability
  # lookup is org-scoped per caller_ctx.
  defp check_capability_enabled(slug, function_path, function_name, ctx) do
    org_id = org_for_ctx(ctx)

    if DmhAi.Connectors.Capabilities.function_enabled?(slug, function_path, org_id) do
      :ok
    else
      {:error, error_envelope(:capability_disabled, function: function_name, connector: slug)}
    end
  end

  defp check_permission(%Manifest.Function{permission: perm}, ctx, function) do
    caller_user_id = ctx[:user_id]
    # The credential-holder is the caller by default; workflow steps
    # may override via `act_as_user_id` (compile-time-permitted only).
    target_user_id = ctx[:act_as_user_id] || caller_user_id
    slug = function |> String.split(".") |> List.first()

    {action, target} =
      case perm do
        :admin -> {:write_settings, "org_settings"}
        _      -> {:act_as_creds,   "creds:#{slug}:#{target_user_id}"}
      end

    if Permissions.can?(caller_user_id, action, target) do
      :ok
    else
      denial = Permissions.denial(caller_user_id, action, target)
      {:error, error_envelope(:permission_denied,
                              function: function,
                              required: perm,
                              denial:   denial)}
    end
  end

  defp maybe_inject_idempotency(%Manifest.Function{permission: :write,
                                               idempotency_key: :required}, args, ctx, function) do
    # Idempotency key scoped to the chain that emitted the call. With no
    # task abstraction, the (session_id, step_seq, function) tuple is the
    # natural collision window — replays inside the same chain hash to
    # the same key.
    session_id = ctx[:session_id] || ""
    step_seq = ctx[:step_seq] || 0
    key = :crypto.hash(:sha256, "#{session_id}\0#{step_seq}\0#{function}") |> Base.encode16(case: :lower)
    {:ok, Map.put(args, "__idempotency_key", key)}
  end

  defp maybe_inject_idempotency(_function, args, _ctx, _function_name), do: {:ok, args}

  defp error_envelope(:permission_denied, opts) do
    base = %{
      error:    "permission_denied",
      function: opts[:function],
      required: opts[:required]
    }

    case opts[:denial] do
      %Permissions.Denial{} = d ->
        Map.merge(base, %{
          reason:      d.reason,
          target:      d.target,
          remediation: Enum.map(d.remediation, fn {kind, text} -> %{kind: kind, text: text} end)
        })

      _ ->
        base
    end
  end

  defp error_envelope(:missing_credentials, opts) do
    %{error: "missing_credentials", connector: opts[:connector]}
  end

  defp error_envelope(:unknown_function, opts) do
    %{error: "unknown_function", function: opts[:function]}
  end

  defp error_envelope(:connector_not_registered, opts) do
    %{error: "connector_not_registered", connector: opts[:connector]}
  end

  defp error_envelope(:capability_disabled, opts) do
    %{
      error:     "capability_disabled",
      connector: opts[:connector],
      function:  opts[:function],
      hint:
        "Admin disabled this capability for the org. The function is no longer " <>
          "available. Tell the user to ask their admin to re-enable it via " <>
          "External Connectors if they need it."
    }
  end

  # Public exports used by adapters/tests.
  @doc false
  def env(kind, opts), do: error_envelope(kind, opts)

  @doc """
  Caller-context org resolution. Pure helper exported so adapter
  shims can pull the calling user's org_id without re-implementing
  the lookup.
  """
  @spec org_for_ctx(map()) :: String.t()
  def org_for_ctx(%{user_id: uid}) when is_binary(uid), do: Orgs.for_user(uid)
  def org_for_ctx(_), do: Orgs.default_id()
end
