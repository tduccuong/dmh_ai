# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Permissions do
  @moduledoc """
  Phase B permission pass.

  For every step in the IR, look up its manifest in `Tools.Catalog`
  and call `Permissions.can?(owner, action, target)`. Owner is
  `workflows.created_by` — the caller on first save, the existing
  owner on edits (immutable). Failure returns a structured envelope
  the chat can render as a request_input for the user to pick a
  remediation.

  Also resolves the owner (`resolve_owner/3`) for first-save vs.
  edit, and formats a denial (`format_denial/4`) into a teaching
  error.
  """

  alias DmhAi.Permissions, as: PermissionsCore
  alias DmhAi.Permissions.Denial
  alias DmhAi.Tools.Catalog
  alias DmhAi.Tools.UpsertWorkflow.{Functions, Synthetics}
  alias DmhAi.Workflows

  @doc """
  First save → caller is the workflow owner; edit → owner is
  immutable and we keep the original `created_by`.
  """
  @spec resolve_owner(String.t(), String.t(), String.t()) :: {:ok, String.t()}
  def resolve_owner(org_id, slug, caller_user_id) do
    case Workflows.get_workflow(org_id, slug) do
      nil -> {:ok, caller_user_id}                       # first save → caller is owner
      %{created_by: owner} -> {:ok, owner}                # edit → owner is immutable
    end
  end

  @doc """
  Permission gate for every step node in the IR. Halts on the first
  denial with a formatted teaching error; passes synthetics and
  unknown functions through (the latter is already caught by
  `Functions.check_functions_exist/1`).
  """
  @spec check_permissions(map(), String.t()) :: :ok | {:error, String.t()}
  def check_permissions(ir, owner_id) do
    step_nodes =
      ir
      |> Map.get("nodes", [])
      |> Enum.filter(&Functions.is_step_node?/1)

    Enum.reduce_while(step_nodes, :ok, fn node, _acc ->
      fn_name      = node["function"]
      act_as       = node["act_as_user_id"]
      target_user  = act_as || owner_id

      case Catalog.lookup(fn_name) do
        {:ok, m} ->
          ctx = %{user_id: owner_id, act_as_user_id: act_as}
          args = Map.get(node, "args", %{})
          target =
            try do
              m.permission_target_fn.(args, %{user_id: target_user, act_as_user_id: act_as})
            rescue
              _ -> "creds:?:#{target_user}"
            end

          if PermissionsCore.can?(owner_id, m.permission, target) do
            {:cont, :ok}
          else
            denial = PermissionsCore.denial(owner_id, m.permission, target)
            {:halt, {:error, format_denial(node, fn_name, denial, ctx)}}
          end

        {:error, :unknown} ->
          if fn_name in Synthetics.list() do
            {:cont, :ok}
          else
            # check_functions_exist already catches truly-unknown
            # functions; this path is defensive.
            {:cont, :ok}
          end
      end
    end)
  end

  @doc """
  Format a `%Permissions.Denial{}` into the user-facing teaching
  error for the offending node. Includes the action, target, and
  remediation kinds so the chat can render a request_input.
  """
  @spec format_denial(map(), String.t(), Denial.t(), map()) :: String.t()
  def format_denial(node, fn_name, %Denial{} = d, _ctx) do
    remediation = Enum.map(d.remediation, fn {kind, text} -> "#{kind}: #{text}" end)
    "upsert_workflow: permission_denied at node #{node["id"]} (`#{fn_name}`). " <>
      "owner=#{d.caller_user_id} action=#{d.action} target=#{d.target} reason=#{d.reason}. " <>
      "Remediation: " <> Enum.join(remediation, "; ")
  end
end
