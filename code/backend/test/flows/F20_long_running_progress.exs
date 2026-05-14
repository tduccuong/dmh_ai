# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F20 — Long-running run_script with progress.
#
# The progress timeline in `session_progress` is the FE's source of
# truth for the streaming chat view. Tool rows go through TWO
# observable states:
#
#   * status='pending', duration_ms=NULL   — appended BEFORE
#     `Tools.Registry.execute/3`. FE renders a spinning bubble.
#   * status='done',    duration_ms=<int>  — flipped AFTER execute
#     returns. FE freezes the bubble with a "(Ns)" suffix.
#
# Per `SessionProgress.mark_tool_done/2`'s contract, the flip is an
# IN-PLACE mutation on the same row id — NOT a new row. This is
# load-bearing: a "new row" model would break the FE's polling
# dedup (it keys on row id) and produce duplicate visual bubbles.
#
# F20 parks `run_script` mid-execution via `T.stub_tool/1` so the
# pending state is observable, then releases and asserts the
# in-place flip.

defmodule DmhAi.Flows.F20LongRunningProgress do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{AssistantCommand, Tasks, SessionProgress, UserAgent, UserAgentMessages}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F20"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F20")
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

  test "run_script parked → row at status=pending → released → same row flips to status=done with duration_ms",
       %{user_id: user_id, session_id: session_id} do
    Tasks.insert(%{
      user_id:     user_id,
      session_id:  session_id,
      task_type:   "one_off",
      task_title:  "long-running probe",
      task_spec:   "run a script that takes a noticeable amount of time",
      task_status: "ongoing",
      language:    "en"
    })

    test_pid = self()
    release_signal = make_ref()
    park_window_ms = 200

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

    # Park run_script. The chain's session_progress row is appended
    # BEFORE this fn fires (in the pre-execute branch of
    # `execute_tools/3`), so any time inside this fn is the window
    # in which an observer sees status='pending'.
    T.stub_tool(fn name, args, _ctx ->
      case name do
        "run_script" ->
          send(test_pid, {:run_script_parked, self()})

          receive do
            {^release_signal, :go} -> :ok
          after
            5_000 ->
              raise "F20: run_script stub timed out waiting for release"
          end

          # Sleep a measurable amount AFTER release so duration_ms
          # is non-trivially positive. `mark_tool_done/2` measures
          # the interval around `Tools.Registry.execute/3`, which
          # includes everything inside this fn — wait + sleep.
          Process.sleep(park_window_ms)

          script = args["script"] || args[:script] || ""
          {:ok, "[stubbed run_script]\nscript=#{script}\nstdout=did the slow thing\nexit=0\n"}

        _other ->
          :passthrough
      end
    end)

    # Drive the chain manually rather than via `session_walk` —
    # the walk's stub installation calls `ExUnit.Callbacks.on_exit/2`
    # which only works from the test process. We need to spawn the
    # dispatch (so the test can observe the parked tool concurrently),
    # so install the LLM stream stub from the test process here and
    # dispatch in a worker.
    walk_step = :counters.new(1, [:atomics])

    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      idx = :counters.get(walk_step, 1)
      :counters.add(walk_step, 1, 1)

      case idx do
        0 ->
          {:ok,
           {:tool_calls,
            [%{"id" => "rs-long-1",
               "type" => "function",
               "function" => %{
                 "name" => "run_script",
                 "arguments" => %{"script" => "sleep 5; ls /"}
               }}]}}

        _ ->
          {:ok, "Done — listed root."}
      end
    end)

    user_msg = "kick off the long script"

    spawn_link(fn ->
      {:ok, _ts} =
        UserAgentMessages.append(session_id, user_id,
          %{role: "user", content: user_msg})

      cmd = %AssistantCommand{
        type:             :chat,
        content:          user_msg,
        session_id:       session_id,
        reply_pid:        test_pid,
        attachment_names: [],
        files:            [],
        metadata:         %{}
      }

      :ok = UserAgent.dispatch_assistant(user_id, cmd)
    end)

    # Wait for run_script to be parked.
    parked_pid =
      receive do
        {:run_script_parked, pid} -> pid
      after
        5_000 -> flunk("run_script stub never reached parked state within 5s")
      end

    # ── Pending observation ──────────────────────────────────────

    progress_during =
      session_id
      |> SessionProgress.fetch_for_session(0)
      |> Enum.filter(fn r ->
           kind  = Map.get(r, :kind)
           label = Map.get(r, :label) || ""
           kind == "tool" and String.downcase(label) =~ "runscript"
         end)

    assert length(progress_during) == 1,
           "expected exactly one run_script tool row while the tool is parked; got: #{inspect(progress_during)}"

    [pending_row] = progress_during
    pending_id = Map.get(pending_row, :id)

    assert Map.get(pending_row, :status) == "pending",
           "while the tool is parked, the row should be at status='pending'; got: #{inspect(pending_row)}"

    assert is_nil(Map.get(pending_row, :duration_ms)),
           "duration_ms should be NULL until mark_tool_done flips the row; got: #{inspect(pending_row)}"

    # ── Release + observe transition ─────────────────────────────

    flip_started_at = System.os_time(:millisecond)
    send(parked_pid, {release_signal, :go})

    :ok = wait_until_idle(user_id, 10_000)

    flip_observed_at = System.os_time(:millisecond)

    progress_after =
      session_id
      |> SessionProgress.fetch_for_session(0)
      |> Enum.filter(fn r ->
           kind  = Map.get(r, :kind)
           label = Map.get(r, :label) || ""
           kind == "tool" and String.downcase(label) =~ "runscript"
         end)

    assert length(progress_after) == 1,
           "still exactly one run_script tool row after the chain ends — flip is in-place, NOT a new row; got: #{inspect(progress_after)}"

    [done_row] = progress_after

    assert Map.get(done_row, :id) == pending_id,
           "row id must be preserved across the pending→done flip " <>
             "(FE polling dedup keys on id); pending_id=#{pending_id} " <>
             "done_id=#{Map.get(done_row, :id)}"

    assert Map.get(done_row, :status) == "done",
           "after release + drain, row should be at status='done'; got: #{inspect(done_row)}"

    duration = Map.get(done_row, :duration_ms)

    assert is_integer(duration),
           "mark_tool_done should stamp an integer duration_ms; got: #{inspect(duration)}"

    assert duration >= park_window_ms,
           "duration_ms should reflect the time the tool was parked plus the post-release sleep; " <>
             "expected ≥#{park_window_ms}, got: #{duration}"

    # The flip is fast — it's a single UPDATE driven from the chain
    # process. Use a generous bound just to catch a regression that
    # accidentally adds, say, an LLM round-trip into the flip path.
    flip_window = flip_observed_at - flip_started_at
    assert flip_window < 5_000,
           "pending→done flip should happen within a few seconds of release; got: #{flip_window}ms"

    # ── Sanity — chain produced its final assistant text. ────────
    %{rows: [[messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    messages = Jason.decode!(messages_json || "[]")

    final_assistant =
      messages
      |> Enum.filter(fn m ->
           role = m["role"] || m[:role]
           role == "assistant" and is_binary(m["content"] || m[:content])
         end)
      |> List.last()

    assert final_assistant
    assert (final_assistant["content"] || final_assistant[:content]) =~ "Done"
  end

  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        flunk("F20: chain didn't reach idle within deadline")

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
