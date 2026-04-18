# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.Plan do
  @moduledoc """
  Worker PLAN phase tool.

  The worker MUST call this as its FIRST action before executing any task.
  The runtime runs a Police scan on the submitted plan and either approves
  it (allowing the worker to proceed) or rejects it (requiring revision).
  """

  @behaviour Dmhai.Tools.Behaviour

  @impl true
  def name, do: "plan"

  @impl true
  def description,
    do:
      "Submit your execution plan before taking any action. MUST be called first in every task. " <>
        "List every step you intend to take. The runtime will approve or reject the plan. " <>
        "Only after approval may you proceed with tool calls."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          steps: %{
            type: "array",
            items: %{type: "string"},
            description: "Ordered list of steps you will take to complete the task."
          },
          rationale: %{
            type: "string",
            description: "Brief explanation of your overall approach (1-3 sentences)."
          }
        },
        required: ["steps"]
      }
    }
  end

  @impl true
  def execute(%{"steps" => steps} = args, ctx) when is_list(steps) and steps != [] do
    rationale = Map.get(args, "rationale", "")
    plan_text = format_plan(steps, rationale)
    ctx_with_count = Map.put(ctx, :plan_step_count, length(steps))

    case Dmhai.Agent.Police.check_plan(plan_text, ctx_with_count) do
      :ok ->
        {:ok, "Plan approved. Proceed with execution step by step."}

      {:rejected, reason} ->
        {:error, "Plan rejected: #{reason}. Revise your plan and resubmit before proceeding."}
    end
  end

  def execute(%{"steps" => []}, _ctx),
    do: {:error, "steps must be a non-empty list of action strings"}

  def execute(_, _), do: {:error, "Missing required argument: steps (array of strings)"}

  defp format_plan(steps, rationale) do
    step_lines =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} -> "#{i}. #{s}" end)

    if is_binary(rationale) and rationale != "" do
      "Rationale: #{rationale}\n\nSteps:\n#{step_lines}"
    else
      step_lines
    end
  end
end
