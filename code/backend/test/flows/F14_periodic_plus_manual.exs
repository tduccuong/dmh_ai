# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F14 — Periodic task cycle interleaved with a manual chat.
#
# Periodic and manual chains share the per-user GenServer's
# `current_task` slot but DO NOT share task state. After cycle 1
# of a periodic re-arms the task to `pending` with a future
# `time_to_pickup`, a sequential manual chain on an unrelated
# topic must:
#
#   * not touch the periodic's `task_status` or `time_to_pickup`
#   * produce its own assistant turn end-to-end (LLM stub for the
#     manual chain works the same way as F07)
#   * keep its own tool/transcript data isolated — periodic's
#     rolling-window entry stays under `task_num=N_periodic`,
#     manual's entries land under whatever anchor the manual
#     chain operates on (here: `nil` / free mode, since manual
#     doesn't open a task of its own).
#
# F13 covers the periodic-only invariants (re-arm, time advance,
# task_result persisted). F14 layers the interleave: a manual
# chat in between cycles must not corrupt the periodic's pending
# state. The "concurrent in-flight" race is structurally
# different (current_task is busy → second dispatch returns
# `:queued`, picked up by the chain-complete hook); that's
# F02's concern.

defmodule DmhAi.Flows.F14PeriodicPlusManual do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{Tasks, UserAgent}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F14"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F14")
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
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "periodic cycle 1 re-arms → manual chat runs → periodic state untouched",
       %{user_id: user_id, session_id: session_id} do
    intvl_sec = 600

    task_id =
      Tasks.insert(%{
        user_id:        user_id,
        session_id:     session_id,
        task_type:      "periodic",
        task_title:     "hourly health-check",
        task_spec:      "every cycle: verify nginx is up on the host",
        task_status:    "pending",
        intvl_sec:      intvl_sec,
        time_to_pickup: System.os_time(:millisecond) - 1,
        language:       "en"
      })

    %{task_num: periodic_num} = Tasks.get(task_id)

    # ── Phase 1 — periodic cycle ─────────────────────────────────

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    T.stub_tool(fn name, args, _ctx ->
      case name do
        "run_script" ->
          script = args["script"] || args[:script] || ""
          {:ok, "[stubbed run_script]\nscript=#{script}\nstdout=nginx is up\nexit=0\n"}

        _other ->
          :passthrough
      end
    end)

    periodic_turns = :counters.new(1, [:atomics])

    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      idx = :counters.get(periodic_turns, 1)
      :counters.add(periodic_turns, 1, 1)

      case idx do
        0 ->
          {:ok,
           {:tool_calls,
            [%{"id" => "rs-pe-1",
               "type" => "function",
               "function" => %{
                 "name" => "run_script",
                 "arguments" => %{"script" => "systemctl status nginx | head"}
               }}]}}

        1 ->
          {:ok,
           {:tool_calls,
            [%{"id" => "cp-pe-1",
               "type" => "function",
               "function" => %{
                 "name" => "complete_task",
                 "arguments" => %{
                   "task_num"    => periodic_num,
                   "task_result" => "nginx healthy this cycle"
                 }
               }}]}}

        _ ->
          {:ok, "Cycle 1: nginx is up and healthy."}
      end
    end)

    {:ok, pid} = DmhAi.Agent.Supervisor.ensure_started(user_id)
    assert :ok = GenServer.call(pid, {:task_due, task_id}, 5_000)

    wait_until_idle(user_id, 6_000)

    # Snapshot periodic state right after cycle 1.
    periodic_after_cycle1 = Tasks.get(task_id)

    assert periodic_after_cycle1.task_status == "pending",
           "after cycle 1, periodic re-arms to 'pending'; got: #{periodic_after_cycle1.task_status}"

    cycle1_pickup = periodic_after_cycle1.time_to_pickup
    assert is_integer(cycle1_pickup) and cycle1_pickup > System.os_time(:millisecond),
           "cycle 1 should leave time_to_pickup in the future; got: #{inspect(cycle1_pickup)}"

    assert :counters.get(periodic_turns, 1) >= 3,
           "periodic stub should have fired ≥3 LLM round-trips; got: #{:counters.get(periodic_turns, 1)}"

    # ── Phase 2 — manual unrelated chat ───────────────────────────

    # Re-stub the streamer for the manual chain (single text turn).
    # `T.stub_llm_stream/1` overwrites the prior install; the manual
    # turn does NOT touch the periodic task at all.
    [obs_manual] =
      T.session_walk(user_id, session_id, [
        {"hey, what's the weather like in your data?",
         [
           fn _msgs, _tools ->
             {:text,
              "I don't have a live weather feed; the periodic " <>
                "health-check is running on its own schedule though."}
           end
         ]}
      ])

    # ── Assertions ────────────────────────────────────────────────

    # 1. The manual chain produced its own assistant turn.
    final_assistant =
      obs_manual.messages
      |> Enum.filter(fn m ->
           role = m["role"] || m[:role]
           role == "assistant" and is_binary(m["content"] || m[:content])
         end)
      |> List.last()

    assert final_assistant, "manual chain should have produced a final assistant text"

    final_content = (final_assistant["content"] || final_assistant[:content]) |> to_string()
    assert final_content =~ "weather" or final_content =~ "schedule",
           "manual reply should be about the weather/schedule, not the periodic; got: #{inspect(final_content)}"

    # 2. The manual chat's user msg is in session.messages.
    user_msgs =
      obs_manual.messages
      |> Enum.filter(fn m -> (m["role"] || m[:role]) == "user" end)
      |> Enum.map(fn m -> (m["content"] || m[:content]) |> to_string() end)

    assert Enum.any?(user_msgs, &String.contains?(&1, "weather")),
           "manual user message should be in session.messages; got users: #{inspect(user_msgs)}"

    # 3. CRITICAL — periodic state UNCHANGED by the manual chat.
    #    Same status, same time_to_pickup as right after cycle 1.
    periodic_after_manual = Tasks.get(task_id)

    assert periodic_after_manual.task_status == "pending",
           "manual chat must not flip periodic status; got: #{periodic_after_manual.task_status}"

    assert periodic_after_manual.time_to_pickup == cycle1_pickup,
           "manual chat must not shift periodic time_to_pickup; " <>
             "before=#{cycle1_pickup} after=#{periodic_after_manual.time_to_pickup}"

    assert periodic_after_manual.task_result == periodic_after_cycle1.task_result,
           "manual chat must not overwrite periodic task_result; " <>
             "before=#{inspect(periodic_after_cycle1.task_result)} " <>
             "after=#{inspect(periodic_after_manual.task_result)}"

    # 4. Manual didn't open a new task either — exactly one task in
    #    the session (the periodic).
    all_tasks = Tasks.list_for_session(session_id)
    assert length(all_tasks) == 1,
           "manual chat must not create a sibling task; got tasks: " <>
             inspect(Enum.map(all_tasks, &{&1.task_num, &1.task_type, &1.task_status}))

    # 5. The periodic's rolling tool_history entry is still present
    #    (continuity across cycles, F13 invariant). The manual
    #    chain didn't accidentally evict it.
    %{rows: [[rolling_json]]} =
      query!(Repo, "SELECT tool_history FROM sessions WHERE id=?", [session_id])

    rolling = Jason.decode!(rolling_json || "[]")

    rolling_periodic =
      rolling
      |> Enum.filter(fn entry ->
           Map.get(entry, "task_num") == periodic_num or
             Map.get(entry, :task_num) == periodic_num
         end)

    refute rolling_periodic == [],
           "periodic's rolling tool_history must survive the manual chain; " <>
             "got rolling: #{inspect(rolling)}"

    # 6. Sanity — chain_end progress rows for both chains exist.
    chain_ends =
      obs_manual.progress
      |> Enum.filter(fn r -> Map.get(r, :kind) == "chain_end" end)

    assert length(chain_ends) >= 2,
           "expected ≥2 chain_end rows (periodic cycle + manual); got #{length(chain_ends)}"
  end

  # Mirrors session_walk's drain semantics for the silent-turn path
  # (no user message → can't go through session_walk). Identical
  # to F13's helper; if a 3rd flow needs it, extract to T module.
  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        flunk("F14: silent-turn pickup never reached idle within deadline")

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
end
