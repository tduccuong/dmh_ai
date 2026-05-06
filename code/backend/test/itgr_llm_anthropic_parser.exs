# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.LLMAnthropicParser do
  use ExUnit.Case, async: false

  alias DmhAi.LLM.Adapters.Anthropic

  describe "build_body/5" do
    test "lifts system messages out of the messages array into a top-level field" do
      messages = [
        %{role: "system", content: "you are helpful"},
        %{role: "user",   content: "hi"}
      ]

      body = Anthropic.build_body("claude-3-5", messages, [], false, %{})

      assert body.system == "you are helpful"
      assert body.messages == [%{role: "user", content: "hi"}]
      assert body.model == "claude-3-5"
      assert body.stream == false
      assert body.max_tokens == 4096
    end

    test "concatenates multiple system messages with blank-line separator" do
      messages = [
        %{role: "system", content: "rule one"},
        %{role: "system", content: "rule two"},
        %{role: "user", content: "ping"}
      ]

      body = Anthropic.build_body("m", messages, [], false, %{})
      assert body.system == "rule one\n\nrule two"
    end

    test "encodes assistant tool_calls as tool_use content blocks with decoded input" do
      messages = [
        %{role: "user", content: "do it"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "fetch_url",
                "arguments" => %{"url" => "https://x.test"}
              }
            }
          ]
        }
      ]

      body = Anthropic.build_body("m", messages, [], false, %{})
      [_user, asst] = body.messages

      assert asst.role == "assistant"
      [tool_block] = asst.content
      assert tool_block.type == "tool_use"
      assert tool_block.id == "call_1"
      assert tool_block.name == "fetch_url"
      assert tool_block.input == %{"url" => "https://x.test"}
    end

    test "decodes string-encoded arguments back to a map for tool_use" do
      messages = [
        %{role: "user", content: "x"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              "id" => "call_2",
              "function" => %{
                "name" => "n",
                "arguments" => ~s({"k":1})
              }
            }
          ]
        }
      ]

      body = Anthropic.build_body("m", messages, [], false, %{})
      [_user, asst] = body.messages
      [block] = asst.content
      assert block.input == %{"k" => 1}
    end

    test "rewrites tool messages to user messages with tool_result blocks" do
      messages = [
        %{role: "tool", tool_call_id: "call_X", content: "the result text"}
      ]

      body = Anthropic.build_body("m", messages, [], false, %{})
      [tool_msg] = body.messages

      assert tool_msg.role == "user"
      [block] = tool_msg.content
      assert block.type == "tool_result"
      assert block.tool_use_id == "call_X"
      assert block.content == "the result text"
    end

    test "encodes tools with input_schema" do
      tools = [
        %{
          "name" => "search",
          "description" => "find things",
          "parameters" => %{type: "object", properties: %{q: %{type: "string"}}}
        }
      ]

      body = Anthropic.build_body("m", [%{role: "user", content: "x"}], tools, false, %{})
      [tool] = body.tools
      assert tool.name == "search"
      assert tool.description == "find things"
      assert tool.input_schema.type == "object"
    end

    test "passes max_tokens and temperature through when supplied" do
      body = Anthropic.build_body("m", [%{role: "user", content: "x"}], [], false, %{
        max_tokens: 1024,
        temperature: 0.3
      })

      assert body.max_tokens == 1024
      assert body.temperature == 0.3
    end
  end

  describe "extract_message/1" do
    test "splits text and tool_use blocks; tool_use input stays a map" do
      body = %{
        "content" => [
          %{"type" => "text", "text" => "ok, calling…"},
          %{
            "type"  => "tool_use",
            "id"    => "call_9",
            "name"  => "fetch",
            "input" => %{"url" => "https://x.test"}
          }
        ],
        "usage" => %{"input_tokens" => 12, "output_tokens" => 7}
      }

      {tx, rx, msg} = Anthropic.extract_message(body)
      assert tx == 12
      assert rx == 7
      assert msg["role"] == "assistant"
      assert msg["content"] == "ok, calling…"
      [call] = msg["tool_calls"]
      assert call["id"] == "call_9"
      assert call["function"]["name"] == "fetch"
      assert call["function"]["arguments"] == %{"url" => "https://x.test"}
    end

    test "text-only response carries no tool_calls key" do
      body = %{
        "content" => [%{"type" => "text", "text" => "hello"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      {_, _, msg} = Anthropic.extract_message(body)
      assert msg["content"] == "hello"
      refute Map.has_key?(msg, "tool_calls")
    end
  end

  describe "auth_headers/1" do
    test "uses x-api-key + anthropic-version (not Bearer)" do
      headers = Anthropic.auth_headers("sk-cp-fake")
      assert {"x-api-key", "sk-cp-fake"} in headers
      assert Enum.any?(headers, fn {k, _v} -> k == "anthropic-version" end)
      refute Enum.any?(headers, fn {k, _v} -> k == "authorization" end)
    end

    test "blank api_key still sets anthropic-version (no auth header)" do
      headers = Anthropic.auth_headers("")
      assert Enum.any?(headers, fn {k, _v} -> k == "anthropic-version" end)
      refute Enum.any?(headers, fn {k, _v} -> k == "x-api-key" end)
    end
  end

  describe "chat_endpoint_url/1" do
    test "appends /messages to the configured base_url" do
      assert Anthropic.chat_endpoint_url(%{base_url: "https://api.minimax.io/anthropic"}) ==
               "https://api.minimax.io/anthropic/messages"
    end

    test "trims trailing slash on base_url before joining" do
      assert Anthropic.chat_endpoint_url(%{base_url: "https://api.minimax.io/anthropic/"}) ==
               "https://api.minimax.io/anthropic/messages"
    end
  end
end
