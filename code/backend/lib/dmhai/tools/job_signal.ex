# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.JobSignal do
  @moduledoc """
  Worker terminal-contract tool. Every job MUST end with a call to this.

  status = "JOB_DONE"    → companion arg: `result` (required) — the final report
                            compiled by the worker to present to the user.
  status = "JOB_BLOCKED" → companion arg: `reason` (required) — verbatim error message.

  Writes a `kind='final'` row to worker_status. The runtime scheduler
  detects this row and transitions the job to its terminal state.
  The worker loop sees this tool's return and exits gracefully.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.WorkerStatus
  require Logger

  @impl true
  def name, do: "job_signal"

  @impl true
  def description,
    do:
      "Terminate the job. " <>
        "JOB_DONE: result=<your full answer/report for the user> (required, non-empty). " <>
        "JOB_BLOCKED: reason=<verbatim error>. No further calls after this."

  @impl true
  def execute(%{"status" => status} = args, ctx) do
    job_id    = Map.get(ctx, :job_id)
    worker_id = Map.get(ctx, :worker_id, "unknown")
    status    = String.upcase(to_string(status))

    cond do
      status not in ["JOB_DONE", "JOB_BLOCKED"] ->
        {:error, "status must be 'JOB_DONE' or 'JOB_BLOCKED', got: #{inspect(status)}"}

      status == "JOB_DONE" and (args["result"] || "") |> String.trim() == "" ->
        {:error, "job_signal(JOB_DONE) requires a non-empty 'result' — compile the final report to present to the user"}

      status == "JOB_BLOCKED" and args["reason"] in [nil, ""] ->
        {:error, "job_signal(JOB_BLOCKED) requires a non-empty 'reason' argument"}

      is_nil(job_id) ->
        {:error, "job_signal called without job_id in context — runtime misconfiguration"}

      true ->
        payload = args["result"] || args["reason"] || ""
        WorkerStatus.append(job_id, worker_id, "final", payload, status)
        Logger.info("[JobSignal] job=#{job_id} status=#{status}")
        {:ok, "Job signal recorded (#{status}). Do not call any further tools."}
    end
  end

  def execute(_args, _ctx), do: {:error, "job_signal requires a 'status' argument"}

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
            enum: ["JOB_DONE", "JOB_BLOCKED"],
            description: "JOB_DONE when the entire job is finished; JOB_BLOCKED when you cannot recover from an error."
          },
          result: %{
            type: "string",
            description: "Required when status='JOB_DONE'. The final report/answer compiled by the worker to present to the user."
          },
          reason: %{
            type: "string",
            description: "Required when status='JOB_BLOCKED'. The verbatim error message."
          }
        },
        required: ["status"]
      }
    }
  end
end
