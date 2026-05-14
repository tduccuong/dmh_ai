# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Permissions do
  @moduledoc """
  Central per-org permission check, per Primitive 0.7. Single API:

      Permissions.can?(user, action, resource) :: boolean

  `user` is either a user-id binary or a map with at minimum `:id`
  and `:org_role`. `:org_role` is one of `member | manager | admin`
  inside their organisation; the install-level `role` superuser flag
  (admin of the DMH-AI deployment itself) always bypasses checks.

  ## Actions

      :read       — view a resource
      :write      — create / mutate
      :invoke     — run a template or call a connector verb
      :approve    — decide on a pending approval
      :administer — manage settings, connectors, templates, members

  ## Resources

  Tagged tuples / atoms describing what is being accessed:

      {:kb, source_id}
      {:template, id}
      {:verb, "connector.verb"}    # e.g. {:verb, "hubspot.deal.create"}
      {:approval, id}
      {:connector, name}
      :org_settings

  ## Denial trail

  Every `false` result writes an `audit_log` row with `outcome='denied'`
  + a short `reason` tag. Allowed checks are silent except where the
  caller explicitly opts into auditing via `audit/4`.

  ## Default policy matrix

  Coarse-grained defaults applied when no per-resource ACL is set.
  Tightened per-resource via the connector's
  `permission_overrides.yaml` or a template's `roles: [...]`
  declaration (handled at the manifest / template layer, not here).

      Role     │ read │ write │ invoke │ approve │ administer
      ─────────┼──────┼───────┼────────┼─────────┼────────────
      member   │  yes │  yes  │  yes   │   no    │   no
      manager  │  yes │  yes  │  yes   │  yes    │   no
      admin    │  yes │  yes  │  yes   │  yes    │  yes
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @type action     :: :read | :write | :invoke | :approve | :administer
  @type resource   :: {:kb, integer()} | {:template, String.t()} | {:verb, String.t()}
                      | {:approval, integer()} | {:connector, String.t()} | :org_settings
  @type user_like  :: map() | String.t()

  @doc """
  Returns `true` if the caller is allowed; `false` otherwise. Writes
  a denial row to `audit_log` on `false`.
  """
  @spec can?(user_like(), action(), resource()) :: boolean()
  def can?(user, action, resource) do
    {user_id, org_role, install_role, org_id} = resolve(user)

    cond do
      install_role == "admin" ->
        true

      org_role == nil ->
        deny(user_id, org_id, action, resource, "no_org_role")
        false

      action == :administer and org_role != "admin" ->
        deny(user_id, org_id, action, resource, "admin_only")
        false

      action == :approve and org_role == "member" ->
        deny(user_id, org_id, action, resource, "manager_or_admin_only")
        false

      true ->
        # Role-default matrix matches the table in the moduledoc. The
        # per-resource overrides hook here later when 0.7 wires in
        # template `roles:` + connector `permission_overrides.yaml`;
        # for now the role gate alone is sufficient.
        true
    end
  end

  @doc """
  Log an explicit allowed/denied audit row. Use from high-sensitivity
  callsites where you want the allowed path traceable (e.g.
  cross-user access to org KB).
  """
  @spec audit(user_like(), action(), resource(), :allowed | :denied, String.t() | nil) :: :ok
  def audit(user, action, resource, outcome, reason \\ nil) do
    {user_id, _org_role, _install_role, org_id} = resolve(user)
    write_audit(user_id, org_id, action, resource, outcome, reason)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp resolve(user_id) when is_binary(user_id) do
    case query!(Repo, "SELECT id, org_id, org_role, role FROM users WHERE id=?", [user_id]).rows do
      [[id, org_id, org_role, role]] -> {id, org_role, role, org_id}
      _ -> {user_id, nil, nil, DmhAi.Constants.default_org_id()}
    end
  rescue
    _ -> {user_id, nil, nil, DmhAi.Constants.default_org_id()}
  end

  defp resolve(%{id: id, org_role: org_role} = user) do
    {id, org_role, Map.get(user, :role), Map.get(user, :org_id, DmhAi.Constants.default_org_id())}
  end

  defp resolve(_), do: {nil, nil, nil, DmhAi.Constants.default_org_id()}

  defp deny(user_id, org_id, action, resource, reason) do
    write_audit(user_id, org_id, action, resource, :denied, reason)
  end

  defp write_audit(user_id, org_id, action, resource, outcome, reason) do
    query!(Repo, """
    INSERT INTO audit_log (org_id, user_id, action, resource, outcome, reason, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """, [
      org_id,
      user_id,
      to_string(action),
      encode_resource(resource),
      to_string(outcome),
      reason,
      System.os_time(:millisecond)
    ])

    :ok
  rescue
    e ->
      Logger.warning("[Permissions] audit insert failed: #{Exception.message(e)}")
      :ok
  end

  defp encode_resource(:org_settings),
    do: Jason.encode!(%{kind: "org_settings"})

  defp encode_resource({kind, id}),
    do: Jason.encode!(%{kind: to_string(kind), id: id})

  defp encode_resource(other),
    do: Jason.encode!(%{kind: "unknown", raw: inspect(other)})
end
