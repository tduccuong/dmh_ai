# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.Signal do
  @moduledoc """
  Worker terminal-contract tool. Every job MUST end with a call to this.

  status = "JOB_DONE"  → companion arg: `result` (the final answer in Markdown)
  status = "BLOCKED"   → companion arg: `reason` (verbatim error message)

  Writes a `kind='final'` row to worker_status. The runtime scheduler
  detects this row and transitions the job to its terminal state.
  The worker loop sees this tool's return and exits gracefully.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.WorkerStatus
  require Logger

  @impl true
  def name, do: "signal"

  @impl true
  def description,
    do:
      "Terminate the job by signalling completion or a hard block. " <>
        "status='JOB_DONE' with result=<final answer> when work is finished. " <>
        "status='BLOCKED' with reason=<verbatim error> when you cannot proceed. " <>
        "After calling this, stop — no further tool calls."

  @impl true
  def execute(%{"status" => status} = args, ctx) do
    job_id    = Map.get(ctx, :job_id)
    worker_id = Map.get(ctx, :worker_id, "unknown")
    status    = String.upcase(to_string(status))

    cond do
      status not in ["JOB_DONE", "BLOCKED"] ->
        {:error, "status must be 'JOB_DONE' or 'BLOCKED', got: #{inspect(status)}"}

      status == "JOB_DONE" and (args["result"] in [nil, ""]) ->
        {:error, "signal(JOB_DONE) requires a non-empty 'result' argument"}

      status == "BLOCKED" and (args["reason"] in [nil, ""]) ->
        {:error, "signal(BLOCKED) requires a non-empty 'reason' argument"}

      is_nil(job_id) ->
        {:error, "signal called without job_id in context — runtime misconfiguration"}

      true ->
        payload = args["result"] || args["reason"]
        WorkerStatus.append(job_id, worker_id, "final", payload, status)
        Logger.info("[Signal] job=#{job_id} status=#{status} chars=#{String.length(to_string(payload))}")
        {:ok, "Signal recorded (#{status}). Do not call any further tools."}
    end
  end

  def execute(_args, _ctx), do: {:error, "signal requires a 'status' argument"}

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
            enum: ["JOB_DONE", "BLOCKED"],
            description: "JOB_DONE when finished; BLOCKED when you cannot proceed."
          },
          result: %{
            type: "string",
            description: "Required when status='JOB_DONE'. The final answer in Markdown."
          },
          reason: %{
            type: "string",
            description: "Required when status='BLOCKED'. The verbatim error message."
          }
        },
        required: ["status"]
      }
    }
  end
end
