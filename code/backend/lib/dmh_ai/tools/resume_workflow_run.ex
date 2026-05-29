# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ResumeWorkflowRun do
  @moduledoc """
  Resume a paused workflow instance. Clears the run's `paused` flag.

  Resume only un-pauses the flag — it does NOT itself spin the
  executor forward; that's a runtime concern (the executor is
  driven by ticks / events; clearing the flag lets it proceed on
  its next opportunity).

  Idempotent — resuming an un-paused run is a no-op.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Workflows
  require Logger

  @impl true
  def name, do: "resume_workflow_run"

  @impl true
  def catalog_manifest, do: %{write_class: :write}

  @impl true
  def description do
    "Resume a paused workflow instance. Clears the `paused` flag; the " <>
      "executor proceeds on its next step boundary. Required arg: run_id."
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
        case Workflows.set_paused(r, false) do
          :ok ->
            Logger.info("[ResumeWorkflowRun] run=#{r}")
            {:ok, %{"run_id" => r, "paused" => false}}

          {:error, :run_not_found} ->
            {:error, "resume_workflow_run: no run with id `#{r}`"}

          {:error, {:terminal_status, s}} ->
            {:error, "resume_workflow_run: run `#{r}` is already terminal (status=#{s}); cannot resume"}

          {:error, other} ->
            {:error, "resume_workflow_run: #{inspect(other)}"}
        end

      _ ->
        {:error, "resume_workflow_run: `run_id` required (string)"}
    end
  end
end
