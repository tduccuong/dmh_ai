# Integration tests: Worker crash/restart recovery lifecycle.
# Run with: MIX_ENV=test mix test test/itgr_crash_recovery.exs

defmodule Itgr.CrashRecovery do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.WorkerState
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp db_status(worker_id) do
    r = query!(Dmhai.Repo, "SELECT status FROM worker_state WHERE worker_id=?", [worker_id])
    case r.rows do
      [[status]] -> status
      [] -> nil
    end
  end

  # ─── Start → checkpoint → crash → recovery ───────────────────────────────

  test "fetch_and_claim restores state saved by the last checkpoint" do
    user_id = uid(); wid = uid(); sid = uid()

    # Worker starts and saves initial row
    WorkerState.upsert(wid, sid, user_id, "do work", [], 0, false, nil, "running")

    # Worker completes one iteration and checkpoints
    msgs = [
      %{role: "system",    content: "sys"},
      %{role: "user",      content: "do work"},
      %{role: "assistant", content: "", tool_calls: [%{"id" => "tc1", "function" => %{"name" => "bash", "arguments" => %{}}}]},
      %{role: "tool",      content: "step done", tool_call_id: "tc1"}
    ]
    WorkerState.checkpoint(wid, msgs, 1, false, "completed step 1")

    # Crash simulation: process dies without calling mark_done

    # UserAgent restarts → fetch_and_claim picks up the orphaned worker
    results = WorkerState.fetch_and_claim(user_id)
    assert length(results) >= 1
    [w] = Enum.filter(results, &(&1.worker_id == wid))

    assert w.session_id == sid
    assert w.task == "do work"
    assert w.iter == 1
    assert w.rolling_summary == "completed step 1"
    assert is_list(w.messages) and length(w.messages) == 4
    assert w.periodic == false
  end

  test "fetch_and_claim transitions status to 'recovering'" do
    user_id = uid(); wid = uid(); sid = uid()
    WorkerState.upsert(wid, sid, user_id, "task", [], 0, false, nil, "running")

    WorkerState.fetch_and_claim(user_id)

    assert db_status(wid) == "recovering"
  end

  test "after successful recovery, mark_done sets terminal state" do
    user_id = uid(); wid = uid(); sid = uid()
    WorkerState.upsert(wid, sid, user_id, "task", [], 0, false, nil, "running")
    WorkerState.fetch_and_claim(user_id)
    assert db_status(wid) == "recovering"

    # Worker resumes and finishes normally
    WorkerState.mark_done(wid)
    assert db_status(wid) == "done"

    # Done workers must not be re-claimed
    assert WorkerState.fetch_and_claim(user_id) == []
  end

  test "checkpoint during recovery preserves status='recovering'" do
    user_id = uid(); wid = uid(); sid = uid()
    WorkerState.upsert(wid, sid, user_id, "task", [], 0, false, nil, "running")
    WorkerState.fetch_and_claim(user_id)
    assert db_status(wid) == "recovering"

    # Worker makes progress during recovery — status must NOT flip back to 'running'
    WorkerState.checkpoint(wid, [], 2, false, "new summary")
    assert db_status(wid) == "recovering"
  end

  # ─── Orphan detection ─────────────────────────────────────────────────────

  test "stale 'recovering' worker (orphan timeout) is reclaimed on restart" do
    user_id = uid(); wid = uid(); sid = uid()
    stale_ts = System.os_time(:millisecond) - :timer.minutes(15)

    query!(Dmhai.Repo,
      "INSERT INTO worker_state (worker_id, session_id, user_id, task, messages, rolling_summary, iter, periodic, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
      [wid, sid, user_id, "orphaned task", "[]", nil, 3, 0, "recovering", stale_ts, stale_ts])

    results = WorkerState.fetch_and_claim(user_id)
    w = Enum.find(results, &(&1.worker_id == wid))
    assert w != nil
    assert w.iter == 3
    assert db_status(wid) == "recovering"
  end

  test "fresh 'recovering' worker is NOT re-claimed (no double-claim)" do
    user_id = uid(); wid = uid(); sid = uid()
    WorkerState.upsert(wid, sid, user_id, "task", [], 0, false, nil, "running")

    # First claim — sets updated_at to now
    [_w] = WorkerState.fetch_and_claim(user_id)
    assert db_status(wid) == "recovering"

    # Second call: row is fresh recovering → must return empty
    assert WorkerState.fetch_and_claim(user_id) == []
  end

  # ─── Multi-worker / isolation ─────────────────────────────────────────────

  test "recovery is scoped to the given user_id" do
    user_a = uid(); user_b = uid()
    wid_a = uid(); wid_b = uid()

    WorkerState.upsert(wid_a, uid(), user_a, "task A", [], 5, false, nil, "running")
    WorkerState.upsert(wid_b, uid(), user_b, "task B", [], 7, false, nil, "running")

    results_a = WorkerState.fetch_and_claim(user_a)
    assert length(results_a) == 1
    assert hd(results_a).worker_id == wid_a
    assert hd(results_a).iter == 5

    # user_b's worker is untouched by user_a's claim
    results_b = WorkerState.fetch_and_claim(user_b)
    assert length(results_b) == 1
    assert hd(results_b).worker_id == wid_b
    assert hd(results_b).iter == 7
  end

  test "multiple workers for the same user are all claimed in one call" do
    user_id = uid()
    wid_1 = uid(); wid_2 = uid()

    WorkerState.upsert(wid_1, uid(), user_id, "task 1", [], 0, false, nil, "running")
    WorkerState.upsert(wid_2, uid(), user_id, "task 2", [], 0, false, nil, "running")

    results = WorkerState.fetch_and_claim(user_id)
    claimed_ids = Enum.map(results, & &1.worker_id)
    assert wid_1 in claimed_ids
    assert wid_2 in claimed_ids
    assert db_status(wid_1) == "recovering"
    assert db_status(wid_2) == "recovering"
  end

  test "periodic flag is preserved across checkpoint and recovery" do
    user_id = uid(); wid = uid(); sid = uid()
    WorkerState.upsert(wid, sid, user_id, "periodic task", [], 0, true, nil, "running")
    WorkerState.checkpoint(wid, [], 3, true, nil)

    [w] = WorkerState.fetch_and_claim(user_id)
    assert w.periodic == true
    assert w.iter == 3
  end
end
