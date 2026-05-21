# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Runs do
  @moduledoc """
  Read-only HTTP surface for the workflow-run viewer:

      GET /runs/:run_id     → returns the run's status + trigger payload
                              + bindings.emits + per-node label join,
                              plus the workflow header so the FE can
                              link back to the IR viewer.

  Org-scoping: a user can only read runs in their own org. Cross-org
  reads return 403. Authentication is required (AuthPlug).

  This is the surface the model links to in chat replies after
  `invoke_workflow` returns — `run_url: "/runs/<run_id>"`. The user
  sees the actual emit values produced by the executor, not the
  static IR.
  """

  alias DmhAi.{Workflows, Constants}
  alias DmhAi.Handlers.Proxy
  require Logger

  @doc """
  GET /runs/:run_id
  """
  def show(conn, user, run_id) when is_binary(run_id) do
    org_id = Map.get(user, :org_id) || Constants.default_org_id()

    case Workflows.get_run(run_id) do
      nil ->
        Proxy.json(conn, 404, %{error: "run_not_found", run_id: run_id})

      run when run.org_id == org_id ->
        wf  = Workflows.get_workflow(org_id, run.workflow_id)
        ver = Workflows.get_version(org_id, run.workflow_id, run.workflow_version)

        # Resolve output nodes from the IR so the FE can render
        # "Results" prominently (vs the raw bindings dump). Output
        # nodes carry an `emit:` map declaration; the executor's
        # resolved values land in `bindings.emits["<node_id>"]`.
        output_nodes =
          (ver && ver.ir |> Map.get("nodes", []) |> Enum.filter(&(&1["kind"] == "output"))) || []

        emits = Map.get(run.bindings, "emits", %{})

        outputs =
          Enum.map(output_nodes, fn node ->
            id_str = node["id"] |> to_string()
            %{
              node_id:  node["id"],
              label:    node["label"],
              declared: Map.get(node, "emit", %{}),
              resolved: Map.get(emits, id_str, %{})
            }
          end)

        # All node emits (for a Debug tab, mirroring workflow viewer's
        # Specification tab). Indexed by node_id → emit map.
        all_emits =
          emits
          |> Enum.map(fn {k, v} -> %{node_id: maybe_int(k), values: v} end)
          |> Enum.sort_by(& &1.node_id)

        Proxy.json(conn, 200, %{
          run: %{
            id:               run.id,
            workflow_id:      run.workflow_id,
            workflow_version: run.workflow_version,
            task_id:          run.task_id,
            owner_user_id:    run.owner_user_id,
            status:           run.status,
            last_error:       run.last_error,
            trigger_payload:  run.trigger_payload,
            started_at:       run.started_at,
            updated_at:       run.updated_at,
            completed_at:     run.completed_at,
            current_node:     run.current_node
          },
          outputs:   outputs,
          all_emits: all_emits,
          workflow:
            wf && %{
              id:           wf.id,
              display_name: wf.display_name,
              description:  wf.description,
              created_by:   wf.created_by
            }
        })

      _other_org ->
        Logger.warning("[Runs] cross-org read attempt user=#{user.id || "?"} run=#{run_id}")
        Proxy.json(conn, 403, %{error: "forbidden"})
    end
  end

  defp maybe_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _       -> s
    end
  end

  defp maybe_int(v), do: v
end
