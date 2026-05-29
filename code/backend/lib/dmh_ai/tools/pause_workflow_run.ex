# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.PauseWorkflowRun do
  @moduledoc """
  Pause an in-flight workflow instance. Sets the run's `paused` flag;
  the executor checks the flag at every step boundary and halts
  AFTER the current step completes (never mid-step — a connector
  HTTP call in flight finishes cleanly).

  Pause is recoverable: `resume_workflow_run` clears the flag and
  the runtime drives the executor onward. Cancel is a separate
  terminal verb (`cancel_workflow_run`).

  Idempotent — pausing an already-paused run is a no-op.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Workflows
  require Logger

  @impl true
  def name, do: "pause_workflow_run"

  @impl true
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    "Pause a running workflow instance. Halts AFTER the current step " <>
      "completes. Use `resume_workflow_run` to continue. Required arg: run_id."
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
            description: "The instance id from `workflow_run_state`. Get it from `invoke_workflow`'s return or `/workflows/<slug>/runs`."
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
        case Workflows.set_paused(r, true) do
          :ok ->
            Logger.info("[PauseWorkflowRun] run=#{r}")
            {:ok, %{"run_id" => r, "paused" => true}}

          {:error, :run_not_found} ->
            {:error, "pause_workflow_run: no run with id `#{r}`"}

          {:error, {:terminal_status, s}} ->
            {:error, "pause_workflow_run: run `#{r}` is already terminal (status=#{s}); cannot pause"}

          {:error, other} ->
            {:error, "pause_workflow_run: #{inspect(other)}"}
        end

      _ ->
        {:error, "pause_workflow_run: `run_id` required (string)"}
    end
  end
end
