# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F03 — user presses Stop while a chain is in flight; runtime
# kills the chain Task and emits `chain_aborted` progress.
#
# A stub LLM hangs deliberately to keep the chain alive while the
# test calls `UserAgent.cancel_current_turn/1`. Without the hang,
# the chain finishes before we get to fire the cancel.
#
# Asserts: cancel returns `{:ok, :stopped}`; a `chain_aborted`
# progress row appears for the session; calling cancel a second
# time returns `{:ok, :no_active_turn}` (idempotent — no chain to
# kill).

defmodule DmhAi.Flows.F03StopButton do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{SessionProgress, UserAgent}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F03"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F03")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, org_id, org_role, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       DmhAi.Constants.default_org_id(), "admin",
       System.os_time(:millisecond)])

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [session_id, user_id, "assistant", "[]", "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "Stop while chain in flight → cancel returns :stopped → chain_aborted progress",
       %{user_id: user_id, session_id: session_id} do
    test_pid = self()

    # The LLM stub blocks indefinitely. We notify `test_pid` that a
    # chain is now in flight, then sleep until killed.
    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      send(test_pid, :chain_in_flight)
      Process.sleep(:infinity)
    end)

    # Persist the user message + dispatch the assistant chain. We
    # cannot call dispatch_assistant from this test process directly
    # because it's a synchronous GenServer.call that won't return
    # until the chain completes — instead spawn a worker.
    user_message = %{role: "user", content: "long-running thing"}
    {:ok, _ts} = DmhAi.Agent.UserAgentMessages.append(session_id, user_id, user_message)

    spawn(fn ->
      cmd = %DmhAi.Agent.AssistantCommand{
        type:             :chat,
        content:          "long-running thing",
        session_id:       session_id,
        reply_pid:        test_pid,
        attachment_names: [],
        files:            [],
        metadata:         %{}
      }

      _ = UserAgent.dispatch_assistant(user_id, cmd)
    end)

    # Wait for the chain to actually be in the LLM call (i.e. our
    # stub fired). Small timeout so a regression that prevents the
    # chain from starting fails the test rather than hanging it.
    assert_receive :chain_in_flight, 5_000

    # Sanity: the session is reported as the user's currently-running
    # turn before we cancel.
    assert UserAgent.current_turn_session_id(user_id) == session_id

    # Press Stop.
    case UserAgent.cancel_current_turn(user_id) do
      {:ok, :stopped} -> :ok

      other ->
        flunk("expected {:ok, :stopped}; got: #{inspect(other)}")
    end

    # Give the runtime a moment to write the chain_aborted progress
    # row (the cancel handler does this synchronously, but cross-
    # process visibility may need a tick).
    Process.sleep(50)

    # chain_aborted progress row appended.
    progress = SessionProgress.fetch_for_session(session_id, 0)

    aborted_row =
      Enum.find(progress, fn r -> Map.get(r, :kind) == "chain_aborted" end)

    assert aborted_row,
           "expected chain_aborted progress row after cancel; got kinds: " <>
             inspect(Enum.map(progress, & &1.kind))

    # Cancelling again is idempotent — nothing to kill.
    assert UserAgent.cancel_current_turn(user_id) == {:ok, :no_active_turn}
  end
end
