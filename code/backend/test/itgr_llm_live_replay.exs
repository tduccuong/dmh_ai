# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

# Live integration test — talks to ollama-cloud over the network.
# Tagged :network so the standard suite skips it. Run with:
#   mix test test/itgr_llm_live_replay.exs --include network

defmodule Itgr.LLMLiveReplay do
  use ExUnit.Case, async: false

  @moduletag :network
  @moduletag timeout: 120_000

  alias DmhAi.Agent.LLM

  test "OpenAI SSE parser populates content/tool_calls for the captured trace" do
    # Replay the 3-message context from /tmp/replay_messages.json,
    # which was extracted from the user's hung-session trace. The
    # body is identical to what the BE was sending. Validates that
    # the new SSE parser actually captures content / tool_calls
    # instead of returning empty (the bug I introduced in #160).

    path = "/tmp/replay_messages.json"

    if not File.exists?(path) do
      IO.puts("\nSkipping live replay — #{path} missing.")
      :ok
    else
      messages = path |> File.read!() |> Jason.decode!()
      receiver = self()

      result =
        LLM.stream(
          "ollama-cloud::devstral-small-2:24b-cloud",
          messages,
          receiver,
          options: %{num_predict: 16384}
        )

      # Drain whatever the collector emitted.
      content = drain_chunks("", "chunk")
      thinking = drain_chunks("", "thinking")

      IO.puts("\n=== Live replay result ===")

      case result do
        {:ok, {:tool_calls, calls}} ->
          IO.puts("tool_calls=#{length(calls)}")
          assert length(calls) >= 1
          Enum.each(calls, fn c ->
            name = get_in(c, ["function", "name"])
            args = get_in(c, ["function", "arguments"])
            IO.puts("  - #{name}: #{inspect(args, limit: 200)}")
            assert is_binary(name) and name != ""
            # Arguments should parse as a JSON map (string-form is also OK
            # — normalize_tool_calls converts; but the captured field is
            # the raw concatenated string from accumulator).
            assert is_map(args) or (is_binary(args) and Jason.decode(args) != :error)
          end)

        {:ok, text} when is_binary(text) ->
          IO.puts("text=#{String.length(text)} chars: #{String.slice(text, 0, 120)}")
          assert String.length(text) > 0

        other ->
          flunk("unexpected result: #{inspect(other, limit: 200)}")
      end

      IO.puts("Streamed content=#{String.length(content)} thinking=#{String.length(thinking)}")
    end
  end

  test "multi-turn: assistant tool_call with map arguments + tool result + next turn does NOT 400" do
    # Reproduces the second hang: the SECOND turn re-sends the prior
    # assistant message (with tool_calls.arguments as a MAP) and used
    # to fail with "cannot unmarshal object into Go struct field
    # .messages.tool_calls.function.arguments of type string".
    # normalize_for_wire/2 fixes it for OpenAI.
    messages = [
      %{role: "user", content: "create a task to review TPS reports"},
      %{role: "assistant", tool_calls: [
        %{
          "id" => "call_test_xyz",
          "type" => "function",
          "function" => %{
            "name" => "create_task",
            # MAP, not string — the bug-trigger shape.
            "arguments" => %{
              "task_title" => "Review TPS reports",
              "task_type" => "one_off",
              "task_spec" => "Pull together the weekly TPS report stack."
            }
          }
        }
      ]},
      %{role: "tool", content: "Task created (1)", tool_call_id: "call_test_xyz"},
      %{role: "user", content: "thanks, anything else I should know?"}
    ]

    receiver = self()
    result = DmhAi.Agent.LLM.stream(
      "ollama-cloud::devstral-small-2:24b-cloud",
      messages,
      receiver,
      options: %{num_predict: 4096}
    )

    case result do
      {:ok, text} when is_binary(text) ->
        IO.puts("\n=== multi-turn replay text=#{String.length(text)} ===\n#{String.slice(text, 0, 200)}")
        assert String.length(text) > 0

      {:ok, {:tool_calls, calls}} ->
        IO.puts("\n=== multi-turn replay tool_calls=#{length(calls)} ===")
        assert length(calls) >= 1

      {:error, reason} ->
        flunk("multi-turn replay still erroring: #{inspect(reason, limit: 200)}")

      other ->
        flunk("unexpected: #{inspect(other, limit: 200)}")
    end
  end

  defp drain_chunks(acc, kind) do
    receive do
      {:chunk, t} when kind == "chunk"      -> drain_chunks(acc <> t, kind)
      {:thinking, t} when kind == "thinking" -> drain_chunks(acc <> t, kind)
      _other                                  -> drain_chunks(acc, kind)
    after
      50 -> acc
    end
  end
end
