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
            items: %{
              type: "object",
              properties: %{
                step: %{type: "string", description: "Short, clear description of this chunk of work."},
                tools: %{
                  type: "array",
                  items: %{type: "string"},
                  description:
                    "Execution tools this step will call. " <>
                    "Required for every step in a multi-step plan — runtime REJECTS 2+ step plans where any step has tools: []."
                }
              },
              required: ["step", "tools"]
            },
            description:
              "Ordered list of steps. Each step must have a 'step' string and a 'tools' array. " <>
              "Single-step plans may have tools: [] for pure knowledge answers. " <>
              "Multi-step plans MUST have at least one tool per step — runtime rejects any step with tools: []."
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
    invalid =
      Enum.reject(steps, fn s ->
        is_map(s) and is_binary(s["step"]) and s["step"] != "" and is_list(s["tools"])
      end)

    if invalid != [] do
      {:error,
       "Each step must be an object with 'step' (string) and 'tools' (array). " <>
         "Wrong: \"plain string\" or {\"step\": \"...\"} with no tools field. " <>
         "Correct: {\"step\": \"fetch the docs\", \"tools\": [\"web_fetch\"]}."}
    else
      rationale = Map.get(args, "rationale", "")
      plan_text = format_plan(steps, rationale)

      ctx_with_meta =
        ctx
        |> Map.put(:plan_step_count, length(steps))
        |> Map.put(:plan_steps_raw, steps)

      case Dmhai.Agent.Police.check_plan(plan_text, ctx_with_meta) do
        :ok ->
          {:ok, "Plan approved. Proceed with execution step by step."}

        {:rejected, reason} ->
          {:error, "Plan rejected: #{reason}. Revise your plan and resubmit before proceeding."}
      end
    end
  end

  def execute(%{"steps" => steps_str} = args, ctx) when is_binary(steps_str) do
    case Jason.decode(steps_str) do
      {:ok, steps} when is_list(steps) and steps != [] ->
        execute(%{args | "steps" => steps}, ctx)
      {:ok, _} ->
        {:error,
         "steps must be a non-empty array of step objects. " <>
         "Do NOT JSON-encode the steps value — pass it directly as a JSON array, not as a string."}
      {:error, _} ->
        {:error,
         "steps contains malformed JSON. " <>
         "Do NOT JSON-encode the steps value — pass it directly as a JSON array, not as a string."}
    end
  end

  def execute(%{"steps" => []}, _ctx),
    do: {:error, "steps must be a non-empty list of step objects"}

  def execute(_, _), do: {:error, "Missing required argument: steps (array of step objects)"}

  defp format_plan(steps, rationale) do
    step_lines =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} ->
        label     = s["step"] || ""
        tools     = s["tools"] || []
        tools_str = if tools != [], do: " [tools: #{Enum.join(tools, ", ")}]", else: ""
        "#{i}. #{label}#{tools_str}"
      end)

    if is_binary(rationale) and rationale != "" do
      "Rationale: #{rationale}\n\nSteps:\n#{step_lines}"
    else
      step_lines
    end
  end
end
