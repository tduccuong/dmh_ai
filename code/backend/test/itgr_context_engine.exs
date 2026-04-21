# Integration tests: ContextEngine.build_confidant_messages, build_assistant_messages, should_compact?.
# Run with: MIX_ENV=test mix test test/itgr_context_engine.exs

defmodule Itgr.ContextEngine do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.ContextEngine

  defp session(opts) do
    %{
      "messages" => Keyword.get(opts, :messages, []),
      "context"  => Keyword.get(opts, :context, nil)
    }
  end

  defp user_msg(text),      do: %{"role" => "user",      "content" => text}
  defp assistant_msg(text), do: %{"role" => "assistant", "content" => text}

  # Helper: find a message by role + content predicate
  defp find_msg(msgs, role, pred) when is_function(pred) do
    Enum.find(msgs, fn m ->
      m.role == role and pred.(m.content)
    end)
  end

  # ─── build_confidant_messages structure ───────────────────────────────────

  test "system message is always first" do
    sd = session(messages: [user_msg("hi")])
    [first | _] = ContextEngine.build_confidant_messages(sd)
    assert first.role == "system"
  end

  test "no context → no compaction prefix" do
    sd = session(messages: [user_msg("hi")])
    msgs = ContextEngine.build_confidant_messages(sd)
    refute find_msg(msgs, "user", &String.starts_with?(&1, "[Summary"))
  end

  test "with context summary → compaction prefix injected after system" do
    ctx = %{"summary" => "Prior convo summary", "summary_up_to_index" => -1}
    sd  = session(messages: [user_msg("new message")], context: ctx)
    msgs = ContextEngine.build_confidant_messages(sd)

    summary_msg = find_msg(msgs, "user", &String.starts_with?(&1, "[Summary of our conversation so far]"))
    assert summary_msg != nil
    assert String.contains?(summary_msg.content, "Prior convo summary")

    # The acknowledgement follows immediately
    idx = Enum.find_index(msgs, &(&1 == summary_msg))
    ack = Enum.at(msgs, idx + 1)
    assert ack.role == "assistant"
    assert String.contains?(ack.content, "Understood")
  end

  test "messages after cutoff are in history; messages before cutoff are excluded" do
    old = user_msg("very old question")
    new = user_msg("recent question")

    # cutoff at 0 → old[0] is summarised, only new is in recent history
    ctx = %{"summary" => "summary of old", "summary_up_to_index" => 0}
    sd  = %{"messages" => [old, new], "context" => ctx}

    msgs = ContextEngine.build_confidant_messages(sd)

    # "recent question" should appear as the last message (build_current_msg converts it)
    assert find_msg(msgs, "user", &(&1 == "recent question")) != nil
    # "very old question" should NOT appear in history (it is before the cutoff)
    # (it might appear as a keyword snippet only if keywords match)
    history_contents =
      msgs
      |> Enum.reject(fn m ->
        String.starts_with?(m.content, "[Summary") or
          String.starts_with?(m.content, "[Potentially relevant")
      end)
      |> Enum.map(& &1.content)

    refute "very old question" in history_contents
  end

  test "web_context frames last user message with search results" do
    sd = session(messages: [user_msg("latest news")])
    msgs = ContextEngine.build_confidant_messages(sd, web_context: "Search result: headline A")

    last_user = msgs |> Enum.filter(&(&1.role == "user")) |> List.last()
    assert String.contains?(last_user.content, "User request: latest news")
    assert String.contains?(last_user.content, "Search result: headline A")
  end

  test "files are appended to the last user message" do
    sd = session(messages: [user_msg("review this")])
    files = [%{"name" => "foo.ex", "content" => "def hello, do: :world"}]
    msgs = ContextEngine.build_confidant_messages(sd, files: files)

    last_user = msgs |> Enum.filter(&(&1.role == "user")) |> List.last()
    assert String.contains?(last_user.content, "foo.ex")
    assert String.contains?(last_user.content, "def hello")
  end

  test "empty message list produces only the system message" do
    sd = session(messages: [])
    msgs = ContextEngine.build_confidant_messages(sd)
    assert length(msgs) == 1
    assert hd(msgs).role == "system"
  end

  test "images are attached to the last user message" do
    sd = session(messages: [user_msg("describe this")])
    msgs = ContextEngine.build_confidant_messages(sd, images: ["base64abc"])
    last_user = msgs |> Enum.filter(&(&1.role == "user")) |> List.last()
    assert Map.get(last_user, :images) == ["base64abc"]
  end

  # ─── build_assistant_messages structure ───────────────────────────────────

  test "assistant: buffer_context injects worker update exchange" do
    sd = session(messages: [user_msg("check status")])
    msgs = ContextEngine.build_assistant_messages(sd, buffer_context: "Worker finished task X")

    buffer_msg = find_msg(msgs, "user", &String.starts_with?(&1, "[Worker agent updates]"))
    assert buffer_msg != nil
    assert String.contains?(buffer_msg.content, "Worker finished task X")
  end

  test "assistant: nil buffer_context → no worker update exchange" do
    sd = session(messages: [user_msg("hello")])
    msgs = ContextEngine.build_assistant_messages(sd, buffer_context: nil)
    refute find_msg(msgs, "user", &String.starts_with?(&1, "[Worker agent updates]"))
  end

  test "assistant: system message is always first" do
    sd = session(messages: [user_msg("do something")])
    [first | _] = ContextEngine.build_assistant_messages(sd)
    assert first.role == "system"
  end

  # ─── keyword retrieval ────────────────────────────────────────────────────

  test "old messages matching current query keywords are injected as snippets" do
    old = [
      user_msg("tell me about quantum computing"),
      assistant_msg("Quantum uses qubits for superposition...")
    ]
    current = user_msg("quantum")

    # cutoff at 1 → old[0..1] summarised; current is the only recent message
    ctx = %{"summary" => "prior", "summary_up_to_index" => 1}
    sd  = %{"messages" => old ++ [current], "context" => ctx}

    msgs = ContextEngine.build_confidant_messages(sd)

    snippet_msg = find_msg(msgs, "user", &String.starts_with?(&1, "[Potentially relevant excerpts"))
    assert snippet_msg != nil
    assert String.contains?(snippet_msg.content, "quantum")
  end

  test "old messages without keyword overlap are NOT injected as snippets" do
    old = [
      user_msg("how do I make pasta"),
      assistant_msg("Boil water, add pasta, cook 10 minutes...")
    ]
    current = user_msg("quantum computing")

    ctx = %{"summary" => "prior", "summary_up_to_index" => 1}
    sd  = %{"messages" => old ++ [current], "context" => ctx}

    msgs = ContextEngine.build_confidant_messages(sd)

    # Pasta has no overlap with quantum computing (0.0 < 0.25 min_relevance)
    refute find_msg(msgs, "user", &String.starts_with?(&1, "[Potentially relevant excerpts"))
  end

  # ─── should_compact? ─────────────────────────────────────────────────────

  test "should_compact? returns false for a short conversation" do
    msgs = Enum.flat_map(1..5, fn i ->
      [user_msg("q#{i}"), assistant_msg("a#{i}")]
    end)
    refute ContextEngine.should_compact?(session(messages: msgs))
  end

  test "should_compact? returns true when turn count exceeds the threshold" do
    # Default threshold is 90. Build 100 messages (50 pairs) to exceed it.
    msgs = Enum.flat_map(1..50, fn i ->
      [user_msg("question #{i} " <> String.duplicate("x", 10)),
       assistant_msg("answer #{i}")]
    end)
    assert ContextEngine.should_compact?(session(messages: msgs))
  end

  test "should_compact? counts only messages AFTER the compaction cutoff" do
    # 100 messages total but all are before cutoff → recent = [] → should NOT compact
    msgs = Enum.flat_map(1..50, fn i ->
      [user_msg("q#{i}"), assistant_msg("a#{i}")]
    end)
    ctx = %{"summary" => "prior", "summary_up_to_index" => 99}
    refute ContextEngine.should_compact?(session(messages: msgs, context: ctx))
  end
end
