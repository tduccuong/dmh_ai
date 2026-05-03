# Integration tests: Stop button — UserAgent.cancel_current_turn/1.
#
# This is a sharp cut across many layers (LLM stream, Task supervision,
# stream/thinking buffers, SessionProgress, RunningTools), so the
# tests must verify post-cancel state has NO leaks:
#
#   - state.current_task        → nil
#   - sessions.stream_buffer    → NULL
#   - sessions.thinking_buffer  → NULL
#   - session_progress          → has a `chain_aborted` row labelled
#                                 "Stopped by user."
#   - subsequent dispatches succeed (agent isn't wedged)
#
# Run with:   MIX_ENV=test mix test test/itgr_stop_button.exs

defmodule Itgr.StopButton do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{ConfidantCommand, UserAgent}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp insert_session(session_id, user_id, mode, messages) do
    now = System.os_time(:millisecond)
    query!(DmhAi.Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, mode, Jason.encode!(messages), now, now])
  end

  defp session_buffers(session_id, user_id) do
    r = query!(DmhAi.Repo,
      "SELECT stream_buffer, thinking_buffer FROM sessions WHERE id=? AND user_id=?",
      [session_id, user_id])
    case r.rows do
      [[s, t]] -> {s, t}
      _ -> {nil, nil}
    end
  end

  defp progress_rows(session_id) do
    DmhAi.Agent.SessionProgress.fetch_for_session(session_id, 0)
  end

  defp current_task_in_state(user_id) do
    [{pid, _}] = Registry.lookup(DmhAi.Agent.Registry, user_id)
    %{current_task: ct} = :sys.get_state(pid)
    ct
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    case fun.() do
      true -> :ok
      _ ->
        if System.os_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(20)
          do_wait_until(deadline, fun)
        end
    end
  end

  defp confidant_cmd(session_id, content) do
    %ConfidantCommand{type: :chat, content: content, session_id: session_id, reply_pid: self()}
  end

  # Stall the LLM stream indefinitely (until the test cancels). The stub
  # blocks on a `receive` that never matches, so the inline Task running
  # the stream is hung when we kill it. Process.exit(:kill) tears it
  # down regardless of the stub's blocking state.
  defp stall_llm_forever do
    test_pid = self()
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO: no search needed"} end)
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      send(test_pid, :stream_started)
      receive do
        :never_arrives -> {:ok, "unreachable"}
      end
    end)
  end

  # ─── No-op when idle ──────────────────────────────────────────────────────

  test "cancel: no_active_turn when agent has never run" do
    user_id = uid()
    # Don't dispatch anything — agent process doesn't exist.
    assert {:error, :not_started} = UserAgent.cancel_current_turn(user_id)
  end

  test "cancel: no_active_turn when agent is idle" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "ping"}])

    # Drive the agent to start, then let the turn complete naturally.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "ok"})
      {:ok, "ok"}
    end)
    :ok = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid, "ping"))

    # Wait for current_task to clear (turn finished).
    :ok = wait_until(3_000, fn -> current_task_in_state(user_id) == nil end)

    assert {:ok, :no_active_turn} = UserAgent.cancel_current_turn(user_id)
  end

  # ─── Happy path ───────────────────────────────────────────────────────────

  test "cancel: in-flight turn → stopped, state cleaned, chain_aborted row appended" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "tell me a long story"}])

    stall_llm_forever()

    # dispatch_confidant blocks until the inline Task replies. Since
    # we've stalled the stream forever, do the dispatch in a side
    # process so the test main can drive the cancel.
    test_pid = self()
    spawn(fn ->
      result = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid, "tell me a long story"))
      send(test_pid, {:dispatch_result, result})
    end)

    # Wait until the stream has actually started (LLM stub fired).
    assert_receive :stream_started, 3_000

    # Confirm the agent is busy on this session.
    assert UserAgent.current_turn_session_id(user_id) == sid

    # Cancel.
    assert {:ok, :stopped} = UserAgent.cancel_current_turn(user_id)

    # Post-cancel invariants:
    assert UserAgent.current_turn_session_id(user_id) == nil
    assert current_task_in_state(user_id) == nil

    {sb, tb} = session_buffers(sid, user_id)
    assert sb == nil, "stream_buffer not cleared after cancel: #{inspect(sb)}"
    assert tb == nil, "thinking_buffer not cleared after cancel: #{inspect(tb)}"

    refute DmhAi.Agent.ChainInFlight.in_flight?(sid),
      "ChainInFlight not cleared after cancel — FE will keep showing 'thinking' phrase forever"

    rows = progress_rows(sid)
    assert Enum.any?(rows, fn r ->
      r.kind == "chain_aborted" and r.label == "Stopped by user."
    end), "expected chain_aborted row, got: #{inspect(Enum.map(rows, & &1.kind))}"
  end

  # ─── Idempotence ─────────────────────────────────────────────────────────

  test "cancel: double-cancel → second call is :no_active_turn" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "hello"}])

    stall_llm_forever()

    spawn(fn ->
      _ = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid, "hello"))
    end)

    assert_receive :stream_started, 3_000
    assert {:ok, :stopped} = UserAgent.cancel_current_turn(user_id)
    assert {:ok, :no_active_turn} = UserAgent.cancel_current_turn(user_id)
  end

  # ─── Recovery: agent accepts new dispatches after cancel ─────────────────

  test "cancel: agent is ready for a fresh turn after cancel" do
    user_id = uid(); sid1 = uid(); sid2 = uid()
    insert_session(sid1, user_id, "confidant",
      [%{"role" => "user", "content" => "first"}])
    insert_session(sid2, user_id, "confidant",
      [%{"role" => "user", "content" => "second"}])

    # First turn — stalled, then cancelled.
    stall_llm_forever()
    spawn(fn ->
      _ = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid1, "first"))
    end)
    assert_receive :stream_started, 3_000
    assert {:ok, :stopped} = UserAgent.cancel_current_turn(user_id)

    # Replace stubs with a normal-completing path.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "Hi back"})
      {:ok, "Hi back"}
    end)

    # Second turn — should run cleanly to completion.
    :ok = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid2, "second"))

    # Wait for the assistant message to land.
    :ok = wait_until(3_000, fn ->
      r = query!(DmhAi.Repo,
        "SELECT messages FROM sessions WHERE id=? AND user_id=?", [sid2, user_id])
      case r.rows do
        [[json]] ->
          msgs = Jason.decode!(json || "[]")
          Enum.any?(msgs, fn m -> m["role"] == "assistant" end)
        _ -> false
      end
    end)
  end

  # ─── current_turn_session_id helper ──────────────────────────────────────

  test "current_turn_session_id: nil when no agent" do
    assert UserAgent.current_turn_session_id(uid()) == nil
  end

  test "current_turn_session_id: nil when idle, sid when busy" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "x"}])

    stall_llm_forever()
    spawn(fn ->
      _ = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid, "x"))
    end)
    assert_receive :stream_started, 3_000

    assert UserAgent.current_turn_session_id(user_id) == sid

    assert {:ok, :stopped} = UserAgent.cancel_current_turn(user_id)
    assert UserAgent.current_turn_session_id(user_id) == nil
  end

  # ─── Race: cancel arriving as task naturally completes ────────────────────

  test "cancel: race with natural completion is harmless" do
    # The cancel call is serialized through the GenServer mailbox, so
    # either it lands while current_task is still set ({:ok, :stopped}
    # — task gets killed; if it had completed too, that's redundant but
    # safe) or after current_task was cleared ({:ok, :no_active_turn}).
    # Both outcomes leave the agent ready for the next dispatch.
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "race"}])

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO" } end)
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "fast"})
      {:ok, "fast"}
    end)

    spawn(fn ->
      _ = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid, "race"))
    end)

    # Don't wait for stream-start — fire cancel as soon as possible so
    # we sample both branches across runs.
    Process.sleep(10)
    result = UserAgent.cancel_current_turn(user_id)
    assert match?({:ok, :stopped}, result) or match?({:ok, :no_active_turn}, result),
      "unexpected race outcome: #{inspect(result)}"

    # Either way, agent must be idle within a small window.
    :ok = wait_until(3_000, fn -> current_task_in_state(user_id) == nil end)
  end
end
