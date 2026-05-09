# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F13 — Periodic task scheduled cycle.
#
# Periodic tasks live in the `pending` state with a `time_to_pickup`
# wall-clock ms. `TaskRuntime` arms a timer; on fire it delivers
# `GenServer.call(user_agent, {:task_due, task_id})`. The agent's
# `do_task_due/2` spawns a SILENT turn (`start_silent_turn` with
# default `kind: :periodic`) — the model gets a `[Task due:]` kicker
# (NOT persisted to session.messages) and treats it as a fresh user
# ask scoped to the named task.
#
# When the silent turn ends with `complete_task`, `Tasks.mark_done/2`
# does the periodic-specific re-arm:
#
#   * status='pending'  (NOT 'done' — periodic is non-terminal)
#   * task_result=<the latest cycle's answer>
#   * time_to_pickup = now + intvl_sec * 1000
#   * `TaskRuntime.schedule_pickup` arms the next firing
#   * `ToolHistory.flush_for_task` archives this cycle's tool data
#
# This flow drives ONE complete cycle and asserts every load-bearing
# state transition above. Multi-cycle interleavings (manual user
# message racing the scheduler) are F14's domain.

defmodule DmhAi.Flows.F13PeriodicLifecycle do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{Tasks, TaskChainArchive, UserAgent}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F13"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F13")
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
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "scheduler-driven pickup → silent turn runs → complete_task → re-armed for next cycle",
       %{user_id: user_id, session_id: session_id} do
    intvl_sec = 600

    task_id =
      Tasks.insert(%{
        user_id:        user_id,
        session_id:     session_id,
        task_type:      "periodic",
        task_title:     "hourly check disk usage",
        task_spec:      "every cycle: report disk usage on the host",
        task_status:    "pending",
        intvl_sec:      intvl_sec,
        time_to_pickup: System.os_time(:millisecond) - 1,
        language:       "en"
      })

    %{task_num: task_num} = Tasks.get(task_id)

    # Stub Swift classifier — silent-turn path may still consult it
    # for chain-start anchoring.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    # Stub run_script — the silent turn's investigative tool.
    T.stub_tool(fn name, args, _ctx ->
      case name do
        "run_script" ->
          script = args["script"] || args[:script] || ""
          {:ok,
           "[stubbed run_script]\nscript=#{script}\n" <>
             "stdout=Filesystem  Size  Used Avail Use%\n" <>
             "/dev/sda1  100G   42G   58G  42%\nstdout_end\nexit=0\n"}

        _other ->
          :passthrough
      end
    end)

    # Stub the silent turn's LLM stream:
    #   Turn 0 — run_script
    #   Turn 1 — complete_task (with task_result)
    #   Turn 2 — final text answer (delivery turn — complete_task's
    #            empty narration triggers the documented fall-through)
    turn_counter = :counters.new(1, [:atomics])

    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      idx = :counters.get(turn_counter, 1)
      :counters.add(turn_counter, 1, 1)

      case idx do
        0 ->
          {:ok,
           {:tool_calls,
            [%{"id" => "rs-1",
               "type" => "function",
               "function" => %{
                 "name" => "run_script",
                 "arguments" => %{"script" => "df -h /"}
               }}]}}

        1 ->
          {:ok,
           {:tool_calls,
            [%{"id" => "cp-1",
               "type" => "function",
               "function" => %{
                 "name" => "complete_task",
                 "arguments" => %{
                   "task_num"    => task_num,
                   "task_result" => "/dev/sda1 at 42% (42G/100G); fine."
                 }
               }}]}}

        _ ->
          {:ok, "Disk usage at 42% on this cycle. Healthy."}
      end
    end)

    # Trigger the periodic pickup the same way `TaskRuntime.deliver_pickup/3`
    # does in production: synchronous GenServer.call to the user's agent.
    {:ok, pid} = DmhAi.Agent.Supervisor.ensure_started(user_id)
    assert :ok = GenServer.call(pid, {:task_due, task_id}, 5_000)

    # Wait until the silent turn drains. `current_turn_session_id`
    # is the same idleness signal session_walk uses.
    wait_until_idle(user_id, 6_000)

    # ── Assertions ──────────────────────────────────────────────────

    # 1. Task is back to pending (re-armed), NOT done. Periodic is
    #    non-terminal; mark_done flips status='pending' for periodic.
    refreshed = Tasks.get(task_id)

    assert refreshed.task_status == "pending",
           "periodic mark_done should re-arm to 'pending'; got: #{refreshed.task_status}"

    # 2. time_to_pickup advanced by ~intvl_sec seconds. Loose bound
    #    accommodates wall-clock between mark_done and our read.
    expected_at_least = System.os_time(:millisecond) + intvl_sec * 1_000 - 5_000
    assert refreshed.time_to_pickup >= expected_at_least,
           "time_to_pickup should advance by ~intvl_sec; " <>
             "now=#{System.os_time(:millisecond)} pickup=#{refreshed.time_to_pickup} " <>
             "expected≥#{expected_at_least}"

    # 3. task_result reflects this cycle's answer.
    assert is_binary(refreshed.task_result) and refreshed.task_result =~ "42%",
           "periodic mark_done should persist this cycle's task_result; " <>
             "got: #{inspect(refreshed.task_result)}"

    # 4. Cycle's tool data stays in the ROLLING tool_history (NOT
    #    the archive). Periodic re-arm flips status to 'pending', so
    #    `save_tools_result_of_chain`'s `closed_task?` predicate is
    #    false and the chain's tool_msgs route to the rolling
    #    window. This is correct: each cycle's investigation
    #    benefits from the previous cycle's tool context until the
    #    rolling cap evicts ages-old entries to archive.
    %{rows: [[rolling_json]]} =
      query!(Repo, "SELECT tool_history FROM sessions WHERE id=?", [session_id])

    rolling = Jason.decode!(rolling_json || "[]")

    rolling_for_task =
      rolling
      |> Enum.filter(fn entry ->
           Map.get(entry, "task_num") == task_num or
             Map.get(entry, :task_num) == task_num
         end)

    refute rolling_for_task == [],
           "periodic cycle's tool pairs should land in rolling tool_history " <>
             "(continuity across cycles); got nothing for task_num=#{task_num}"

    rolling_dump =
      rolling_for_task
      |> Enum.flat_map(fn entry -> Map.get(entry, "messages") || [] end)
      |> Enum.map_join("\n", fn m -> to_string(m["content"] || m[:content] || "") end)

    assert rolling_dump =~ "df -h" or rolling_dump =~ "stubbed run_script",
           "rolling entry should contain this cycle's run_script call/result; got: #{inspect(rolling_dump)}"

    # Archive may or may not have older cycles' data — irrelevant
    # for a single-cycle test, but should NOT have the just-run
    # cycle's pairs (since rolling kept them).
    archive = TaskChainArchive.fetch_for_task(task_id)
    archive_dump =
      Enum.map_join(archive, "\n", fn r -> to_string(Map.get(r, :content) || "") end)

    refute archive_dump =~ "stubbed run_script",
           "fresh periodic cycle's run_script result should be in rolling, " <>
             "not archive (yet); got archived: #{inspect(archive_dump)}"

    # 5. Silent turn's final text persisted as an assistant message
    #    in session.messages (audit trail for the next chain).
    %{rows: [[messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    messages = Jason.decode!(messages_json || "[]")

    final_assistant =
      messages
      |> Enum.filter(fn m -> (m["role"] || m[:role]) == "assistant" end)
      |> List.last()

    assert final_assistant,
           "silent turn should persist its final assistant text; got messages: #{inspect(messages)}"

    final_content = (final_assistant["content"] || final_assistant[:content]) |> to_string()

    assert final_content =~ "42%" or final_content =~ "Healthy" or final_content =~ "Disk",
           "final assistant text should contain the cycle's answer; got: #{inspect(final_content)}"

    # 6. The `[Task due: …]` silent kicker is NEVER persisted to
    #    session.messages — only the assistant's response is. (It's
    #    a runtime-injected user-role message in the LLM context
    #    only, by design.)
    refute Enum.any?(messages, fn m ->
             content = m["content"] || m[:content] || ""
             is_binary(content) and String.contains?(content, "[Task due:")
           end),
           "silent kicker must not leak into session.messages; got: #{inspect(messages)}"

    # 7. chain_end progress row exists. Cause is `final_text` (same
    #    fall-through path as F07).
    progress = DmhAi.Agent.SessionProgress.fetch_for_session(session_id, 0)
    chain_end_row = Enum.find(progress, fn r -> Map.get(r, :kind) == "chain_end" end)
    assert chain_end_row, "expected chain_end after silent turn"

    cause = Map.get(chain_end_row, :label) || Map.get(chain_end_row, "label")
    assert cause == "final_text",
           "complete_task with empty narration → final_text close; got: #{inspect(cause)}"

    # 8. Sanity: the stub fired at least 3 turns (run_script,
    #    complete_task, delivery text). Catches a regression where
    #    the silent path short-circuits before the model can deliver.
    assert :counters.get(turn_counter, 1) >= 3,
           "silent turn should have run ≥3 LLM round-trips; got: #{:counters.get(turn_counter, 1)}"
  end

  # Mirrors `session_walk`'s drain semantics — wait for the user's
  # agent to be empty for a brief continuous window. Inlined here
  # because the silent-turn entry point doesn't go through
  # `session_walk` (no user message).
  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        flunk("F13: silent-turn pickup never reached idle within #{deadline}ms deadline")

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
