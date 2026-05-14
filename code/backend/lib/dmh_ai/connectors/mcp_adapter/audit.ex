# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPAdapter.Audit do
  @moduledoc """
  Audit-row writer for connector calls. Reuses the `audit_log` table
  introduced by Primitive 0.1's Permissions module — same shape,
  different `action` taxonomy.

  Policy: write verbs ALWAYS audit. Read verbs audit only on denial
  (volume reasons — read-tier traffic dominates).
  """

  alias DmhAi.Repo
  alias DmhAi.Tools.Manifest
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @type outcome :: :allowed | {:denied, String.t() | atom()}

  @doc """
  Write one audit row for a connector call. `connector_mod`
  exposes `manifest/0`, from which we read the verb's permission
  tag to decide whether to write a row on the `:allowed` path.
  """
  @spec record(module(), String.t(), map(), outcome()) :: :ok
  def record(connector_mod, verb_path, caller_ctx, outcome) do
    permission = verb_permission(connector_mod, verb_path)

    if should_write?(permission, outcome) do
      do_write(connector_mod, verb_path, caller_ctx, outcome)
    else
      :ok
    end
  end

  # Read + allowed → silent (volume).
  defp should_write?(:read, :allowed), do: false
  defp should_write?(_, _), do: true

  defp verb_permission(connector_mod, verb_path) do
    case connector_mod.manifest().verbs[verb_path] do
      %Manifest.Verb{permission: p} -> p
      _ -> :read
    end
  end

  defp do_write(connector_mod, verb_path, caller_ctx, outcome) do
    user_id = caller_ctx[:user_id]
    org_id  = DmhAi.Orgs.for_user(user_id)
    slug    = connector_mod.mcp_slug()
    {outcome_str, reason} = encode_outcome(outcome)

    resource = Jason.encode!(%{
      kind:      "verb",
      connector: slug,
      verb:      verb_path
    })

    action = action_for(connector_mod, verb_path)

    query!(Repo, """
    INSERT INTO audit_log (org_id, user_id, action, resource, outcome, reason, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """, [
      org_id,
      user_id,
      action,
      resource,
      outcome_str,
      reason,
      System.os_time(:millisecond)
    ])

    :ok
  rescue
    e ->
      Logger.warning("[MCPAdapter.Audit] insert failed: #{Exception.message(e)}")
      :ok
  end

  defp action_for(connector_mod, verb_path) do
    case verb_permission(connector_mod, verb_path) do
      :read  -> "read"
      :write -> "write"
      :admin -> "administer"
    end
  end

  defp encode_outcome(:allowed),                           do: {"allowed", nil}
  defp encode_outcome({:denied, reason}) when is_binary(reason), do: {"denied", reason}
  defp encode_outcome({:denied, reason}),                  do: {"denied", to_string(reason)}
end
