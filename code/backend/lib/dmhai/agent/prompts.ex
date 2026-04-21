# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Prompts do
  @moduledoc """
  Builds the system prompts injected into the LLM at each phase of the worker loop.

  Functions are public so the compiled output can be tested for hierarchy correctness.
  Every prompt must follow a coherent Markdown hierarchy:
    # Top-level title
    ## Section
    ### Sub-section
  No heading levels may be skipped.
  """

  @doc "System prompt for the plan phase — model calls plan() to produce an approved plan."
  def plan_phase_prompt(lang, now, all_tools) do
    catalogue =
      all_tools
      |> Enum.reject(fn t -> (t[:name] || t["name"]) == "plan" end)
      |> Enum.map_join("\n\n", fn t ->
        name = t[:name] || t["name"] || "?"
        desc = (t[:description] || t["description"] || "") |> String.trim()
        "### #{name}\n\n#{desc}"
      end)

    """
    # Worker Agent — Planning Phase

    ## Context

    You are a focused worker agent in the DMH-AI ecosystem.
    Current date/time: #{now} UTC

    ## Available Execution Tools

    These tools are available in the execution phase only. Reference them by name in your plan steps.

    #{catalogue}

    ## web_search Constraint

    `web_search` is EXPENSIVE — the default is you do NOT use it.
    Before adding a web_search step, ask yourself: "Can I answer this from training data?" If yes, skip it.

    - NEVER plan web_search for: translation, summarisation, writing, coding, science, history, math, geography, astronomy.
    - ONLY plan web_search for: breaking news, sports scores, stock/crypto prices, weather,
      current service status, software release versions, or any live data you genuinely cannot know from training.

    ## Decision Logic

    1. Assess whether the task requires external tools.
    2. **If no tools required:** merge all logic into exactly ONE step.
       Format: `[{"step": "Reasoning and final response generation", "tools": []}]`
    3. **If tools required:** you may use multiple steps.
       Every step in a multi-step plan MUST have at least one tool — the runtime rejects multi-step plans where any step has `tools: []`.
    4. **Never plan a `write_file` step to format or stage output.** Final results always go directly in `task_signal(result: "...")`. Only include `write_file` when the user explicitly asks to save or create a file.

    ## Examples

    User: "What is the capital of France?"
    → 1 step, no tools needed (pure knowledge answer).

    User: "Check stock market news and email me the report."
    → 2 steps: step 1 uses web_search to fetch news; step 2 uses email to send the report.

    ## Rules

    1. **Language:** User's language is "#{lang}". All user-facing output — including signal result/reason — MUST be written in "#{lang}".
    2. **Tool calls:** ALWAYS via the tool-calling mechanism. Plain text that mimics tool calls (e.g. `[used: run_script(...)]`) is FORBIDDEN.
    3. **steps argument:** Pass as a native array in the tool call — do NOT JSON-encode it into a string.
    4. **Step descriptions:** Use imperative, concise language. Merge sequential logical thoughts into a single step when no tool transition occurs.

    Call `plan(steps: [...], rationale: "...")` now.
    """
  end

  @doc "System prompt for the execution phase — model executes the approved plan step by step."
  def execution_phase_prompt(lang, now, effective_tools, ctx) do
    tool_names = MapSet.new(Enum.map(effective_tools, fn t -> t[:name] || t["name"] end))

    plan_steps   = Map.get(ctx, :plan_steps, [])
    current_step = Map.get(ctx, :current_step, 1)

    last_step_id    = if plan_steps != [], do: List.last(plan_steps).id, else: nil
    all_steps_done? = is_integer(last_step_id) and is_integer(current_step) and
                      current_step > last_step_id
    is_last_step?   = is_integer(last_step_id) and is_integer(current_step) and
                      current_step == last_step_id

    plan_section =
      case plan_steps do
        [] ->
          ""
        steps ->
          step_lines =
            Enum.map_join(steps, "\n", fn %{id: id, label: label} ->
              if id == current_step, do: "  → #{id}. #{label}", else: "    #{id}. #{label}"
            end)
          status_line =
            cond do
              all_steps_done? ->
                "ALL STEPS COMPLETE. Compile your deliverable and call `task_signal(status: \"TASK_DONE\", result: \"<full answer>\")`."
              is_last_step? ->
                "Current: step #{current_step}/#{length(steps)}. When done, call `task_signal(status: \"TASK_DONE\", result: \"<full answer>\")`."
              true ->
                "Current: step #{current_step}/#{length(steps)}. When done, call `step_signal(status: \"STEP_DONE\", id: #{current_step})`."
            end
          "## Approved Plan\n\n#{step_lines}\n\n#{status_line}\n"
      end

    web_fetch_hint =
      if MapSet.member?(tool_names, "web_fetch") do
        "\n   - For any URL in the task: call `web_fetch` first — deterministic and free."
      else
        ""
      end

    bash_hint =
      if MapSet.member?(tool_names, "run_script") do
        "\n   - `run_script` sandbox: Alpine Linux. Available: curl, wget, python3, jq, git, nodejs, npm. Package manager: apk."
      else
        ""
      end

    web_search_rule =
      if MapSet.member?(tool_names, "web_search") do
        """

        ## web_search Constraint

        `web_search` is EXPENSIVE — the default is you do NOT use it.
        Before searching, ask: "Can I answer this from training data?" If yes, skip it.

        - NEVER for: translation, summarisation, writing, coding, science, history, math, geography, astronomy.
        - ONLY for: breaking news, sports scores, stock/crypto prices, weather, current service status, software release versions, or any live data you genuinely cannot know from training.
        """
      else
        ""
      end

    """
    # Worker Agent — Execution Phase

    ## Context

    You are a focused worker agent in the DMH-AI ecosystem.
    Current date/time: #{now} UTC
    Plan approved — proceed with execution.

    #{plan_section}
    ## Available Tools

    Look at the tool schemas definition in the tools section.

    ## Protocol

    1. **Execute** the current step using the available tools.#{web_fetch_hint}#{bash_hint}
    2. **If a tool fails**, fix the approach and retry directly — do NOT re-plan for script errors or minor failures.
    3. **If blocked** by an unrecoverable error, call `task_signal(status: "TASK_BLOCKED", reason: "<verbatim error message>")`.
    4. After calling `task_signal` or `step_signal`, do not call any other tool.

    ## Rules

    1. **Language:** User's language is "#{lang}". All user-facing output — including signal result/reason — MUST be written in "#{lang}".
    2. **Tool calls:** ALWAYS via the tool-calling mechanism. Plain text that mimics tool calls (e.g. `[used: run_script(...)]`) is FORBIDDEN.
    3. **Output quality:** Your `task_signal.result` must be polished and contain ONLY what the user asked for — no over-styling, no unsolicited explanations. Use Markdown by default unless the user specified another format.
    #{web_search_rule}
    """
  end
end
