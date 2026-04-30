# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.LLMOllamaParser do
  use ExUnit.Case, async: false

  alias Dmhai.LLM.Adapters.Ollama

  describe "chat_endpoint_url/1" do
    test "appends /api/chat to a bare host" do
      assert Ollama.chat_endpoint_url(%{base_url: "http://192.168.1.1:11434"}) ==
               "http://192.168.1.1:11434/api/chat"
    end

    test "strips trailing /v1 (legacy OpenAI-shim base) before appending /api/chat" do
      assert Ollama.chat_endpoint_url(%{base_url: "http://192.168.1.1:11434/v1"}) ==
               "http://192.168.1.1:11434/api/chat"

      assert Ollama.chat_endpoint_url(%{base_url: "https://ollama.com/v1"}) ==
               "https://ollama.com/api/chat"
    end

    test "tolerates trailing slashes" do
      assert Ollama.chat_endpoint_url(%{base_url: "http://host:11434/"}) ==
               "http://host:11434/api/chat"

      assert Ollama.chat_endpoint_url(%{base_url: "http://host:11434/v1/"}) ==
               "http://host:11434/api/chat"
    end
  end

  describe "build_body/5" do
    test "wraps tools in OpenAI-shape envelope and includes options when non-empty" do
      tools = [%{name: "calculator", description: "math", parameters: %{}}]
      body = Ollama.build_body("devstral:24b", [%{role: "user", content: "hi"}], tools, true,
                               %{num_ctx: 32768, num_predict: 4096})

      assert body.model == "devstral:24b"
      assert body.stream == true
      assert [%{type: "function", function: %{name: "calculator"}}] = body.tools
      assert body.options == %{num_ctx: 32768, num_predict: 4096}
    end

    test "omits :tools and :options when empty" do
      body = Ollama.build_body("m", [%{role: "user", content: "hi"}], [], false, %{})
      refute Map.has_key?(body, :tools)
      refute Map.has_key?(body, :options)
    end
  end

  describe "extract_message/1 (non-streaming /api/chat)" do
    test "pulls top-level message + eval counts" do
      body = %{
        "message" => %{"role" => "assistant", "content" => "Hello"},
        "done" => true,
        "prompt_eval_count" => 100,
        "eval_count" => 5
      }

      assert {100, 5, %{"role" => "assistant", "content" => "Hello"}} =
               Ollama.extract_message(body)
    end

    test "defaults to zeros + empty map when fields absent" do
      assert {0, 0, %{}} = Ollama.extract_message(%{})
    end
  end

  describe "handle_stream_line/2 (NDJSON streaming)" do
    setup do
      keys = make_ctx()
      on_exit(fn -> for {_k, v} <- keys, do: Process.delete(v) end)
      {:ok, keys}
    end

    test "captures content tokens and forwards to reply_pid", %{ctx: ctx, text_key: text_key} do
      line = ~s({"message":{"role":"assistant","content":"Hello"},"done":false})
      {:cont, false} = Ollama.handle_stream_line(line, ctx)
      assert Process.get(text_key) == "Hello"
      assert_received {:chunk, "Hello"}
    end

    test "concatenates across multiple chunks", %{ctx: ctx, text_key: text_key} do
      Ollama.handle_stream_line(~s({"message":{"content":" world"},"done":false}), ctx)
      Ollama.handle_stream_line(~s({"message":{"content":"!"},"done":false}), ctx)
      assert Process.get(text_key) == " world!"
    end

    test "captures complete tool_calls with map arguments (no fragmentation)",
         %{ctx: ctx, calls_key: calls_key} do
      line =
        ~s|{"message":{"role":"assistant","content":"","tool_calls":[| <>
          ~s|{"id":"call_abc","function":{"name":"calc","arguments":{"x":2,"y":3}}}| <>
          ~s|]},"done":false}|

      {:cont, false} = Ollama.handle_stream_line(line, ctx)
      [tc] = Process.get(calls_key)
      assert tc["id"] == "call_abc"
      assert tc["function"]["name"] == "calc"
      assert tc["function"]["arguments"] == %{"x" => 2, "y" => 3}
    end

    test "splits embedded <think>...</think> tokens out as :thinking messages",
         %{ctx: ctx} do
      Ollama.handle_stream_line(
        ~s({"message":{"content":"<think>plan</think>answer"},"done":false}),
        ctx
      )

      assert_received {:thinking, "plan"}
      assert_received {:chunk, "answer"}
    end

    test "passes through `thinking` field as :thinking messages", %{ctx: ctx} do
      Ollama.handle_stream_line(
        ~s({"message":{"thinking":"step one"},"done":false}),
        ctx
      )

      assert_received {:thinking, "step one"}
    end

    test "tallies tokens on the done:true terminating line", %{ctx: ctx} do
      counter = self()
      ctx = Map.put(ctx, :on_tokens, fn rx, tx -> send(counter, {:tokens, rx, tx}) end)

      line =
        ~s|{"message":{"content":""},"done":true,| <>
          ~s|"prompt_eval_count":42,"eval_count":7}|

      {:cont, false} = Ollama.handle_stream_line(line, ctx)
      assert_received {:tokens, 7, 42}
    end

    test "halts on inline error line", %{ctx: ctx, err_key: err_key} do
      assert {:halt, true} =
               Ollama.handle_stream_line(~s({"error":"bad model"}), ctx)
      assert Process.get(err_key) == "bad model"
    end

    test "tolerates malformed JSON lines without crashing", %{ctx: ctx} do
      assert {:cont, false} = Ollama.handle_stream_line("not json", ctx)
    end
  end

  describe "finalize_stream/1" do
    test "is a no-op (no fragmentation to consolidate)" do
      assert :ok = Ollama.finalize_stream(%{calls_key: :unused, tc_acc_key: :unused})
    end
  end

  # ─── Helpers ───────────────────────────────────────────────────────

  defp make_ctx do
    text_key     = {__MODULE__, :text,        self()}
    calls_key    = {__MODULE__, :calls,       self()}
    err_key      = {__MODULE__, :err,         self()}
    think_key    = {__MODULE__, :think_buf,   self()}
    in_think_key = {__MODULE__, :in_think,    self()}
    tc_acc_key   = {__MODULE__, :tc_acc,      self()}

    Process.put(text_key, "")
    Process.put(calls_key, [])
    Process.put(think_key, "")
    Process.put(in_think_key, false)
    Process.put(tc_acc_key, %{})
    Process.delete(err_key)

    ctx = %{
      text_key: text_key, calls_key: calls_key, err_key: err_key,
      think_key: think_key, in_think_key: in_think_key,
      tc_acc_key: tc_acc_key,
      reply_pid: self(), on_tokens: nil
    }

    %{
      ctx: ctx,
      text_key: text_key,
      calls_key: calls_key,
      err_key: err_key,
      think_key: think_key,
      in_think_key: in_think_key,
      tc_acc_key: tc_acc_key
    }
  end
end
