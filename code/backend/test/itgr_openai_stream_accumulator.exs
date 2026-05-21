# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.OpenAiStreamAccumulatorTest do
  @moduledoc """
  Unit-level test for the OpenAI-protocol streaming accumulator
  (`DmhAi.LLM.Adapters.OpenAI`). Two wire dialects must produce the
  same final list of tool calls:

    * **Standard OpenAI** — first chunk carries `id` + `function.name`;
      subsequent chunks share the same `index` and grow
      `function.arguments` by string concatenation.

    * **Ollama-cloud (observed)** — every delta is a COMPLETE tool
      call (full `id`, `name`, and JSON-decoded `arguments`), but all
      deltas share `index: 0`. Distinct `id`s identify each call.

  The accumulator must NOT collapse two distinct ids onto the same
  slot just because they share an index. Identity is `id`; `index` is
  only a hint for output ordering.

  We drive the adapter through its public stream handler with synthetic
  SSE lines and inspect the final list emitted into `calls_key`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.LLM.Adapters.OpenAI

  defp empty_ctx do
    %{
      reply_pid:        self(),
      think_key:        {:think_acc, make_ref()},
      in_think_key:     {:in_think, make_ref()},
      text_key:         {:text_acc, make_ref()},
      calls_key:        {:calls, make_ref()},
      tc_acc_key:       {:tc_acc, make_ref()},
      err_key:          {:err, make_ref()},
      on_tokens:        nil
    }
  end

  defp feed(ctx, lines) do
    Process.put(ctx.text_key, "")
    Enum.each(lines, fn line ->
      {:cont, _halt} = OpenAI.handle_stream_line("data: " <> line, ctx)
    end)
    :ok = OpenAI.finalize_stream(ctx)
    Process.get(ctx.calls_key) || []
  end

  describe "standard OpenAI streaming (fragmented arguments across chunks)" do
    test "two tool_calls, each split across multiple chunks, share index 0 and 1" do
      ctx = empty_ctx()

      lines = [
        ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_aaa","type":"function","function":{"name":"connect_mcp","arguments":""}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"slug\\":"}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"google_workspace\\"}"}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_bbb","type":"function","function":{"name":"connect_mcp","arguments":""}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\\"slug\\":\\"hubspot\\"}"}}]}}]})
      ]

      calls = feed(ctx, lines)

      assert length(calls) == 2

      assert Enum.at(calls, 0)["id"] == "call_aaa"
      assert Enum.at(calls, 0)["function"]["name"] == "connect_mcp"
      assert Enum.at(calls, 0)["function"]["arguments"] == ~s({"slug":"google_workspace"})

      assert Enum.at(calls, 1)["id"] == "call_bbb"
      assert Enum.at(calls, 1)["function"]["name"] == "connect_mcp"
      assert Enum.at(calls, 1)["function"]["arguments"] == ~s({"slug":"hubspot"})
    end
  end

  describe "ollama-cloud streaming (multiple complete calls, shared index)" do
    test "two complete tool_calls arrive in a SINGLE delta, both at index 0" do
      ctx = empty_ctx()

      lines = [
        ~s({"choices":[{"delta":{"tool_calls":[
          {"id":"call_x","index":0,"type":"function","function":{"name":"connect_mcp","arguments":"{\\"slug\\":\\"google_workspace\\"}"}},
          {"id":"call_y","index":0,"type":"function","function":{"name":"connect_mcp","arguments":"{\\"slug\\":\\"hubspot\\"}"}}
        ]}}]})
      ]

      calls = feed(ctx, lines)

      assert length(calls) == 2,
             "two distinct ids must produce two slots even when they share an index"

      assert Enum.at(calls, 0)["id"] == "call_x"
      assert Enum.at(calls, 0)["function"]["arguments"] == ~s({"slug":"google_workspace"})

      assert Enum.at(calls, 1)["id"] == "call_y"
      assert Enum.at(calls, 1)["function"]["arguments"] == ~s({"slug":"hubspot"})
    end

    test "two complete tool_calls arrive in SEPARATE deltas, both at index 0" do
      ctx = empty_ctx()

      lines = [
        ~s({"choices":[{"delta":{"tool_calls":[{"id":"call_p","index":0,"type":"function","function":{"name":"connect_mcp","arguments":"{\\"slug\\":\\"calendly\\"}"}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"id":"call_q","index":0,"type":"function","function":{"name":"connect_mcp","arguments":"{\\"slug\\":\\"hubspot\\"}"}}]}}]})
      ]

      calls = feed(ctx, lines)

      assert length(calls) == 2
      assert Enum.at(calls, 0)["function"]["arguments"] == ~s({"slug":"calendly"})
      assert Enum.at(calls, 1)["function"]["arguments"] == ~s({"slug":"hubspot"})
    end
  end

  describe "decode_args fails loud on malformed JSON" do
    # Regression net: if the accumulator ever drifts back to merging
    # arguments by index, the resulting concatenated JSON would parse-
    # fail downstream. `DmhAi.Agent.LLM.normalize_tool_calls/1` (via
    # `decode_args/1`) raises `DmhAi.LLM.MalformedArgumentsError`
    # rather than silently producing `%{}`.

    test "concatenated `{...}{...}` raises MalformedArgumentsError" do
      malformed = [
        %{
          "id" => "call_z",
          "type" => "function",
          "function" => %{
            "name" => "connect_mcp",
            "arguments" => ~s({"slug":"google_workspace"}{"slug":"hubspot"})
          }
        }
      ]

      assert_raise DmhAi.LLM.MalformedArgumentsError, fn ->
        DmhAi.Agent.LLM.__test_normalize_tool_calls__(malformed)
      end
    end

    test "valid arguments JSON decodes cleanly into a map" do
      ok = [
        %{
          "id" => "call_ok",
          "type" => "function",
          "function" => %{
            "name" => "connect_mcp",
            "arguments" => ~s({"slug":"hubspot"})
          }
        }
      ]

      [call | _] = DmhAi.Agent.LLM.__test_normalize_tool_calls__(ok)
      assert call["function"]["arguments"] == %{"slug" => "hubspot"}
    end
  end
end
