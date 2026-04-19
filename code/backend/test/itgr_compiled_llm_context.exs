# Verifies that every compiled LLM system prompt conforms to a coherent Markdown
# heading hierarchy before it is injected into any LLM call.
#
# Valid hierarchy rules:
#   1. The first heading must be level 1 (#).
#   2. Heading levels must never skip more than one level going deeper
#      (e.g. # → ### is illegal; # → ## → ### is fine).
#   3. Headings inside fenced code blocks (``` ... ```) are ignored.
#
# Run with: MIX_ENV=test mix test test/itgr_compiled_llm_context.exs

defmodule Itgr.CompiledLlmContext do
  use ExUnit.Case, async: true

  alias Dmhai.Agent.{Prompts, SystemPrompt}
  alias Dmhai.Tools.Registry, as: ToolRegistry

  @all_tools ToolRegistry.all_definitions()
  @now       "2026-04-19T12:00"
  @lang      "en"

  # ── Hierarchy helpers ────────────────────────────────────────────────────────

  # Returns [{level, heading_text}] for all headings outside code fences.
  defp extract_headings(text) do
    {headings, _in_code} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {acc, in_code} ->
        stripped = String.trim_leading(line, " ")
        cond do
          String.starts_with?(stripped, "```") ->
            {acc, !in_code}

          in_code ->
            {acc, in_code}

          true ->
            case String.split(stripped, " ", parts: 2) do
              [hashes, _rest] when hashes != "" ->
                if String.match?(hashes, ~r/^[#]+$/) do
                  {[{String.length(hashes), stripped} | acc], in_code}
                else
                  {acc, in_code}
                end

              _ ->
                {acc, in_code}
            end
        end
      end)

    Enum.reverse(headings)
  end

  defp assert_valid_hierarchy(text, label) do
    headings = extract_headings(text)

    assert headings != [],
      "#{label}: prompt has no Markdown headings at all"

    {first_level, first_text} = hd(headings)
    assert first_level == 1,
      "#{label}: first heading must be # (h1), got h#{first_level}: #{first_text}"

    Enum.reduce(headings, 0, fn {level, heading_text}, prev ->
      assert level <= prev + 1,
        "#{label}: heading level jumped from h#{prev} to h#{level} — skipped a level: \"#{heading_text}\""
      level
    end)

    :ok
  end

  # ── Plan phase ───────────────────────────────────────────────────────────────

  describe "plan_phase_prompt hierarchy" do
    test "valid — full tool registry" do
      Prompts.plan_phase_prompt(@lang, @now, @all_tools)
      |> assert_valid_hierarchy("plan/full_tools")
    end

    test "valid — empty tool list" do
      Prompts.plan_phase_prompt(@lang, @now, [])
      |> assert_valid_hierarchy("plan/empty_tools")
    end

    test "each tool appears as ### (h3) heading" do
      prompt   = Prompts.plan_phase_prompt(@lang, @now, @all_tools)
      headings = extract_headings(prompt)

      tool_names =
        @all_tools
        |> Enum.map(&(&1[:name] || &1["name"]))
        |> Enum.reject(&(&1 == "plan"))

      for name <- tool_names do
        assert Enum.any?(headings, fn {level, text} ->
                 level == 3 and String.contains?(text, name)
               end),
               "expected ### #{name} in plan phase prompt"
      end
    end

    test "web_search Constraint is ## (h2), not nested deeper" do
      prompt   = Prompts.plan_phase_prompt(@lang, @now, @all_tools)
      headings = extract_headings(prompt)
      matches  = Enum.filter(headings, fn {_, t} -> String.contains?(t, "web_search Constraint") end)

      assert matches != [], "expected 'web_search Constraint' heading"
      for {level, text} <- matches do
        assert level == 2, "web_search Constraint must be ## (h2), got h#{level}: #{text}"
      end
    end
  end

  # ── Execution phase ──────────────────────────────────────────────────────────

  describe "execution_phase_prompt hierarchy" do
    test "valid — no plan, no web_search" do
      tools = Enum.reject(@all_tools, &((&1[:name] || &1["name"]) == "web_search"))
      Prompts.execution_phase_prompt(@lang, @now, tools, %{})
      |> assert_valid_hierarchy("exec/no_plan_no_ws")
    end

    test "valid — no plan, with web_search" do
      Prompts.execution_phase_prompt(@lang, @now, @all_tools, %{})
      |> assert_valid_hierarchy("exec/no_plan_with_ws")
    end

    test "valid — mid-plan (step 1 of 3)" do
      steps = [%{id: 1, label: "Fetch data"}, %{id: 2, label: "Analyse"}, %{id: 3, label: "Report"}]
      Prompts.execution_phase_prompt(@lang, @now, @all_tools, %{plan_steps: steps, current_step: 1})
      |> assert_valid_hierarchy("exec/mid_plan_step1")
    end

    test "valid — last step" do
      steps = [%{id: 1, label: "Fetch"}, %{id: 2, label: "Deliver"}]
      Prompts.execution_phase_prompt(@lang, @now, @all_tools, %{plan_steps: steps, current_step: 2})
      |> assert_valid_hierarchy("exec/last_step")
    end

    test "valid — all steps done" do
      steps = [%{id: 1, label: "Done"}]
      Prompts.execution_phase_prompt(@lang, @now, @all_tools, %{plan_steps: steps, current_step: 2})
      |> assert_valid_hierarchy("exec/all_steps_done")
    end

    test "Approved Plan is ## (h2)" do
      steps    = [%{id: 1, label: "Fetch"}, %{id: 2, label: "Deliver"}]
      prompt   = Prompts.execution_phase_prompt(@lang, @now, @all_tools, %{plan_steps: steps, current_step: 1})
      headings = extract_headings(prompt)
      match    = Enum.find(headings, fn {_, t} -> String.contains?(t, "Approved Plan") end)

      assert match != nil, "expected 'Approved Plan' heading"
      {level, _} = match
      assert level == 2, "Approved Plan must be ## (h2), got h#{level}"
    end

    test "web_search Constraint is ## (h2) when tool present" do
      prompt   = Prompts.execution_phase_prompt(@lang, @now, @all_tools, %{})
      headings = extract_headings(prompt)
      matches  = Enum.filter(headings, fn {_, t} -> String.contains?(t, "web_search Constraint") end)

      assert matches != [], "expected 'web_search Constraint' heading when web_search tool is present"
      for {level, text} <- matches do
        assert level == 2, "web_search Constraint must be ## (h2), got h#{level}: #{text}"
      end
    end

    test "web_search Constraint absent when tool not present" do
      tools  = Enum.reject(@all_tools, &((&1[:name] || &1["name"]) == "web_search"))
      prompt = Prompts.execution_phase_prompt(@lang, @now, tools, %{})
      refute String.contains?(prompt, "web_search Constraint"),
             "web_search Constraint must not appear when tool is absent"
    end
  end

  # ── SystemPrompt (intentionally prose — no Markdown headers) ────────────────

  describe "SystemPrompt.generate" do
    test "confidant mode is pure prose — no Markdown headings" do
      prompt = SystemPrompt.generate(mode: "confidant")
      assert extract_headings(prompt) == [],
             "confidant system prompt must not contain Markdown headings"
    end

    test "assistant mode is pure prose — no Markdown headings" do
      prompt = SystemPrompt.generate(mode: "assistant")
      assert extract_headings(prompt) == [],
             "assistant system prompt must not contain Markdown headings"
    end
  end
end
