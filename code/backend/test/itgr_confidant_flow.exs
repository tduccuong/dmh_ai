# Integration tests: Confidant end-to-end pipeline via UserAgent.dispatch_confidant.
# Run with: MIX_ENV=test mix test test/itgr_confidant_flow.exs
#
# Polling-based architecture (CLAUDE.md rule #9 + specs/architecture.md
# §Polling-based delivery): the BE writes the final message to
# session.messages and streams partial tokens into sessions.stream_buffer.
# Tests assert on DB state (messages persisted, stream_buffer drained)
# rather than on mailbox messages to reply_pid.

defmodule Itgr.ConfidantFlow do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{ConfidantCommand, UserAgent}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @settle_ms 800

  defp uid, do: T.uid()

  defp insert_session(session_id, user_id, mode, messages) do
    now = System.os_time(:millisecond)
    query!(DmhAi.Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, mode, Jason.encode!(messages), now, now])
  end

  defp session_messages(session_id, user_id) do
    r = query!(DmhAi.Repo,
      "SELECT messages FROM sessions WHERE id=? AND user_id=?",
      [session_id, user_id])
    case r.rows do
      [[json]] -> Jason.decode!(json || "[]")
      _ -> []
    end
  end

  defp session_stream_buffer(session_id, user_id) do
    r = query!(DmhAi.Repo,
      "SELECT stream_buffer FROM sessions WHERE id=? AND user_id=?",
      [session_id, user_id])
    case r.rows do
      [[v]] -> v
      _ -> nil
    end
  end

  defp wait_for_assistant_message(session_id, user_id, timeout_ms \\ 5_000) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait(session_id, user_id, deadline)
  end

  defp do_wait(session_id, user_id, deadline) do
    msgs = session_messages(session_id, user_id)
    assistant = Enum.find(msgs, fn m -> m["role"] == "assistant" end)

    cond do
      assistant != nil -> {:ok, assistant}
      System.os_time(:millisecond) > deadline -> :timeout
      true ->
        Process.sleep(50)
        do_wait(session_id, user_id, deadline)
    end
  end

  defp chat_cmd(session_id, content) do
    %ConfidantCommand{type: :chat, content: content, session_id: session_id, reply_pid: self()}
  end

  # ─── Happy path ───────────────────────────────────────────────────────────

  test "confidant: final assistant message persists to session.messages" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "Hello!"}])

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO: no search needed"} end)
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "Hi "})
      send(reply_pid, {:chunk, "there!"})
      {:ok, "Hi there!"}
    end)

    :ok = UserAgent.dispatch_confidant(user_id, chat_cmd(sid, "Hello!"))
    assert {:ok, msg} = wait_for_assistant_message(sid, user_id)
    assert msg["content"] == "Hi there!"
    assert is_integer(msg["ts"])
    # stream_buffer is cleared once the final message lands
    assert session_stream_buffer(sid, user_id) == nil
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

    :ok = UserAgent.dispatch_confidant(user_id, chat_cmd(sid, "Tell me a joke."))
    assert {:ok, msg} = wait_for_assistant_message(sid, user_id)
    assert msg["content"] == "Why don't scientists trust atoms?"
  end

  test "confidant: history is included in the LLM call" do
    user_id = uid(); sid = uid()

    history = [
      %{"role" => "user",      "content" => "What is 2+2?"},
      %{"role" => "assistant", "content" => "Four."},
      %{"role" => "user",      "content" => "And 3+3?"}
    ]
    insert_session(sid, user_id, "confidant", history)

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO: no search needed"} end)

    test_pid = self()
    T.stub_llm_stream(fn _model, msgs, reply_pid, _opts ->
      send(test_pid, {:msg_count, length(msgs)})
      send(reply_pid, {:chunk, "Six."})
      {:ok, "Six."}
    end)

    :ok = UserAgent.dispatch_confidant(user_id, chat_cmd(sid, "And 3+3?"))
    assert_receive {:msg_count, count}, 2_000
    assert {:ok, _} = wait_for_assistant_message(sid, user_id)
    # system + 2 history messages + current = at least 4
    assert count >= 4
  end

  test "confidant: web_context path does not crash when detection returns a search category" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "Latest news?"}])

    {:ok, call_n} = Agent.start_link(fn -> 0 end)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(call_n, fn n -> {n, n + 1} end)
      if n == 0, do: {:ok, "NO: not needed"}, else: {:ok, "No results found."}
    end)

    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "No results."})
      {:ok, "No results."}
    end)

    :ok = UserAgent.dispatch_confidant(user_id, chat_cmd(sid, "Latest news?"))
    assert {:ok, _} = wait_for_assistant_message(sid, user_id)
  end

  # ─── Error paths ─────────────────────────────────────────────────────────

  test "confidant: LLM stream error persists a localized error placeholder" do
    # When the Confidant LLM hard-errors, the runtime appends a short
    # localized apology so session.messages never ends with role=user
    # (otherwise the chain hook's mode-blind fallback would loop
    # forever — see git history for the bug). The placeholder is
    # produced by Swift.localize/2; the test stub for that call
    # echoes its "Message to express:" payload back verbatim so we
    # can assert on the template literal.
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "hi"}])

    # Default __llm_call_stub__ from the suite setup echoes localize's
    # message-to-express verbatim (see setup/0 — the "translate a short
    # runtime message" branch). We just need __llm_stream_stub__ to
    # error and the stream collector to drain.
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts -> {:error, "upstream timeout"} end)

    :ok = UserAgent.dispatch_confidant(user_id, chat_cmd(sid, "hi"))
    Process.sleep(@settle_ms)

    msgs = session_messages(sid, user_id)
    assistant_msgs = Enum.filter(msgs, fn m -> m["role"] == "assistant" end)

    assert length(assistant_msgs) == 1,
           "expected exactly one assistant placeholder, got #{length(assistant_msgs)}"

    [%{"content" => content}] = assistant_msgs
    assert content =~ "couldn't reach the model"

    assert session_stream_buffer(sid, user_id) == nil
  end

  test "confidant: session not found leaves no assistant message" do
    user_id = uid()
    missing_sid = uid()

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts -> {:ok, "answer"} end)

    :ok = UserAgent.dispatch_confidant(user_id, chat_cmd(missing_sid, "hello"))
    Process.sleep(@settle_ms)

    msgs = session_messages(missing_sid, user_id)
    assert msgs == []
  end

  test "confidant: second dispatch is rejected while first is still running" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "slow question"}])

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      :timer.sleep(400)
      send(reply_pid, {:chunk, "ok"})
      {:ok, "ok"}
    end)

    :ok = UserAgent.dispatch_confidant(user_id, chat_cmd(sid, "slow question"))
    :timer.sleep(80)

    result = UserAgent.dispatch_confidant(user_id, chat_cmd(sid, "another question"))
    assert result == {:error, :busy}

    assert {:ok, _} = wait_for_assistant_message(sid, user_id)
  end
end
