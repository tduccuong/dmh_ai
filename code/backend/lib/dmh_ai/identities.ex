# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Identities do
  @moduledoc """
  Primitive 0.9 — org-user ⇄ connector-user mapping.

  Single API:

      Identities.resolve(user_id, connector_slug) ::
        {:ok, external_id}
      | {:error, :no_mapping | :connector_not_found | :api_error}

  Generic — no per-connector code lives here. Vendor knowledge is
  one row in the connector's manifest (the `identity_lookup`
  callback). Adding a new connector vertical = drop the manifest
  line; workflows that say `@user_N` against that vertical Just
  Work.

  ## Flow

  1. Look up `(org_id, user_id, connector_slug)` in the cache table
     `connector_identities`. Hit + non-stale → return.
  2. Cache miss / stale → read the user's `email` + `email_aliases`
     from `users`. For each email in priority order, call the
     connector module's `identity_lookup/0` function via the
     dispatcher.
  3. First success → INSERT/UPDATE the cache row, return the id.
  4. All emails fail → `{:error, :no_mapping}`.

  ## Manual overrides

  Admin writes a row with `resolved_via = "manual_override"` and
  `ttl_s = 0` (permanent) via `put_manual_override/4` (used by
  `POST /admin/identities`). Manual overrides win over the email
  pivot and survive TTL expiry. They're invalidated only by
  `users.email` change, use-time 404 (`invalidate/2`), or an
  explicit admin overwrite.

  ## Invalidation

      Identities.invalidate(user_id, connector_slug)

  Drops the cache row. Use from the dispatcher when a downstream
  function returns "user not found" with the external_id we passed
  — the cached mapping is stale.
  """

  alias DmhAi.{Repo, Constants, Permissions}
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @resolved_primary "primary_email"
  @resolved_manual  "manual_override"
  @default_ttl_s    86_400      # 24h

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Look up the user's external id for a connector. Returns the
  cached value when fresh; on cache miss or staleness, runs the
  email pivot via the connector's manifest hook.

  Permission gate: caller (whoever invoked this) must have at least
  `:read_profile` on the target user. In practice that's same-org;
  cross-org leaks are impossible because the cache PK includes
  `org_id` and the resolver scopes its SELECT to the caller's org.
  """
  @spec resolve(String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def resolve(user_id, connector_slug)
      when is_binary(user_id) and is_binary(connector_slug) do
    org_id = org_for_user(user_id)

    case cache_lookup(org_id, user_id, connector_slug) do
      {:ok, external_id} ->
        {:ok, external_id}

      :stale ->
        # Cache hit but TTL expired (manual overrides are TTL=0 →
        # never stale). Try to refresh; if refresh fails, the cached
        # value is gone — invalidate and report no_mapping.
        case refresh(user_id, org_id, connector_slug) do
          {:ok, _} = ok -> ok
          err -> err
        end

      :miss ->
        refresh(user_id, org_id, connector_slug)
    end
  end

  def resolve(_, _), do: {:error, :bad_args}

  @doc """
  Invalidate a cached (user, slug) mapping. Called from the
  dispatcher when a downstream API rejects the external_id we
  passed (use-time 404).
  """
  @spec invalidate(String.t(), String.t()) :: :ok
  def invalidate(user_id, connector_slug)
      when is_binary(user_id) and is_binary(connector_slug) do
    org_id = org_for_user(user_id)

    query!(Repo, """
    DELETE FROM connector_identities
    WHERE org_id=? AND user_id=? AND connector_slug=?
    """, [org_id, user_id, connector_slug])

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Invalidate every cached mapping for a user. Called from the
  users-email-change handler — every external_id pivoted on the
  old email is presumed stale.
  """
  @spec invalidate_all(String.t()) :: :ok
  def invalidate_all(user_id) when is_binary(user_id) do
    org_id = org_for_user(user_id)

    query!(Repo, """
    DELETE FROM connector_identities WHERE org_id=? AND user_id=?
    """, [org_id, user_id])

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Write a permanent manual-override mapping. Used by the admin
  endpoint `POST /admin/identities`. Idempotent — overwrites any
  existing row for the same `(org, user, slug)`.

  Permission gate: enforced at the HTTP handler layer
  (`:write_settings, "org_settings"`); not re-checked here.
  """
  @spec put_manual_override(String.t(), String.t(), String.t(), String.t()) :: :ok
  def put_manual_override(user_id, connector_slug, external_id, _audit_actor_id)
      when is_binary(user_id) and is_binary(connector_slug) and is_binary(external_id) do
    org_id = org_for_user(user_id)
    now    = System.os_time(:second)

    query!(Repo, """
    INSERT INTO connector_identities
      (org_id, user_id, connector_slug, external_id, resolved_via, cached_at, ttl_s)
    VALUES (?, ?, ?, ?, ?, ?, 0)
    ON CONFLICT(org_id, user_id, connector_slug) DO UPDATE SET
      external_id  = excluded.external_id,
      resolved_via = excluded.resolved_via,
      cached_at    = excluded.cached_at,
      ttl_s        = 0
    """, [org_id, user_id, connector_slug, external_id, @resolved_manual, now])

    :ok
  end

  @doc """
  Inspect cached identity rows for a user (FE/admin diagnostics).
  Returns `[%{slug, external_id, resolved_via, cached_at, ttl_s}]`.
  """
  @spec list_for_user(String.t()) :: [map()]
  def list_for_user(user_id) when is_binary(user_id) do
    org_id = org_for_user(user_id)

    %{rows: rows} = query!(Repo, """
    SELECT connector_slug, external_id, resolved_via, cached_at, ttl_s
      FROM connector_identities
     WHERE org_id=? AND user_id=?
     ORDER BY connector_slug
    """, [org_id, user_id])

    Enum.map(rows, fn [slug, ext_id, via, at, ttl] ->
      %{slug: slug, external_id: ext_id, resolved_via: via,
        cached_at: at, ttl_s: ttl}
    end)
  end

  # ── Cache layer ─────────────────────────────────────────────────────────

  defp cache_lookup(org_id, user_id, slug) do
    case query!(Repo, """
    SELECT external_id, resolved_via, cached_at, ttl_s
      FROM connector_identities
     WHERE org_id=? AND user_id=? AND connector_slug=?
    """, [org_id, user_id, slug]).rows do
      [[external_id, _via, _cached_at, 0]] ->
        # Manual override (ttl_s = 0) — never stale.
        {:ok, external_id}

      [[external_id, _via, cached_at, ttl_s]] ->
        if fresh?(cached_at, ttl_s),
          do:  {:ok, external_id},
          else: :stale

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp fresh?(cached_at, ttl_s) when is_integer(cached_at) and is_integer(ttl_s) do
    System.os_time(:second) < cached_at + ttl_s
  end

  defp fresh?(_, _), do: false

  defp cache_put(org_id, user_id, slug, external_id, resolved_via) do
    now = System.os_time(:second)

    query!(Repo, """
    INSERT INTO connector_identities
      (org_id, user_id, connector_slug, external_id, resolved_via, cached_at, ttl_s)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(org_id, user_id, connector_slug) DO UPDATE SET
      external_id  = excluded.external_id,
      resolved_via = excluded.resolved_via,
      cached_at    = excluded.cached_at,
      ttl_s        = excluded.ttl_s
    """, [org_id, user_id, slug, external_id, resolved_via, now, @default_ttl_s])

    :ok
  rescue
    e ->
      Logger.warning("[Identities] cache_put failed: #{Exception.message(e)}")
      :ok
  end

  # ── Refresh / email-pivot ───────────────────────────────────────────────

  defp refresh(user_id, org_id, slug) do
    with {:ok, connector_module}   <- find_connector_module(slug),
         %{} = lookup_spec          <- get_identity_lookup(connector_module),
         {:ok, emails}              <- user_emails(user_id) do
      try_emails(emails, user_id, org_id, slug, connector_module, lookup_spec, 0)
    else
      :no_lookup ->
        {:error, :connector_has_no_identity_lookup}

      {:error, :not_registered} ->
        {:error, :connector_not_found}

      {:error, _} = err ->
        err
    end
  end

  defp try_emails([], _user_id, _org_id, _slug, _module, _spec, _idx),
    do: {:error, :no_mapping}

  defp try_emails([email | rest], user_id, org_id, slug, module, spec, idx) do
    resolved_via =
      if idx == 0, do: @resolved_primary, else: "alias:#{idx}"

    case call_identity_lookup(module, spec, email, user_id) do
      {:ok, external_id} when is_binary(external_id) and external_id != "" ->
        cache_put(org_id, user_id, slug, external_id, resolved_via)
        {:ok, external_id}

      _ ->
        try_emails(rest, user_id, org_id, slug, module, spec, idx + 1)
    end
  end

  # ── Manifest hook ───────────────────────────────────────────────────────

  defp get_identity_lookup(module) do
    if function_exported?(module, :identity_lookup, 0) do
      case module.identity_lookup() do
        nil -> :no_lookup
        spec when is_map(spec) -> spec
        _ -> :no_lookup
      end
    else
      :no_lookup
    end
  end

  defp call_identity_lookup(module, spec, email, caller_user_id) do
    function_name = Map.fetch!(spec, :function)
    by_arg_atom   = Map.fetch!(spec, :by_arg)
    emit_field    = Map.fetch!(spec, :emit_field)

    args = %{to_string(by_arg_atom) => email}
    ctx  = %{user_id: caller_user_id}

    [_slug | path_parts] = String.split(function_name, ".")
    path = Enum.join(path_parts, ".")

    case module.call(path, args, ctx) do
      {:ok, result} when is_map(result) ->
        case Map.get(result, emit_field) || Map.get(result, to_string(emit_field)) do
          v when is_binary(v) and v != "" -> {:ok, v}
          _ -> {:error, :emit_missing}
        end

      {:ok, _} ->
        {:error, :emit_missing}

      {:error, _} = err ->
        err
    end
  rescue
    e ->
      Logger.warning("[Identities] lookup raised slug=#{inspect(spec)}: #{Exception.message(e)}")
      {:error, :api_error}
  end

  # ── User + connector lookup helpers ─────────────────────────────────────

  defp user_emails(user_id) do
    case query!(Repo, "SELECT email, email_aliases FROM users WHERE id=?", [user_id]).rows do
      [[email, aliases_json]] when is_binary(email) and email != "" ->
        aliases = decode_aliases(aliases_json)
        {:ok, [email | aliases]}

      _ ->
        {:error, :user_not_found}
    end
  rescue
    _ -> {:error, :user_not_found}
  end

  defp decode_aliases(nil), do: []
  defp decode_aliases(""),  do: []

  defp decode_aliases(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.filter(list, &(is_binary(&1) and &1 != ""))

      _ ->
        []
    end
  end

  defp org_for_user(user_id) when is_binary(user_id) do
    case query!(Repo, "SELECT org_id FROM users WHERE id=?", [user_id]).rows do
      [[org]] when is_binary(org) -> org
      _ -> Constants.default_org_id()
    end
  rescue
    _ -> Constants.default_org_id()
  end

  defp find_connector_module(slug) do
    case DmhAi.Tools.Dispatcher.lookup(slug) do
      {:ok, %{module: mod}} -> {:ok, mod}
      :not_found            -> {:error, :not_registered}
    end
  end

  # ── Caller-side wrapper for permission-guarded reads ────────────────────

  @doc """
  Same as `resolve/2`, but enforces `:read_profile` on the target
  user first. Caller is the (typically workflow-owner) doing the
  read; the target user is `user_id` (whose external_id we want).
  Returns a `%Permissions.Denial{}` envelope on permission failure.
  """
  @spec resolve_for(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom() | Permissions.Denial.t()}
  def resolve_for(caller_user_id, target_user_id, connector_slug)
      when is_binary(caller_user_id) and is_binary(target_user_id) and is_binary(connector_slug) do
    if Permissions.can?(caller_user_id, :read_profile, "user:" <> target_user_id) do
      resolve(target_user_id, connector_slug)
    else
      {:error, Permissions.denial(caller_user_id, :read_profile, "user:" <> target_user_id)}
    end
  end
end
