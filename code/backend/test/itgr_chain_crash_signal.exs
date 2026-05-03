# Integration tests: visible chain-end signal on inline-Task crash.
#
# The :DOWN handler in UserAgent must:
#   1. Append a `kind: "chain_aborted"` session_progress row so the
#      FE renders an error line in the chat (same shape as Stop /
#      task-cancel).
#   2. Clear stream_buffer and thinking_buffer.
#   3. NOT auto-resume Assistant (no infinite-retry loop on
#      deterministic crashes).
#   4. Clear `current_task` so the agent is ready for the next dispatch.
#
# Also covers the configurable Confidant pre-step timeout
# (`AgentSettings.confidant_pre_step_timeout_ms`).
#
# Run with:   MIX_ENV=test mix test test/itgr_chain_crash_signal.exs

defmodule Itgr.ChainCrashSignal do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{AssistantCommand, ConfidantCommand, UserAgent}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    snapshot =
      case query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"]) do
        %{rows: [[v]]} -> v
        _              -> nil
      end

    on_exit(fn ->
      if snapshot do
        query!(Repo,
               "INSERT INTO settings (key, value) VALUES (?, ?) " <>
                 "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
               ["admin_cloud_settings", snapshot])
      else
        query!(Repo, "DELETE FROM settings WHERE key=?", ["admin_cloud_settings"])
      end
    end)

    :ok
  end

  defp uid, do: T.uid()

  defp put_settings(map) do
    query!(Repo,
           "INSERT INTO settings (key, value) VALUES (?, ?) " <>
             "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
           ["admin_cloud_settings", Jason.encode!(map)])
  end

  defp insert_session(session_id, user_id, mode, messages) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, mode, Jason.encode!(messages), now, now])
  end

  defp session_buffers(session_id, user_id) do
    r = query!(Repo,
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

  defp assistant_cmd(session_id, content) do
    %AssistantCommand{
      type:             :chat,
      content:          content,
      session_id:       session_id,
      reply_pid:        self(),
      attachment_names: [],
      files:            [],
      metadata:         %{}
    }
  end

  # ─── Confidant: pre-step timeout → visible chain_aborted row ──────────────

  test "confidant: pre-step that exceeds the configured timeout writes chain_aborted" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "anything"}])

    # Tiny timeout — 200 ms. Stub the Swift planner to block forever.
    put_settings(%{"confidantPreStepTimeoutMs" => 200})

    test_pid = self()
    T.stub_llm_call(fn _model, _msgs, _opts ->
      send(test_pid, :swift_started)
      receive do
        :never -> {:ok, "{}"}
      end
    end)

    # Confidant Task.await on web_task raises after 200 ms → run_confidant
    # crashes → :DOWN fires → chain_aborted row.
    spawn(fn ->
      _ = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid, "anything"))
    end)

    assert_receive :swift_started, 2_000

    :ok = wait_until(3_000, fn ->
      Enum.any?(progress_rows(sid), fn r -> r.kind == "chain_aborted" end)
    end)

    rows = progress_rows(sid)
    assert Enum.any?(rows, fn r ->
      r.kind == "chain_aborted" and is_binary(r.label) and r.label != ""
    end)

    # State invariants — same shape as the Stop-button cancel path.
    assert current_task_in_state(user_id) == nil
    {sb, tb} = session_buffers(sid, user_id)
    assert sb == nil
    assert tb == nil
  end

  # ─── Confidant: stream raises → chain_aborted ─────────────────────────────

  test "confidant: LLM.stream raising mid-turn writes chain_aborted (no silent hang)" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "confidant",
      [%{"role" => "user", "content" => "explode"}])

    # Pre-step succeeds quickly; main stream raises.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      raise "boom from stream stub"
    end)

    spawn(fn ->
      _ = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid, "explode"))
    end)

    :ok = wait_until(3_000, fn ->
      Enum.any?(progress_rows(sid), fn r -> r.kind == "chain_aborted" end)
    end)

    assert current_task_in_state(user_id) == nil
    {sb, tb} = session_buffers(sid, user_id)
    assert sb == nil
    assert tb == nil
  end

  # ─── Assistant: crash → chain_aborted, NO auto-resume loop ────────────────

  test "assistant: crash writes chain_aborted exactly once (no infinite retry)" do
    user_id = uid(); sid = uid()
    insert_session(sid, user_id, "assistant",
      [%{"role" => "user", "content" => "do a thing"}])

    # Every Assistant LLM.stream call raises. Pre-fix this would loop:
    # crash → :DOWN → auto_resume_assistant → re-dispatch → crash → ...
    # Post-fix: one chain_aborted row, then quiet.
    {:ok, call_n} = Agent.start_link(fn -> 0 end)
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      Agent.update(call_n, fn n -> n + 1 end)
      raise "boom from assistant stream"
    end)
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)

    spawn(fn ->
      _ = UserAgent.dispatch_assistant(user_id, assistant_cmd(sid, "do a thing"))
    end)

    :ok = wait_until(3_000, fn ->
      Enum.any?(progress_rows(sid), fn r -> r.kind == "chain_aborted" end)
    end)

    # Settle window — give any erroneous auto-resume a chance to fire.
    Process.sleep(500)

    aborted_count =
      progress_rows(sid)
      |> Enum.count(fn r -> r.kind == "chain_aborted" end)

    assert aborted_count == 1, "expected exactly one chain_aborted row, got #{aborted_count}"
    assert current_task_in_state(user_id) == nil

    # Stream stub fired a small bounded number of times — definitely not
    # an unbounded loop. Allow some headroom for legitimate sub-calls
    # within a single chain pickup.
    n = Agent.get(call_n, & &1)
    assert n < 10, "stream stub fired #{n}× — looks like an auto-resume loop"
  end

  # ─── Recovery: agent ready for the next dispatch after crash ──────────────

  test "after a crash, the agent accepts a fresh dispatch cleanly" do
    user_id = uid(); sid1 = uid(); sid2 = uid()
    insert_session(sid1, user_id, "confidant",
      [%{"role" => "user", "content" => "boom"}])
    insert_session(sid2, user_id, "confidant",
      [%{"role" => "user", "content" => "again"}])

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO"} end)
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      raise "boom"
    end)

    spawn(fn -> _ = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid1, "boom")) end)

    :ok = wait_until(3_000, fn ->
      Enum.any?(progress_rows(sid1), fn r -> r.kind == "chain_aborted" end)
    end)
    :ok = wait_until(3_000, fn -> current_task_in_state(user_id) == nil end)

    # Now stub a successful path and dispatch again.
    T.stub_llm_stream(fn _model, _msgs, reply_pid, _opts ->
      send(reply_pid, {:chunk, "hello back"})
      {:ok, "hello back"}
    end)

    :ok = UserAgent.dispatch_confidant(user_id, confidant_cmd(sid2, "again"))

    :ok = wait_until(3_000, fn ->
      r = query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?", [sid2, user_id])
      case r.rows do
        [[json]] ->
          msgs = Jason.decode!(json || "[]")
          Enum.any?(msgs, fn m -> m["role"] == "assistant" end)
        _ -> false
      end
    end)
  end

  # ─── Setting: default value when unset ────────────────────────────────────

  test "AgentSettings.confidant_pre_step_timeout_ms returns the default when unset" do
    query!(Repo, "DELETE FROM settings WHERE key=?", ["admin_cloud_settings"])
    assert DmhAi.Agent.AgentSettings.confidant_pre_step_timeout_ms() == 60_000
  end

  test "AgentSettings.confidant_pre_step_timeout_ms returns the override when set" do
    put_settings(%{"confidantPreStepTimeoutMs" => 12_345})
    assert DmhAi.Agent.AgentSettings.confidant_pre_step_timeout_ms() == 12_345
  end
end
