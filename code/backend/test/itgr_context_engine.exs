# Integration tests: ContextEngine.build_confidant_messages, build_assistant_messages, should_compact?.
# Run with: MIX_ENV=test mix test test/itgr_context_engine.exs

defmodule Itgr.ContextEngine do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.ContextEngine
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp session(opts) do
    # `"id"` is required by build_assistant_messages/2's contract
    # assertion — it drives ToolHistory.load + the Recently-extracted
    # files block. These tests don't care about the actual id value,
    # so a random uid is fine; what matters is that the key is present.
    %{
      "id"       => Keyword.get(opts, :id, T.uid()),
      "messages" => Keyword.get(opts, :messages, []),
      "context"  => Keyword.get(opts, :context, nil)
    }
  end

  defp insert_session(session_id, user_id, messages, ctx \\ nil) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, context, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
      [session_id, user_id, "assistant",
       Jason.encode!(messages),
       if(ctx, do: Jason.encode!(ctx), else: nil),
       now, now])
  end

  defp read_context(session_id) do
    r = query!(Repo, "SELECT context FROM sessions WHERE id=?", [session_id])
    case r.rows do
      [[nil]]        -> nil
      [[json]]       -> Jason.decode!(json)
      _              -> nil
    end
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
      %{task_id: "abc", task_num: 1, task_title: "do physics", task_status: "ongoing",
        task_type: "one_off", task_spec: "research quantum computing",
        time_to_pickup: nil},
      %{task_id: "def", task_num: 2, task_title: "book flight", task_status: "pending",
        task_type: "one_off", task_spec: "book round-trip LAX↔Tokyo",
        time_to_pickup: nil}
    ]
    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: tasks)

    task_msg = find_msg(msgs, "user", &String.starts_with?(&1, "## Task list"))
    assert task_msg != nil
    assert String.contains?(task_msg.content, "### one_off")
    # Phase 3: tasks render as `#### (N) title` — task_id is BE-internal.
    assert String.contains?(task_msg.content, "#### (1) do physics")
    assert String.contains?(task_msg.content, "#### (2) book flight")
    assert String.contains?(task_msg.content, "**Description:** research quantum computing")
    # task_id must NOT appear in the rendered block.
    refute String.contains?(task_msg.content, "abc")
    refute String.contains?(task_msg.content, "def")
  end

  test "assistant: empty active_tasks → no task list block" do
    sd = session(messages: [user_msg("hello")])
    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: [])
    refute find_msg(msgs, "user", &String.starts_with?(&1, "## Task list"))
  end

  test "assistant: done section renders flat (N) title entries" do
    sd = session(messages: [user_msg("hi")])
    done = [
      %{task_id: "xyz", task_num: 3, task_title: "Research physics", task_status: "done",
        task_type: "one_off", task_spec: "...", time_to_pickup: nil}
    ]
    msgs = ContextEngine.build_assistant_messages(sd, recent_done: done)
    task_msg = find_msg(msgs, "user", &String.starts_with?(&1, "## Task list"))
    assert task_msg != nil
    assert String.contains?(task_msg.content, "### done")
    # Phase 3: flat bullets under `### done`, no task_id.
    assert String.contains?(task_msg.content, "- (3) Research physics")
    # Done tasks do NOT get their own #### heading
    refute String.contains?(task_msg.content, "#### Research physics")
    refute String.contains?(task_msg.content, "xyz")
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
    active = [%{task_id: "a1", task_num: 1, task_title: "Z",
                task_status: "pending", task_type: "one_off",
                task_spec: "s", time_to_pickup: nil}]
    [msg, _] = ContextEngine.build_task_list_block(active, [], base_level: 4)
    assert String.starts_with?(msg.content, "#### Task list")
    assert String.contains?(msg.content, "##### one_off")
    assert String.contains?(msg.content, "###### (1) Z")
    refute String.contains?(msg.content, "a1")
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
    # Default threshold is 50 (master_compact_turn_threshold). Build 60
    # messages (30 pairs) to exceed it.
    msgs = Enum.flat_map(1..30, fn i ->
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

  test "should_compact? triggers on char budget even when turn count is under threshold" do
    # A few turns with very long content: 3 pairs × 60k chars of content
    # blows past the char trigger (0.45 × 64_000 × 4 = 115_200 chars) while
    # staying far below the 50-turn-message threshold.
    fat = String.duplicate("x", 30_000)
    msgs = Enum.flat_map(1..3, fn i -> [user_msg("q#{i} " <> fat), assistant_msg("a#{i} " <> fat)] end)
    assert ContextEngine.should_compact?(session(messages: msgs))
  end

  # ─── compact!/3 end-to-end ────────────────────────────────────────────────

  test "compact! persists summary to sessions.context with the correct cutoff" do
    session_id = T.uid()
    user_id    = T.uid()
    # 30 messages; @keep_recent is 20, so indices 0..9 get summarised.
    msgs = T.conversation(15)
    insert_session(session_id, user_id, msgs)

    T.stub_llm_call(fn _model, _messages, _opts -> {:ok, "SUMMARY_OK"} end)

    :ok = ContextEngine.compact!(session_id, user_id, %{"messages" => msgs, "context" => nil})

    ctx = read_context(session_id)
    assert ctx["summary"] == "SUMMARY_OK"
    # keep_from = max(cutoff + 1, length(msgs) - @keep_recent) = max(0, 30 - 20) = 10
    # summary_up_to_index = keep_from - 1 = 9
    assert ctx["summary_up_to_index"] == 9
  end

  test "compact! is a no-op when there's nothing new since the last cutoff" do
    session_id = T.uid()
    user_id    = T.uid()
    msgs = T.conversation(5)  # 10 messages
    prior_ctx = %{"summary" => "old summary", "summary_up_to_index" => 99}
    insert_session(session_id, user_id, msgs, prior_ctx)

    # If the stub fires, we flag it.
    stub_fired = :counters.new(1, [])
    T.stub_llm_call(fn _model, _messages, _opts ->
      :counters.add(stub_fired, 1, 1)
      {:ok, "SHOULD_NOT_FIRE"}
    end)

    :ok = ContextEngine.compact!(session_id, user_id, %{"messages" => msgs, "context" => prior_ctx})

    assert :counters.get(stub_fired, 1) == 0
    # Context unchanged on disk
    ctx = read_context(session_id)
    assert ctx["summary"] == "old summary"
    assert ctx["summary_up_to_index"] == 99
  end

  test "compact! injects the [Previous summary] exchange when a prior summary exists" do
    session_id = T.uid()
    user_id    = T.uid()
    msgs = T.conversation(15)
    prior_ctx = %{"summary" => "PRIOR_SUMMARY_TEXT", "summary_up_to_index" => -1}
    insert_session(session_id, user_id, msgs, prior_ctx)

    captured_messages = :ets.new(:cap_msgs, [:public, :set])
    T.stub_llm_call(fn _model, messages, _opts ->
      :ets.insert(captured_messages, {:m, messages})
      {:ok, "NEW_SUMMARY"}
    end)

    :ok = ContextEngine.compact!(session_id, user_id, %{"messages" => msgs, "context" => prior_ctx})

    [{:m, m}] = :ets.lookup(captured_messages, :m)
    # First message should be [Previous summary] — injected before the
    # messages to summarise.
    first = hd(m)
    assert first.role == "user"
    assert String.starts_with?(first.content, "[Previous summary]")
    assert String.contains?(first.content, "PRIOR_SUMMARY_TEXT")

    # And the ack follows immediately.
    second = Enum.at(m, 1)
    assert second.role == "assistant"
    assert String.contains?(second.content, "Understood")
  end

  test "compact! leaves sessions.context untouched when the LLM call fails" do
    session_id = T.uid()
    user_id    = T.uid()
    msgs = T.conversation(15)
    insert_session(session_id, user_id, msgs)

    T.stub_llm_call(fn _model, _messages, _opts -> {:error, :network_down} end)

    :ok = ContextEngine.compact!(session_id, user_id, %{"messages" => msgs, "context" => nil})

    # Context row not set (nil encoded as NULL).
    assert read_context(session_id) == nil
  end

  test "compact! keeps the last @keep_recent messages outside the summary" do
    session_id = T.uid()
    user_id    = T.uid()
    # 50 messages → keep_from = max(0, 50 - 20) = 30 → summary covers indices 0..29.
    msgs = T.conversation(25)
    insert_session(session_id, user_id, msgs)

    captured = :ets.new(:cap_count, [:public, :set])
    T.stub_llm_call(fn _model, messages, _opts ->
      # Count user/assistant messages in the input that correspond to
      # summarised turns (exclude the final instruction).
      content_msgs = length(messages) - 1   # last msg is the instruction
      :ets.insert(captured, {:n, content_msgs})
      {:ok, "SUM"}
    end)

    :ok = ContextEngine.compact!(session_id, user_id, %{"messages" => msgs, "context" => nil})

    ctx = read_context(session_id)
    assert ctx["summary_up_to_index"] == 29

    # 30 messages summarised; no [Previous summary] prefix this run.
    [{:n, n}] = :ets.lookup(captured, :n)
    assert n == 30
  end
end
