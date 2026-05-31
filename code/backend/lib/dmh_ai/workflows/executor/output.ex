# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.Output do
  @moduledoc """
  Output-node handler. Resolves the node's `emit` map against the run
  bindings, persists it as the step's output, and completes the run.
  Terminal — there is no `next` edge to follow.
  """

  alias DmhAi.Workflows
  alias DmhAi.Workflows.Executor.Bindings
  require Logger

  @doc """
  Top-level output handler invoked by the walker's `dispatch_node/4`.
  """
  def handle_output(_ir, node, state) do
    raw_emit = Map.get(node, "emit", %{})
    emit     = Bindings.resolve_args(raw_emit, state)
    step_id  = Workflows.open_step(state.id, node["id"], raw_emit)
    Workflows.close_step(step_id, :completed, output: emit)

    new_bindings = Bindings.put_emits(state.bindings, node["id"], emit)
    :ok = Workflows.update_run(state.id, %{bindings: new_bindings})
    :ok = Workflows.complete_run(state.id, :completed)
    Logger.info("[Executor] completed run=#{state.id} via node=#{node["id"]}")
    {:ok, Workflows.get_run!(state.id)}
  end
end
