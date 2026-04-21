# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.StepSignal do
  @moduledoc """
  Non-terminal step contract tool. Called at the end of each execution step.

  status = "STEP_DONE"    → args: id (step id)
  status = "STEP_BLOCKED" → args: id + reason (verbatim blocker)
  status = "PLAN_REVISE"  → args: new_steps (list) + reason

  Writes a step_done / step_blocked / plan_revision row to worker_status.
  Non-terminal — the worker loop continues after this call.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.WorkerStatus
  require Logger

  @impl true
  def name, do: "step_signal"

  @impl true
  def description,
    do:
      "Signal the completion or blocking of a single execution step. " <>
        "STEP_DONE: step complete — runtime advances to the next step. " <>
        "STEP_BLOCKED: step cannot proceed — provide id and reason; runtime will retry or unblock. " <>
        "PLAN_REVISE: overall plan must change — provide new_steps and reason; await re-approval."

  @impl true
  def execute(%{"status" => status} = args, ctx) do
    task_id    = Map.get(ctx, :task_id)
    worker_id = Map.get(ctx, :worker_id, "unknown")
    status    = String.upcase(to_string(status))

    cond do
      status not in ["STEP_DONE", "STEP_BLOCKED", "PLAN_REVISE"] ->
        {:error,
         "status must be 'STEP_DONE', 'STEP_BLOCKED', or 'PLAN_REVISE', got: #{inspect(status)}"}

      status in ["STEP_DONE", "STEP_BLOCKED"] and args["id"] in [nil, ""] ->
        {:error, "step_signal(#{status}) requires a non-empty 'id' argument"}

      status == "STEP_BLOCKED" and args["reason"] in [nil, ""] ->
        {:error, "step_signal(STEP_BLOCKED) requires a non-empty 'reason' argument"}

      status == "PLAN_REVISE" and not (is_list(args["new_steps"]) and args["new_steps"] != []) ->
        {:error, "step_signal(PLAN_REVISE) requires a non-empty 'new_steps' list"}

      status == "PLAN_REVISE" and args["reason"] in [nil, ""] ->
        {:error, "step_signal(PLAN_REVISE) requires a non-empty 'reason' argument"}

      is_nil(task_id) ->
        {:error, "step_signal called without task_id in context — runtime misconfiguration"}

      true ->
        {kind, content} =
          case status do
            "STEP_DONE"          -> {"step_done", "Step #{args["id"]}"}
            "STEP_BLOCKED"       -> {"step_blocked", args["reason"]}
            "PLAN_REVISE" ->
              payload = Jason.encode!(%{reason: args["reason"], new_steps: args["new_steps"]})
              {"plan_revision", payload}
          end

        WorkerStatus.append(task_id, worker_id, kind, content, status)
        Logger.info("[StepSignal] task=#{task_id} status=#{status} id=#{args["id"] || "—"}")

        msg =
          case status do
            "STEP_DONE"          -> "Step #{args["id"]} done. Proceed to the next step."
            "STEP_BLOCKED"       -> "Step #{args["id"]} blocked. The runtime will provide guidance."
            "PLAN_REVISE" -> "Plan revision request recorded. Await re-approval before continuing."
          end

        {:ok, msg}
    end
  end

  def execute(_args, _ctx), do: {:error, "step_signal requires a 'status' argument"}

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          status: %{
            type: "string",
            enum: ["STEP_DONE", "STEP_BLOCKED", "PLAN_REVISE"],
            description:
              "STEP_DONE when the step is complete; " <>
                "STEP_BLOCKED when the step cannot proceed; " <>
                "PLAN_REVISE when the overall plan must change."
          },
          id: %{
            type: "string",
            description: "Required for STEP_DONE and STEP_BLOCKED. The step identifier (e.g. '1', '2')."
          },
          reason: %{
            type: "string",
            description:
              "Required for STEP_BLOCKED and PLAN_REVISE. " <>
                "Verbatim error or explanation of why the plan must change."
          },
          new_steps: %{
            type: "array",
            items: %{type: "string"},
            description: "Required for PLAN_REVISE. The replacement plan steps."
          }
        },
        required: ["status"]
      }
    }
  end
end
