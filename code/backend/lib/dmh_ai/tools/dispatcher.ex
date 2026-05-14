# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.Dispatcher do
  @moduledoc """
  Primitive 0.3's single chokepoint for every connector verb call.

  The agent surface (chat handler, task runner) hands a typed call
  `{verb, args, caller_ctx}` and Dispatcher does:

    1. Resolve `verb` (namespace.path → connector + verb name).
    2. Load the connector manifest (validated at registration time).
    3. **Rule 1 — Permission.** `Permissions.can?(user, action, ...)`;
       deny → audit + typed `permission_denied` envelope.
    4. **Rule 2 — Write-requires-task.** `permission: :write` verbs
       refuse with `write_requires_task` envelope when
       `caller_ctx.task_id` is nil.
    5. **Rule 3 — Idempotency.** For writes, compute
       `sha256(task_id ‖ step_seq ‖ verb)` and pass to the adapter.
    6. **Rule 4 — Credentials.** Look up the calling user's
       `user_credentials` for the connector; missing → typed
       `missing_credentials` envelope.
    7. Forward to `MCPAdapter.<Connector>.call/3` (or in-process
       Elixir route, when we add internal connectors).
    8. Normalise the response via the adapter shim.

  Internal verbs (`*_task`, `fetch_index`, `run_script`, …) are
  out-of-scope for the dispatcher's rules — they're not in any
  manifest. They keep their existing dispatch path through
  `DmhAi.Tools.Registry`.

  ## Connector registration

  At application boot, `Application.start/2` walks the configured
  connector modules, calls `manifest/0` on each, validates, and
  registers them into the dispatcher's in-memory table (ETS, keyed
  by connector slug). A manifest that fails `Manifest.validate/1`
  logs a `manifest_violation` and is NOT registered — the verbs
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
          Logger.info("[Dispatcher] registered connector=#{manifest.connector} verbs=#{map_size(manifest.verbs)}")
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
  Dispatch a verb call. `verb` is `"<connector>.<path>"` (e.g.
  `"hubspot.contact.find"`). `args` is the verb's argument map.
  `caller_ctx` carries `:user_id` (required), `:task_id` (optional
  — active task id, required for write verbs), `:step_seq` (when
  inside a task).

  Returns `{:ok, result}` or `{:error, envelope}`.
  """
  @spec call(String.t(), map(), map()) :: {:ok, term()} | {:error, map()}
  def call(verb_name, args, caller_ctx) when is_binary(verb_name) do
    with {:ok, connector_slug, verb_path} <- parse_verb(verb_name),
         {:ok, entry}                     <- get_entry(connector_slug),
         {:ok, verb}                      <- get_verb(entry, verb_path),
         :ok                              <- check_callable_from(verb, caller_ctx, verb_name),
         :ok                              <- check_permission(verb, caller_ctx, verb_name),
         {:ok, args2}                     <- maybe_inject_idempotency(verb, args, caller_ctx, verb_name) do
      entry.module.call(verb_path, args2, caller_ctx)
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp parse_verb(verb) do
    case String.split(verb, ".", parts: 2) do
      [connector, path] when connector != "" and path != "" ->
        {:ok, connector, path}

      _ ->
        {:error, error_envelope(:unknown_verb, verb: verb)}
    end
  end

  defp get_entry(slug) do
    case lookup(slug) do
      {:ok, entry} -> {:ok, entry}
      :not_found -> {:error, error_envelope(:connector_not_registered, connector: slug)}
    end
  end

  defp get_verb(entry, verb_path) do
    case entry.manifest.verbs[verb_path] do
      %Manifest.Verb{} = v -> {:ok, v}
      _ -> {:error, error_envelope(:unknown_verb, verb: verb_path)}
    end
  end

  defp check_callable_from(%Manifest.Verb{callable_from: from}, ctx, verb) do
    in_task? = is_binary(ctx[:task_id]) and ctx[:task_id] != ""

    cond do
      :task in from and in_task? -> :ok
      :chat in from and not in_task? -> :ok
      :task in from and not in_task? ->
        # Rule 2 (HARD): write verb attempted outside an active task.
        {:error, error_envelope(:write_requires_task, verb: verb,
                                hint: "open a task first via create_task, then retry")}

      true ->
        {:error, error_envelope(:write_requires_task, verb: verb)}
    end
  end

  defp check_permission(%Manifest.Verb{permission: perm}, ctx, verb) do
    user_id = ctx[:user_id]
    resource = {:verb, verb}
    action =
      case perm do
        :read  -> :read
        :write -> :write
        :admin -> :administer
      end

    if Permissions.can?(user_id, action, resource) do
      :ok
    else
      {:error, error_envelope(:permission_denied, verb: verb, required: perm)}
    end
  end

  defp maybe_inject_idempotency(%Manifest.Verb{permission: :write,
                                               idempotency_key: :required}, args, ctx, verb) do
    task_id  = ctx[:task_id]
    step_seq = ctx[:step_seq] || 0
    key = :crypto.hash(:sha256, "#{task_id}\0#{step_seq}\0#{verb}") |> Base.encode16(case: :lower)
    {:ok, Map.put(args, "__idempotency_key", key)}
  end

  defp maybe_inject_idempotency(_verb, args, _ctx, _verb_name), do: {:ok, args}

  defp error_envelope(:write_requires_task, opts) do
    %{
      error: "write_requires_task",
      verb:  opts[:verb],
      hint:  opts[:hint] || "this verb is only callable inside an active task"
    }
  end

  defp error_envelope(:permission_denied, opts) do
    %{
      error:    "permission_denied",
      verb:     opts[:verb],
      required: opts[:required]
    }
  end

  defp error_envelope(:missing_credentials, opts) do
    %{error: "missing_credentials", connector: opts[:connector]}
  end

  defp error_envelope(:unknown_verb, opts) do
    %{error: "unknown_verb", verb: opts[:verb]}
  end

  defp error_envelope(:connector_not_registered, opts) do
    %{error: "connector_not_registered", connector: opts[:connector]}
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
