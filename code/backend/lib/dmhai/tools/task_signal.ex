# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.TaskSignal do
  @moduledoc """
  Worker terminal-contract tool. Every task MUST end with a call to this.

  status = "TASK_DONE"    → companion arg: `result` (required) — the final report
                            compiled by the worker to present to the user.
  status = "TASK_BLOCKED" → companion arg: `reason` (required) — verbatim error message.

  Writes a `kind='final'` row to worker_status. The runtime scheduler
  detects this row and transitions the task to its terminal state.
  The worker loop sees this tool's return and exits gracefully.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.WorkerStatus
  require Logger

  @impl true
  def name, do: "task_signal"

  @impl true
  def description,
    do:
      "Terminate the task. " <>
        "TASK_DONE: result=<your full answer/report for the user> (required, non-empty). " <>
        "TASK_BLOCKED: reason=<verbatim error>. No further calls after this."

  @impl true
  def execute(%{"status" => status} = args, ctx) do
    task_id   = Map.get(ctx, :task_id)
    worker_id = Map.get(ctx, :worker_id, "unknown")
    status    = String.upcase(to_string(status))

    cond do
      status not in ["TASK_DONE", "TASK_BLOCKED"] ->
        {:error, "status must be 'TASK_DONE' or 'TASK_BLOCKED', got: #{inspect(status)}"}

      status == "TASK_DONE" and (args["result"] || "") |> String.trim() == "" ->
        {:error, "task_signal(TASK_DONE) requires a non-empty 'result' — compile the final report to present to the user"}

      status == "TASK_BLOCKED" and args["reason"] in [nil, ""] ->
        {:error, "task_signal(TASK_BLOCKED) requires a non-empty 'reason' argument"}

      is_nil(task_id) ->
        {:error, "task_signal called without task_id in context — runtime misconfiguration"}

      true ->
        payload = args["result"] || args["reason"] || ""
        WorkerStatus.append(task_id, worker_id, "final", payload, status)
        Logger.info("[TaskSignal] task=#{task_id} status=#{status}")
        {:ok, "Task signal recorded (#{status}). Do not call any further tools."}
    end
  end

  def execute(_args, _ctx), do: {:error, "task_signal requires a 'status' argument"}

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
            enum: ["TASK_DONE", "TASK_BLOCKED"],
            description: "TASK_DONE when the entire task is finished; TASK_BLOCKED when you cannot recover from an error."
          },
          result: %{
            type: "string",
            description: "Required when status='TASK_DONE'. The final report/answer compiled by the worker to present to the user."
          },
          reason: %{
            type: "string",
            description: "Required when status='TASK_BLOCKED'. The verbatim error message."
          }
        },
        required: ["status"]
      }
    }
  end
end
