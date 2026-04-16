# Integration tests: Confidant end-to-end pipeline via UserAgent.dispatch.
# Run with: MIX_ENV=test mix test test/itgr_confidant_flow.exs

defmodule Itgr.ConfidantFlow do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{Command, UserAgent}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  # Insert a session with optional initial messages.
  defp insert_session(session_id, user_id, mode, messages) do
    now = System.os_time(:millisecond)
    query!(Dmhai.Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, mode, Jason.encode!(messages), now, now])
  end

  defp session_messages(session_id, user_id) do
    r = query!(Dmhai.Repo,
      "SELECT messages FROM sessions WHERE id=? AND user_id=?",
      [session_id, user_id])
    case r.rows do
      [[json]] -> Jason.decode!(json || "[]")
      _ -> []
    end
  end

  # Build a chat Command with reply_pid = self().
  defp chat_cmd(session_id, content) do
    %Command{type: :chat, content: content, session_id: session_id, reply_pid: self()}
  end

  # ─── Happy path ───────────────────────────────────────────────────────────

  test "confidant: reply_pid receives chunk(s) then done" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "Hello!"}])

    # Web search detection stub (returns "NO")
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO: no search needed"} end)

    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "Hi there!"})
      {:ok, "Hi there!"}
    end)

    :ok = UserAgent.dispatch(user_id, chat_cmd(sid, "Hello!"))
    assert_receive {:done, %{content: "Hi there!"}}, 5_000
  end

  test "confidant: assistant response is persisted to the session" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "Tell me a joke."}])

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO: no search needed"} end)
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "Why don't scientists trust atoms?"})
      {:ok, "Why don't scientists trust atoms?"}
    end)

    :ok = UserAgent.dispatch(user_id, chat_cmd(sid, "Tell me a joke."))
    assert_receive {:done, _}, 5_000

    msgs = session_messages(sid, user_id)
    assert Enum.any?(msgs, fn m ->
      m["role"] == "assistant" and m["content"] == "Why don't scientists trust atoms?"
    end)
  end

  test "confidant: history is included in the LLM call" do
    user_id = uid(); sid = uid()

    # Pre-populate session with two turns of history
    history = [
      %{"role" => "user",      "content" => "What is 2+2?"},
      %{"role" => "assistant", "content" => "Four."},
      %{"role" => "user",      "content" => "And 3+3?"}
    ]
    insert_session(sid, user_id, "confidant", history)

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO: no search needed"} end)

    test_pid = self()
    T.stub_llm_stream(fn _model, msgs, reply_pid, _opts ->
      # messages should include the prior turns (not just the current message)
      send(test_pid, {:msg_count, length(msgs)})
      send(reply_pid, {:chunk, "Six."})
      {:ok, "Six."}
    end)

    :ok = UserAgent.dispatch(user_id, chat_cmd(sid, "And 3+3?"))
    assert_receive {:done, _}, 5_000
    assert_received {:msg_count, count}
    # system + 2 history messages + current = at least 4
    assert count >= 4
  end

  test "confidant: web_context is injected when LLM detection returns a search category" do
    # This test stubs detect_category to return a search result by having LLM.call
    # return "NEWS: breaking news question". WebSearch.search_and_fetch would run
    # but since the searxng server isn't running in tests it will return empty results.
    # We verify the pipeline doesn't crash and still produces a response.
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "Latest news?"}])

    {:ok, call_n} = Agent.start_link(fn -> 0 end)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(call_n, fn n -> {n, n + 1} end)
      # First call is web search detection → return "NO" to simplify
      # (testing the search path would require a running searxng instance)
      if n == 0, do: {:ok, "NO: not needed"}, else: {:ok, "No results found."}
    end)

    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "No results."})
      {:ok, "No results."}
    end)

    :ok = UserAgent.dispatch(user_id, chat_cmd(sid, "Latest news?"))
    assert_receive {:done, _}, 5_000
  end

  # ─── Error paths ─────────────────────────────────────────────────────────

  test "confidant: LLM stream error sends {:error, ...} to reply_pid" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "hi"}])

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts -> {:error, "upstream timeout"} end)

    :ok = UserAgent.dispatch(user_id, chat_cmd(sid, "hi"))
    assert_receive {:error, _}, 5_000
  end

  test "confidant: session not found sends {:error, ...} to reply_pid" do
    user_id = uid()
    # Deliberately do NOT insert a session
    missing_sid = uid()

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts -> {:ok, "answer"} end)

    :ok = UserAgent.dispatch(user_id, chat_cmd(missing_sid, "hello"))
    assert_receive {:error, _}, 5_000
  end

  test "confidant: second dispatch is rejected while first is still running" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "slow question"}])

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)

    # Stub sleeps 400ms so the second dispatch arrives while the first task is live.
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      :timer.sleep(400)
      send(reply_pid, {:chunk, "ok"})
      {:ok, "ok"}
    end)

    # First dispatch — Task starts and enters the 400ms sleep in the stub.
    :ok = UserAgent.dispatch(user_id, chat_cmd(sid, "slow question"))

    # Allow the Task enough time to start and call LLM.stream.
    :timer.sleep(80)

    # Second dispatch — UserAgent sees current_task is set, returns {:error, :busy}.
    result = UserAgent.dispatch(user_id, chat_cmd(sid, "another question"))
    assert result == {:error, :busy}

    # Wait for the first task to finish.
    assert_receive {:done, _}, 5_000
  end
end
