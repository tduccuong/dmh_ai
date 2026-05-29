# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.CancelWorkflowRun do
  @moduledoc """
  Cancel a workflow instance. Terminal — the run's status flips to
  `cancelled` and cannot be undone. The executor sees the new
  status on its next step boundary and halts the walk; an
  in-flight connector HTTP call completes naturally (no abort
  mid-call).

  Cancelling an already-terminal run is rejected (you can't cancel
  something that completed / failed / was already cancelled).
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Workflows
  require Logger

  @impl true
  def name, do: "cancel_workflow_run"

  @impl true
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    "Cancel a workflow instance. Terminal. The current step finishes " <>
      "naturally; no further steps run. Required arg: run_id."
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          run_id: %{
            type:        "string",
            description: "The instance id from `workflow_run_state`."
          }
        },
        required: ["run_id"]
      }
    }
  end

  @impl true
  def execute(args, _ctx) do
    case Map.get(args, "run_id") do
      r when is_binary(r) and r != "" ->
        case Workflows.cancel_run(r) do
          :ok ->
            Logger.info("[CancelWorkflowRun] run=#{r}")
            {:ok, %{"run_id" => r, "status" => "cancelled"}}

          {:error, :run_not_found} ->
            {:error, "cancel_workflow_run: no run with id `#{r}`"}

          {:error, {:terminal_status, s}} ->
            {:error, "cancel_workflow_run: run `#{r}` is already terminal (status=#{s}); cannot cancel"}

          {:error, other} ->
            {:error, "cancel_workflow_run: #{inspect(other)}"}
        end

      _ ->
        {:error, "cancel_workflow_run: `run_id` required (string)"}
    end
  end
end
