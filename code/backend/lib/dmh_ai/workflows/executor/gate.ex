# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.Gate do
  @moduledoc """
  Gate-node handler. Opens an approval wait keyed by the gate's
  `approver` predicate and suspends the run. The approver receives a
  notification via Primitive 0.4; `Executor.resume_run/2` fires when
  the decision lands.
  """

  alias DmhAi.Workflows
  require Logger

  @doc """
  Top-level gate handler invoked by the walker's `dispatch_node/4`.
  """
  def handle_gate(_ir, node, state, _n) do
    # Suspend at the gate. The approver receives a notification
    # via Primitive 0.4; on decision, resume_run/2 fires.
    pred = %{
      "approver"     => Map.get(node, "approver", %{}),
      "context"      => Map.get(node, "context", %{}),
      "node_id"      => node["id"]
    }

    step_id = Workflows.open_step(state.id, node["id"],
      %{approver: pred["approver"], context: pred["context"]})
    Workflows.close_step(step_id, :waiting, waiting_on: %{kind: "approval", predicate: pred})

    :ok = Workflows.add_wait(state.id, node["id"], :approval, pred)
    Logger.info("[Executor] suspended at gate run=#{state.id} node=#{node["id"]}")
    {:ok, Workflows.get_run!(state.id)}
  end
end
