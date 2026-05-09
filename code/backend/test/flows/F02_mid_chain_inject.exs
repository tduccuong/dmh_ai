# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F02 — Mid-chain user message injection.
#
# A user message arriving WHILE the previous chain is still running
# can't pre-empt that chain — `dispatch_assistant`'s
# `current_task != nil` guard rejects with `{:error, :queued}` so the
# FE knows it's been ack'd. The persisted user message survives in
# `session.messages` with a fresh ts, and the chain-complete hook
# (`user_agent.ex:564-567`) checks the watermark — if any user
# message landed AFTER the chain's last LLM round-trip saw the
# session, fire `:auto_resume_assistant` so a fresh chain spawns to
# answer it.
#
# This flow drives that exact race deterministically:
#
#   1. Spawn a worker that dispatches msg1. The LLM stub blocks
#      until the test releases it — that's "chain in flight."
#   2. Test process sends msg2: persists via UserAgentMessages.append,
#      then `dispatch_assistant`. The dispatch must return
#      `{:error, :queued}` because the agent is busy.
#   3. Verify both messages exist in `session.messages` (msg2 was
#      persisted even though its dispatch was rejected).
#   4. Release the stub. Chain 1 ends — its watermark is msg1.ts,
#      msg2.ts > watermark → hook fires `:auto_resume_assistant`.
#   5. Chain 2 runs (auto-resume), produces its assistant text,
#      ends.
#   6. Final state: 2 user messages, 2 assistant messages, 2
#      chain_end progress rows.
#
# What this protects against (per architecture.md §Mid-chain user
# message injection): a regression that drops msg2 silently — either
# by failing to persist when the agent is busy (no `:queued` ack) or
# by skipping the chain-complete watermark check (msg2 stranded
# until the user types again).

