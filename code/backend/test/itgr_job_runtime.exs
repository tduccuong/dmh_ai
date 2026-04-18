# Integration tests for the job lifecycle: Jobs, WorkerStatus, Signal, JobRuntime.
# Run with: MIX_ENV=test mix test test/itgr_job_runtime.exs

defmodule Itgr.JobRuntime do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{Jobs, JobRuntime, WorkerStatus}
  alias Dmhai.Tools.JobSignal
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_session(sid, user_id) do
    now = System.os_time(:millisecond)
    query!(Dmhai.Repo,
      "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, user_id, "confidant", "[]", now, now])
  end

  # ─── Jobs DB helpers ─────────────────────────────────────────────────────

  test "Jobs.insert + get round-trip" do
    sid = uid(); uid_ = uid()
    jid = Jobs.insert(user_id: uid_, session_id: sid, job_title: "hello",
                      job_spec: "spec", job_type: "one_off")

    job = Jobs.get(jid)
    assert job.job_id == jid
    assert job.job_type == "one_off"
    assert job.job_title == "hello"
    assert job.job_status == "pending"
  end

  test "Jobs.mark_running sets status + worker_id + timestamp" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "s")
    wid = uid()
    Jobs.mark_running(jid, wid)
    job = Jobs.get(jid)
    assert job.job_status == "running"
    assert job.current_worker_id == wid
    assert is_integer(job.last_run_started_at)
  end

  test "Jobs.mark_done stores result and clears worker_id" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "s")
    Jobs.mark_running(jid, uid())
    Jobs.mark_done(jid, "42")
    job = Jobs.get(jid)
    assert job.job_status == "done"
    assert job.job_result == "42"
    assert job.current_worker_id == nil
  end

  test "Jobs.set_periodic flips type and sets interval" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "s")
    Jobs.set_periodic(jid, 60)
    job = Jobs.get(jid)
    assert job.job_type == "periodic"
    assert job.intvl_sec == 60
  end

  test "Jobs.fetch_due_periodic only returns periodic jobs past next_run_at" do
    past   = System.os_time(:millisecond) - 1_000
    future = System.os_time(:millisecond) + 60_000

    due_id = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "due",
                         job_spec: "s", job_type: "periodic", intvl_sec: 60)
    Jobs.schedule_next_run(due_id, past)

    not_due_id = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "notdue",
                             job_spec: "s", job_type: "periodic", intvl_sec: 60)
    Jobs.schedule_next_run(not_due_id, future)

    due_list = Jobs.fetch_due_periodic()
    due_ids  = Enum.map(due_list, & &1.job_id)
    assert due_id in due_ids
    refute not_due_id in due_ids
  end

  # ─── WorkerStatus DB helpers ─────────────────────────────────────────────

  test "WorkerStatus.append + fetch_since monotonic cursor" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "s")
    wid = uid()

    :ok = WorkerStatus.append(jid, wid, "tool_call", "bash(date)")
    :ok = WorkerStatus.append(jid, wid, "tool_result", "Mon Jan 1")
    :ok = WorkerStatus.append(jid, wid, "final", "all done", "JOB_DONE")

    all = WorkerStatus.fetch_since(jid, 0)
    assert length(all) == 3
    kinds = Enum.map(all, & &1.kind)
    assert kinds == ["tool_call", "tool_result", "final"]

    # Cursor after second row → only final remains.
    second_id = Enum.at(all, 1).id
    [last] = WorkerStatus.fetch_since(jid, second_id)
    assert last.kind == "final"
    assert last.signal_status == "JOB_DONE"
  end

  test "WorkerStatus truncates very large content" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "s")
    big = String.duplicate("a", 10_000)
    :ok = WorkerStatus.append(jid, uid(), "tool_result", big)
    [row] = WorkerStatus.fetch_since(jid, 0)
    assert String.length(row.content) < 5_000
    assert String.ends_with?(row.content, "[truncated]")
  end

  # ─── JobSignal tool contract ──────────────────────────────────────────────

  test "JobSignal.execute(JOB_DONE) writes a 'final' row with the result payload" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "s")
    ctx = %{job_id: jid, worker_id: "w1"}

    assert {:ok, _} = JobSignal.execute(%{"status" => "JOB_DONE", "result" => "all done"}, ctx)

    [row] = WorkerStatus.fetch_since(jid, 0)
    assert row.kind == "final"
    assert row.signal_status == "JOB_DONE"
    assert row.content == "all done"
  end

  test "JobSignal.execute rejects JOB_DONE without result" do
    ctx = %{job_id: "x", worker_id: "w1"}
    assert {:error, reason} = JobSignal.execute(%{"status" => "JOB_DONE"}, ctx)
    assert String.contains?(reason, "result")
  end

  test "JobSignal.execute(JOB_BLOCKED) writes a 'final' row with JOB_BLOCKED status" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "s")
    ctx = %{job_id: jid, worker_id: "w1"}

    assert {:ok, _} = JobSignal.execute(%{"status" => "JOB_BLOCKED", "reason" => "api down"}, ctx)

    [row] = WorkerStatus.fetch_since(jid, 0)
    assert row.signal_status == "JOB_BLOCKED"
    assert row.content == "api down"
  end

  test "JobSignal.execute rejects invalid status" do
    ctx = %{job_id: "x", worker_id: "w1"}
    assert {:error, reason} = JobSignal.execute(%{"status" => "WEIRD"}, ctx)
    assert String.contains?(reason, "must be")
  end

  test "JobSignal.execute rejects JOB_BLOCKED without reason" do
    ctx = %{job_id: "x", worker_id: "w1"}
    assert {:error, reason} = JobSignal.execute(%{"status" => "JOB_BLOCKED"}, ctx)
    assert String.contains?(reason, "reason")
  end

  test "JobSignal.execute rejects missing job_id" do
    ctx = %{worker_id: "w1"}
    assert {:error, reason} = JobSignal.execute(%{"status" => "JOB_DONE", "result" => "x"}, ctx)
    assert String.contains?(reason, "job_id")
  end

  # ─── JobRuntime end-to-end (one-off with stubbed LLM) ────────────────────

  test "JobRuntime.start_job runs worker and finalises JOB_DONE" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)

    jid = Jobs.insert(user_id: user_id, session_id: sid,
                      job_type: "one_off", intvl_sec: 0,
                      job_title: "greet", job_spec: "say hello",
                      job_status: "pending")

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
    end)

    JobRuntime.start_job(jid)

    # Wait up to 3s for the job to reach 'done' state.
    assert wait_for(fn -> Jobs.get(jid).job_status == "done" end, 3_000)

    job = Jobs.get(jid)
    assert job.job_result == "done"
    assert is_integer(job.last_run_completed_at)
  end

  test "JobRuntime finalises BLOCKED on signal(BLOCKED)" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)

    jid = Jobs.insert(user_id: user_id, session_id: sid, job_title: "x",
                      job_spec: "s", job_status: "pending")

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_BLOCKED", "reason" => "network error"})]}}
    end)

    JobRuntime.start_job(jid)
    assert wait_for(fn -> Jobs.get(jid).job_status == "blocked" end, 3_000)

    job = Jobs.get(jid)
    assert job.job_result == "network error"
  end

  test "JobRuntime.cancel_job halts a running job" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)

    jid = Jobs.insert(user_id: user_id, session_id: sid, job_title: "x",
                      job_spec: "s", job_status: "pending")

    # Make the stub block forever so we can cancel mid-run.
    T.stub_llm_call(fn _model, _msgs, _opts ->
      Process.sleep(:timer.seconds(30))
      {:ok, "never"}
    end)

    JobRuntime.start_job(jid)
    Process.sleep(100)
    :ok = JobRuntime.cancel_job(jid)

    assert wait_for(fn -> Jobs.get(jid).job_status == "cancelled" end, 3_000)
  end

  # ─── Progress summarizer ─────────────────────────────────────────────────

  test "summarize_and_announce: delta-only, advances cursor, appends session message" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)
    jid = Jobs.insert(user_id: user_id, session_id: sid, job_title: "research",
                      job_spec: "run multi-step research", job_status: "running")

    # Seed a batch of worker_status rows.
    WorkerStatus.append(jid, "w1", "tool_call", "web_search(btc price)")
    WorkerStatus.append(jid, "w1", "tool_result", "Found 3 results")
    WorkerStatus.append(jid, "w1", "tool_call", "web_fetch(nytimes.com)")

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, "Searching the web and fetching articles — in progress."}
    end)

    {:ok, text} = JobRuntime.summarize_and_announce(jid, force: true)
    assert String.contains?(text, "in progress")

    # Cursor advanced past the 3 input rows.
    job = Jobs.get(jid)
    assert job.last_summarized_status_id > 0

    # progress_summary row saved.
    all = WorkerStatus.fetch_since(jid, 0)
    assert Enum.any?(all, fn r -> r.kind == "progress_summary" end)
  end

  test "summarize_and_announce(force: false): no-op when no new rows" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)
    jid = Jobs.insert(user_id: user_id, session_id: sid, job_title: "x",
                      job_spec: "s", job_status: "running")
    # No worker_status rows at all.
    assert :ok = JobRuntime.summarize_and_announce(jid, force: false)
  end

  test "summarize_and_announce(force: true): canned message when no new rows" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)
    jid = Jobs.insert(user_id: user_id, session_id: sid, job_title: "quiet",
                      job_spec: "s", job_status: "running")

    {:ok, text} = JobRuntime.summarize_and_announce(jid, force: true)
    assert String.contains?(text, "No new activity")
  end

  test "summarize_and_announce: excludes prior progress_summary rows from next summary input" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)
    jid = Jobs.insert(user_id: user_id, session_id: sid, job_title: "x",
                      job_spec: "s", job_status: "running")

    WorkerStatus.append(jid, "w1", "tool_call", "step 1")
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    T.stub_llm_call(fn _model, msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      send(test_pid, {:summarize_call, n, msgs})
      {:ok, "Summary #{n}."}
    end)

    JobRuntime.summarize_and_announce(jid, force: true)
    WorkerStatus.append(jid, "w1", "tool_call", "step 2")
    JobRuntime.summarize_and_announce(jid, force: true)

    # Second call should NOT have the prior summary in its input.
    assert_received {:summarize_call, 1, msgs}
    prompt = msgs |> List.last() |> Map.get(:content)
    refute String.contains?(prompt, "Summary 0")
    refute String.contains?(prompt, "progress_summary")
    assert String.contains?(prompt, "step 2")
  end

  test "summarize_and_announce: per-job mutex prevents concurrent runs" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)
    jid = Jobs.insert(user_id: user_id, session_id: sid, job_title: "x",
                      job_spec: "s", job_status: "running")

    WorkerStatus.append(jid, "w1", "tool_call", "step 1")

    # Stub LLM to block; we'll trigger two concurrent summaries to force the
    # mutex path. First one holds the lock; second must see {:skipped, _}.
    {:ok, started_pid} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    T.stub_llm_call(fn _model, _msgs, _opts ->
      Agent.update(started_pid, &(&1 + 1))
      send(test_pid, :summary_started)
      Process.sleep(200)
      {:ok, "Progress summary."}
    end)

    # Fire the first in a Task — it will acquire the lock and sleep.
    spawn_link(fn -> JobRuntime.summarize_and_announce(jid, force: true) end)

    # Wait for the first to enter the LLM call (lock held).
    assert_receive :summary_started, 1_000

    # Second call must hit the mutex and return {:skipped, _}.
    assert {:skipped, text} = JobRuntime.summarize_and_announce(jid, force: true)
    assert String.contains?(text, "being prepared")

    # Poller (force=false) just gets :ok no-op when locked.
    assert :ok = JobRuntime.summarize_and_announce(jid, force: false)

    # Only the first invocation triggered the LLM.
    assert Agent.get(started_pid, & &1) == 1
  end

  # ─── helpers ─────────────────────────────────────────────────────────────

  defp wait_for(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_loop(fun, deadline)
  end

  defp wait_for_loop(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true ->
        Process.sleep(50)
        wait_for_loop(fun, deadline)
    end
  end
end
