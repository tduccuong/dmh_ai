# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.Trigger do
  @moduledoc """
  The trigger node behaves differently per `trigger_kind`:

    * `manual`   — `state.bindings["trigger"]` is the invoke_workflow
                   caller's payload. Pass through to `next`; downstream
                   refs use `{{T.<field>}}` to bind against it.

    * `poll` / `schedule`
                 — execute the trigger's `connector_function` with
                   `connector_args` and bind the result as node 0's
                   emits. Same shape an autonomous poller fire would
                   produce, run synchronously inside the executor. A
                   manual `invoke_workflow` against a polled workflow
                   ends up running ONE synthetic poll cycle and the
                   rest of the IR — this is "test the workflow with
                   current data" from the user's perspective.

    * `webhook`  — `state.bindings["trigger"]` is the synthetic
                   event payload supplied by the invoke caller. Bind
                   it as node 0's emits so `{{0.<field>}}` refs
                   resolve the same way they would for an
                   autonomous webhook fire.
  """

  alias DmhAi.Workflows
  alias DmhAi.Workflows.Executor
  alias DmhAi.Workflows.Executor.{Bindings, StepDispatch}

  @doc """
  Top-level trigger handler invoked by the walker's `dispatch_node/4`.
  """
  def handle_trigger(ir, node, state, n) do
    case Map.get(node, "trigger_kind", "manual") do
      "manual" ->
        next = Executor.find_node_by_id(ir, node["next"])
        Executor.walk(ir, next, state, n + 1)

      kind when kind in ["poll", "schedule"] ->
        run_polled_trigger(ir, node, state, n)

      "webhook" ->
        run_webhook_trigger(ir, node, state, n)

      other ->
        err = %{
          error:        :unknown_trigger_kind,
          trigger_kind: other,
          node_id:      node["id"],
          hint:         "trigger_kind must be one of: manual, poll, schedule, webhook"
        }
        :ok = Workflows.complete_run(state.id, :failed, err)
        {:error, err}
    end
  end

  defp run_polled_trigger(ir, node, state, n) do
    fn_name = node["connector_function"]
    args    = Bindings.resolve_args(node["connector_args"] || %{}, state)

    if not is_binary(fn_name) or fn_name == "" do
      err = %{
        error:   :trigger_misconfigured,
        node_id: node["id"],
        hint:    "trigger_kind=#{node["trigger_kind"]} requires `connector_function` (the function the runtime polls/schedules)"
      }
      :ok = Workflows.complete_run(state.id, :failed, err)
      {:error, err}
    else
      step_id = Workflows.open_step(state.id, node["id"],
        %{function: fn_name, args: args, trigger_kind: node["trigger_kind"]})

      case StepDispatch.dispatch_step(fn_name, args, node, state) do
        {:ok, result} ->
          emit         = Bindings.extract_emits(node, result)
          Workflows.close_step(step_id, :completed, output: emit)
          new_bindings = Bindings.put_emits(state.bindings, node["id"], emit)
          :ok          = Workflows.update_run(state.id, %{bindings: new_bindings})
          next         = Executor.find_node_by_id(ir, node["next"])
          Executor.walk(ir, next, %{state | bindings: new_bindings}, n + 1)

        {:error, e} ->
          err = %{
            error:    :trigger_failed,
            node_id:  node["id"],
            function: fn_name,
            detail:   Executor.encode_err(e)
          }
          Workflows.close_step(step_id, :failed, error: err)
          :ok = Workflows.complete_run(state.id, :failed, err)
          {:error, err}
      end
    end
  end

  defp run_webhook_trigger(ir, node, state, n) do
    payload = state.bindings["trigger"] || state.bindings[:trigger] || %{}
    step_id = Workflows.open_step(state.id, node["id"],
      %{trigger_kind: node["trigger_kind"], payload: payload})

    emit    = Bindings.extract_emits(node, payload)
    Workflows.close_step(step_id, :completed, output: emit)
    new_bindings = Bindings.put_emits(state.bindings, node["id"], emit)
    :ok = Workflows.update_run(state.id, %{bindings: new_bindings})
    next = Executor.find_node_by_id(ir, node["next"])
    Executor.walk(ir, next, %{state | bindings: new_bindings}, n + 1)
  end
end
