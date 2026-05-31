# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.Wait do
  @moduledoc """
  Wait-node handler. Opens a wait row for the matching event (webhook
  or schedule) with an optional `timeout_seconds` deadline; the run
  suspends until the matching event fires or the deadline passes.

  Also owns the resume-side `find_next_after_wait/3` helper, which
  picks the post-wait next node id from the wait node's IR
  (`on_fire` for kind-specific routing, falling back to `next`).
  """

  alias DmhAi.Workflows
  require Logger

  @doc """
  Top-level wait handler invoked by the walker's `dispatch_node/4`.
  """
  def handle_wait(_ir, node, state, _n) do
    timeout_s = Map.get(node, "timeout_seconds")
    expires   = timeout_s && System.os_time(:second) + timeout_s

    pred = %{
      "trigger"      => Map.get(node, "trigger", %{}),
      "node_id"      => node["id"]
    }

    kind =
      case Map.get(node, "trigger", %{}) |> Map.get("kind") do
        "webhook"  -> :webhook
        "schedule" -> :schedule
        _          -> :webhook
      end

    step_id = Workflows.open_step(state.id, node["id"], pred)
    Workflows.close_step(step_id, :waiting,
      waiting_on: %{kind: kind, predicate: pred, expires_at: expires})

    :ok = Workflows.add_wait(state.id, node["id"], kind, pred, expires)
    Logger.info("[Executor] suspended at wait run=#{state.id} node=#{node["id"]}")
    {:ok, Workflows.get_run!(state.id)}
  end

  @doc """
  Look up the next node id to walk to once a wait has fired. The IR's
  `on_fire` wins when present; otherwise we fall through to `next`.
  Returns `nil` when the wait node has no outgoing edge (terminal
  wait — unusual but legal).
  """
  def find_next_after_wait(_ir, %{"on_fire" => nid}, _payload), do: nid
  def find_next_after_wait(_ir, %{"next" => nid}, _payload),    do: nid
  def find_next_after_wait(_ir, _, _), do: nil
end
