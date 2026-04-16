# Integration test: verifies that each model configured to use tools in this system
# (1) returns a tool_call response when a tool is offered, and
# (2) can complete a second call with sanitized tool-call history in the context
#     without receiving an HTTP 400 (regression for the thought_signature bug).
#
# Makes REAL HTTP calls — no LLM stubs.
# Requires the production DB so credentials are available.
#
# Run with:
#   DB_PATH=~/.dmhai/db/chat.db MIX_ENV=test mix test test/itgr_tool_capability.exs

defmodule Itgr.ToolCapability do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Dmhai.Agent.{AgentSettings, LLM}

  # A minimal tool schema whose sole purpose is to force a tool-call response.
  # The description is an imperative so the model is unlikely to ignore it.
  @ping_tool %{
    name: "ping",
    description: "Returns a pong signal. You MUST call this tool to respond — do not write plain text.",
    parameters: %{
      type: "object",
      properties: %{
        label: %{
          type: "string",
          description: "A short identifier for this ping, e.g. 'test'."
        }
      },
      required: ["label"]
    }
  }

  # The two agent roles that invoke tools in production:
  # - assistantModel: master agent (handoff_to_resolver, handoff_to_worker, …)
  # - workerModel:    worker agent (bash, web_fetch, …)
  defp tool_using_models do
    [
      {"assistantModel", AgentSettings.assistant_model()},
      {"workerModel",    AgentSettings.worker_model()}
    ]
    |> Enum.uniq_by(fn {_, m} -> m end)
  end

  # ─── Test 1: basic tool-call capability ───────────────────────────────────

  test "each tool-using model returns a tool call when given a tool" do
    for {role, model} <- tool_using_models() do
      messages = [
        %{role: "user",
          content: "Use the ping tool with label='#{role}_check'. Do not write plain text — call the tool."}
      ]

      result = LLM.call(model, messages, tools: [@ping_tool])

      assert {:ok, {:tool_calls, calls}} = result,
        "#{role} (#{model}): expected tool_calls, got: #{inspect(result)}"

      assert Enum.any?(calls, fn c -> get_in(c, ["function", "name"]) == "ping" end),
        "#{role} (#{model}): 'ping' not found in tool calls: #{inspect(calls)}"
    end
  end

  # ─── Test 2: multi-turn after tool call (thought_signature regression) ────
  #
  # Reproduces the exact failure mode:
  #   Round 1 → model returns tool_calls (possibly with thought_signature internally)
  #   Round 2 → history is sanitized to plain text (our fix) → must NOT get HTTP 400
  #
  # If sanitize_ollama_messages were removed, round 2 would fail with:
  #   "Function call is missing a thought_signature in functionCall parts"

  test "each tool-using model completes a second call with sanitized tool-call history" do
    for {role, model} <- tool_using_models() do
      # Round 1: get a tool call response
      msgs_r1 = [
        %{role: "user",
          content: "Use the ping tool with label='r1'. Call the tool — do not write plain text."}
      ]

      r1 = LLM.call(model, msgs_r1, tools: [@ping_tool])

      case r1 do
        {:ok, {:tool_calls, calls}} ->
          call_name = get_in(hd(calls), ["function", "name"]) || "ping"

          # Round 2: extend history with the sanitized text representation of the tool call
          # (exactly as do_sanitize_gemini_messages/1 produces it — name + verbatim args).
          # No tools in round 2 — we just want a text response, proving the model accepted
          # the sanitized history without thought_signature validation errors.
          msgs_r2 = msgs_r1 ++ [
            %{role: "assistant", content: "[used: #{call_name}({\"label\":\"r1\"})]"},
            %{role: "user",      content: "[result:#{call_name}] pong"},
            %{role: "user",      content: "Good. Now reply with just the single word: done"}
          ]

          r2 = LLM.call(model, msgs_r2)

          assert {:ok, text} = r2,
            "#{role} (#{model}): second call (multi-turn) failed: #{inspect(r2)}"
          assert is_binary(text) and text != "",
            "#{role} (#{model}): second call returned empty text"

        other ->
          flunk("#{role} (#{model}): round 1 did not return tool calls (cannot test multi-turn): #{inspect(other)}")
      end
    end
  end
end