defmodule DmhAi.Flows.F02MidChainInject do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{AssistantCommand, SessionProgress, UserAgent, UserAgentMessages}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F02"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F02")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
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

  test "msg2 arrives while chain1 is in flight → queued → auto-resume answers msg2",
       %{user_id: user_id, session_id: session_id} do
    test_pid = self()

    # State machine for the LLM stream stub:
    #   call 0 — chain 1: signal in-flight, block until release.
    #   call 1 — chain 2 (auto-resume): respond to msg2 immediately.
    call_counter = :counters.new(1, [:atomics])
    release_signal = make_ref()

    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      idx = :counters.get(call_counter, 1)
      :counters.add(call_counter, 1, 1)

      case idx do
        0 ->
          # Chain 1 — block.
          send(test_pid, {:chain1_in_flight, self()})

          receive do
            {^release_signal, :go} -> :ok
          after
            5_000 ->
              raise "F02: chain 1 stub timed out waiting for release"
          end

          {:ok, "Ack of msg1: hello back."}

        1 ->
          # Chain 2 — auto-resume turn for msg2.
          {:ok, "Ack of msg2: yep, I see your follow-up."}

        _ ->
          # No third chain expected — fail loud if hit.
          raise "F02: unexpected LLM call idx=#{idx}; only 2 chains expected"
      end
    end)

    # Stub Swift classifier — chain-start side-channel.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    # ── Step 1 — dispatch msg1 in a worker process ───────────────

    msg1_content = "hello, here is msg1"

    worker =
      spawn_link(fn ->
        {:ok, _ts} =
          UserAgentMessages.append(session_id, user_id,
            %{role: "user", content: msg1_content})

        cmd = %AssistantCommand{
          type:             :chat,
          content:          msg1_content,
          session_id:       session_id,
          reply_pid:        test_pid,
          attachment_names: [],
          files:            [],
          metadata:         %{}
        }

        :ok = UserAgent.dispatch_assistant(user_id, cmd)
      end)

    # Wait for chain 1 to be parked in the LLM stub.
    chain1_pid =
      receive do
        {:chain1_in_flight, pid} -> pid
      after
        5_000 -> flunk("chain 1 didn't reach the LLM stub within 5s")
      end

    # Sanity — UserAgent reports the user as having an in-flight turn.
    assert UserAgent.current_turn_session_id(user_id) == session_id,
           "expected current_turn_session_id to point at the in-flight session"

    # ── Step 2 — dispatch msg2 from the test process ─────────────

    msg2_content = "actually, also tell me about msg2"

    {:ok, msg2_ts} =
      UserAgentMessages.append(session_id, user_id,
        %{role: "user", content: msg2_content})

    cmd2 = %AssistantCommand{
      type:             :chat,
      content:          msg2_content,
      session_id:       session_id,
      reply_pid:        test_pid,
      attachment_names: [],
      files:            [],
      metadata:         %{}
    }

    # Agent is busy → dispatch returns `:queued`.
    case UserAgent.dispatch_assistant(user_id, cmd2) do
      {:error, :queued} -> :ok
      other -> flunk("expected :queued mid-chain dispatch; got: #{inspect(other)}")
    end

    # ── Step 3 — both messages persisted ─────────────────────────

    %{rows: [[messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    mid_chain_messages = Jason.decode!(messages_json || "[]")

    user_msgs =
      mid_chain_messages
      |> Enum.filter(fn m -> (m["role"] || m[:role]) == "user" end)

    assert length(user_msgs) == 2,
           "both user messages should be persisted by now; got: #{inspect(user_msgs)}"

    contents = Enum.map(user_msgs, fn m -> (m["content"] || m[:content]) |> to_string() end)
    assert msg1_content in contents
    assert msg2_content in contents

    # msg2's ts is strictly later (load-bearing for the watermark).
    [m1_ts, m2_ts] = Enum.map(user_msgs, fn m -> m["ts"] || m[:ts] end)
    assert is_integer(m1_ts) and is_integer(m2_ts)
    assert m2_ts == msg2_ts,
           "ts returned by append/3 should match the persisted row; append=#{msg2_ts} persisted=#{m2_ts}"
    assert m2_ts > m1_ts,
           "msg2 ts must be strictly after msg1 (watermark relies on it); got m1=#{m1_ts} m2=#{m2_ts}"

    # ── Step 4 — release chain 1 ─────────────────────────────────

    send(chain1_pid, {release_signal, :go})

    # ── Step 5 — wait for both chains to drain ───────────────────

    :ok = wait_until_idle(user_id, 8_000)

    # ── Step 6 — final state ─────────────────────────────────────

    %{rows: [[final_messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    final_messages = Jason.decode!(final_messages_json || "[]")

    assistant_msgs =
      final_messages
      |> Enum.filter(fn m -> (m["role"] || m[:role]) == "assistant" end)

    assert length(assistant_msgs) == 2,
           "expected 2 assistant turns (chain 1 + auto-resumed chain 2); " <>
             "got: #{inspect(assistant_msgs)}"

    assistant_dump =
      assistant_msgs
      |> Enum.map_join(" | ", fn m -> (m["content"] || m[:content]) |> to_string() end)

    assert assistant_dump =~ "msg1", "chain 1's reply should reference msg1; got: #{assistant_dump}"
    assert assistant_dump =~ "msg2", "auto-resumed chain's reply should reference msg2; got: #{assistant_dump}"

    # Both chains emitted chain_end progress rows.
    progress = SessionProgress.fetch_for_session(session_id, 0)

    chain_ends =
      progress
      |> Enum.filter(fn r -> Map.get(r, :kind) == "chain_end" end)

    assert length(chain_ends) == 2,
           "expected exactly 2 chain_end rows (msg1 + auto-resumed msg2); " <>
             "got #{length(chain_ends)} kinds=#{inspect(Enum.map(progress, & &1.kind))}"

    # The stub fired exactly twice — one chain per user message.
    assert :counters.get(call_counter, 1) == 2,
           "LLM stub should have fired exactly 2 times; got: #{:counters.get(call_counter, 1)}"

    # Worker process ran to completion (didn't crash).
    refute Process.alive?(worker),
           "msg1 worker should have exited cleanly after dispatch_assistant returned"
  end

  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        flunk("F02: chains never reached idle within #{timeout_ms_for(deadline)} window")

      UserAgent.current_turn_session_id(user_id) != nil ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, nil)

      is_nil(idle_since) ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, System.os_time(:millisecond))

      System.os_time(:millisecond) - idle_since >= grace_ms ->
        :ok

      true ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, idle_since)
    end
  end

  defp timeout_ms_for(deadline_ms),
    do: deadline_ms - System.os_time(:millisecond)
end
