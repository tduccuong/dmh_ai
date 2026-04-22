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

  test "assistant: active_tasks injects hierarchical ## Task list block" do
    sd = session(messages: [user_msg("check status")])
    tasks = [
      %{task_id: "abc", task_title: "do physics", task_status: "ongoing",
        task_type: "one_off", task_spec: "research quantum computing",
        time_to_pickup: nil},
      %{task_id: "def", task_title: "book flight", task_status: "pending",
        task_type: "one_off", task_spec: "book round-trip LAX↔Tokyo",
        time_to_pickup: nil}
    ]
    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: tasks)

    task_msg = find_msg(msgs, "user", &String.starts_with?(&1, "## Task list"))
    assert task_msg != nil
    assert String.contains?(task_msg.content, "### one_off")
    # task_id is rendered alongside the title so the model never needs to invent one.
    assert String.contains?(task_msg.content, "#### `abc` — do physics")
    assert String.contains?(task_msg.content, "#### `def` — book flight")
    assert String.contains?(task_msg.content, "**Description:** research quantum computing")
  end

  test "assistant: empty active_tasks → no task list block" do
    sd = session(messages: [user_msg("hello")])
    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: [])
    refute find_msg(msgs, "user", &String.starts_with?(&1, "## Task list"))
  end

  test "assistant: done section renders flat id: title entries" do
    sd = session(messages: [user_msg("hi")])
    done = [
      %{task_id: "xyz", task_title: "Research physics", task_status: "done",
        task_type: "one_off", task_spec: "...", time_to_pickup: nil}
    ]
    msgs = ContextEngine.build_assistant_messages(sd, recent_done: done)
    task_msg = find_msg(msgs, "user", &String.starts_with?(&1, "## Task list"))
    assert task_msg != nil
    assert String.contains?(task_msg.content, "### done")
    # Same id-prefix format as active tasks, but flat bullets under `### done`.
    assert String.contains?(task_msg.content, "- `xyz` — Research physics")
    # Done tasks do NOT get their own #### heading
    refute String.contains?(task_msg.content, "#### Research physics")
  end

  test "task-list block: attachments extracted from 📎 lines, emoji stripped" do
    sd = session(messages: [user_msg("x")])
    tasks = [
      %{task_id: "a1", task_title: "Analyze",
        task_status: "pending", task_type: "one_off",
        task_spec: "identify the dog breed\n\n📎 workspace/photo.jpg\n📎 workspace/notes.txt",
        time_to_pickup: nil}
    ]
    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: tasks)
    task_msg = find_msg(msgs, "user", &String.starts_with?(&1, "## Task list"))
    assert String.contains?(task_msg.content, "**Attachments:**")
    assert String.contains?(task_msg.content, "- workspace/photo.jpg")
    assert String.contains?(task_msg.content, "- workspace/notes.txt")
    # Description shows prose only; 📎 lines stripped from it
    assert String.contains?(task_msg.content, "**Description:** identify the dog breed")
    refute Regex.match?(~r/\*\*Description:.*📎/s, task_msg.content)
  end

  test "task-list block: heading hierarchy coherent at base_level=2 (no skips)" do
    active = [%{task_id: "a1", task_title: "X",
                task_status: "pending", task_type: "one_off",
                task_spec: "s", time_to_pickup: nil}]
    done = [%{task_id: "d1", task_title: "Y",
              task_status: "done", task_type: "one_off",
              task_spec: "s", time_to_pickup: nil}]

    [msg, _] = ContextEngine.build_task_list_block(active, done, base_level: 2)
    headings = Regex.scan(~r/^(#+)\s/m, msg.content, capture: :all_but_first)
               |> List.flatten()
               |> Enum.map(&String.length/1)

    # Every heading is 2, 3, or 4 — no h5/h6 leakage, no h1.
    assert Enum.all?(headings, &(&1 in [2, 3, 4]))
    # The top heading is always h2.
    assert hd(headings) == 2
    # Transitions: 2→3, 3→4, 4→3, 3→3 are allowed; 2→4 (skipping) is not.
    headings
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> assert abs(a - b) <= 1 or b <= a end)
  end

  test "task-list block: base_level pushes all headings deeper consistently" do
    active = [%{task_id: "a1", task_title: "Z",
                task_status: "pending", task_type: "one_off",
                task_spec: "s", time_to_pickup: nil}]
    [msg, _] = ContextEngine.build_task_list_block(active, [], base_level: 4)
    assert String.starts_with?(msg.content, "#### Task list")
    assert String.contains?(msg.content, "##### one_off")
    assert String.contains?(msg.content, "###### `a1` — Z")
  end

  test "task-list block: base_level raising past Markdown h6 errors out" do
    active = [%{task_id: "a1", task_title: "Z",
                task_status: "pending", task_type: "one_off",
                task_spec: "s", time_to_pickup: nil}]
    assert_raise ArgumentError, fn ->
      ContextEngine.build_task_list_block(active, [], base_level: 5)
    end
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
