# Integration tests: WorkerState DB persistence.
# Run with: MIX_ENV=test mix test test/itgr_db_persistence.exs

defmodule Itgr.DbPersistence do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.WorkerState

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp uid, do: T.uid()

  defp insert_worker(opts \\ []) do
    wid        = Keyword.get(opts, :worker_id, uid())
    sid        = Keyword.get(opts, :session_id, uid())
    user_id    = Keyword.get(opts, :user_id, uid())
    task       = Keyword.get(opts, :task, "test task")
    messages   = Keyword.get(opts, :messages, [])
    iter       = Keyword.get(opts, :iter, 0)
    periodic   = Keyword.get(opts, :periodic, false)
    summary    = Keyword.get(opts, :rolling_summary, nil)
    status     = Keyword.get(opts, :status, "running")

    WorkerState.upsert(wid, sid, user_id, task, messages, iter, periodic, summary, status)
    {wid, sid, user_id}
  end

  defp raw_row(worker_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]
    result = query!(Dmhai.Repo,
      "SELECT status, iter, periodic, rolling_summary, updated_at FROM worker_state WHERE worker_id=?",
      [worker_id])
    case result.rows do
      [[status, iter, periodic, summary, updated_at]] ->
        %{status: status, iter: iter, periodic: periodic == 1,
          rolling_summary: summary, updated_at: updated_at}
      [] -> nil
    end
  end

  # ─── upsert ───────────────────────────────────────────────────────────────

  test "upsert creates row with status='running'" do
    {wid, _sid, _uid} = insert_worker()
    row = raw_row(wid)
    assert row.status == "running"
  end

  test "upsert stores task, messages, iter, periodic, rolling_summary" do
    msgs    = [%{role: "system", content: "sys"}, %{role: "user", content: "task"}]
    {wid, _sid, _uid} = insert_worker(messages: msgs, iter: 3, periodic: true, rolling_summary: "summary text")
    row = raw_row(wid)
    assert row.iter == 3
    assert row.periodic == true
    assert row.rolling_summary == "summary text"
  end

  test "upsert on conflict updates the existing row" do
    {wid, sid, user_id} = insert_worker(iter: 0, status: "running")
    WorkerState.upsert(wid, sid, user_id, "new task", [], 5, false, nil, "running")
    row = raw_row(wid)
    assert row.iter == 5
  end

  # ─── checkpoint ──────────────────────────────────────────────────────────

  test "checkpoint updates messages and iter WITHOUT touching status" do
    {wid, _, _} = insert_worker(status: "running", iter: 0)
    new_msgs = [%{role: "system", content: "x"}]
    WorkerState.checkpoint(wid, new_msgs, 2, true, "rolling")
    row = raw_row(wid)
    assert row.status == "running"   # status must NOT change
    assert row.iter == 2
    assert row.periodic == true
    assert row.rolling_summary == "rolling"
  end

  test "checkpoint on recovering worker keeps status='recovering'" do
    {wid, _, _} = insert_worker(status: "recovering", iter: 1)
    WorkerState.checkpoint(wid, [], 2, false, nil)
    assert raw_row(wid).status == "recovering"
  end

  # ─── mark_done / mark_cancelled ───────────────────────────────────────────

  test "mark_done sets status='done'" do
    {wid, _, _} = insert_worker()
    WorkerState.mark_done(wid)
    assert raw_row(wid).status == "done"
  end

  test "mark_cancelled sets status='cancelled'" do
    {wid, _, _} = insert_worker()
    WorkerState.mark_cancelled(wid)
    assert raw_row(wid).status == "cancelled"
  end

  # ─── fetch_and_claim ──────────────────────────────────────────────────────

  test "fetch_and_claim returns 'running' workers and sets them to 'recovering'" do
    user_id = uid()
    {wid, _, _} = insert_worker(user_id: user_id, status: "running", iter: 3)

    results = WorkerState.fetch_and_claim(user_id)

    assert length(results) == 1
    [w] = results
    assert w.worker_id == wid
    assert w.iter == 3
    # DB row should now be 'recovering'
    assert raw_row(wid).status == "recovering"
  end

  test "fetch_and_claim does NOT return 'done' workers" do
    user_id = uid()
    {_wid, _, _} = insert_worker(user_id: user_id, status: "done")
    assert WorkerState.fetch_and_claim(user_id) == []
  end

  test "fetch_and_claim does NOT return 'cancelled' workers" do
    user_id = uid()
    {_wid, _, _} = insert_worker(user_id: user_id, status: "cancelled")
    assert WorkerState.fetch_and_claim(user_id) == []
  end

  test "fetch_and_claim does NOT return fresh 'recovering' workers" do
    user_id = uid()
    # Insert with status='recovering' and a recent updated_at (< orphan threshold)
    {_wid, _sid, _} = insert_worker(user_id: user_id, status: "running")
    WorkerState.fetch_and_claim(user_id)   # claims it → recovering
    # Second call should return empty (row is fresh recovering, not stale)
    assert WorkerState.fetch_and_claim(user_id) == []
  end

  test "fetch_and_claim reclaims stale 'recovering' workers (orphan timeout)" do
    user_id = uid()
    wid     = uid()
    sid     = uid()
    # Insert as recovering with an old updated_at (simulate orphaned recovery)
    stale_ts = System.os_time(:millisecond) - :timer.minutes(15)
    import Ecto.Adapters.SQL, only: [query!: 3]
    query!(Dmhai.Repo,
      "INSERT INTO worker_state (worker_id, session_id, user_id, task, messages, rolling_summary, iter, periodic, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
      [wid, sid, user_id, "stale task", "[]", nil, 2, 0, "recovering", stale_ts, stale_ts])

    results = WorkerState.fetch_and_claim(user_id)
    assert Enum.any?(results, &(&1.worker_id == wid))
  end

  test "fetch_and_claim returns correct messages, task, iter from checkpoint" do
    user_id = uid()
    msgs    = [%{"role" => "system", "content" => "sys"}, %{"role" => "user", "content" => "do work"}]
    {wid, sid, _} = insert_worker(user_id: user_id, messages: msgs, task: "do work", iter: 5, rolling_summary: "prior work")

    [w] = WorkerState.fetch_and_claim(user_id)
    assert w.worker_id == wid
    assert w.session_id == sid
    assert w.task == "do work"
    assert w.iter == 5
    assert w.rolling_summary == "prior work"
    assert is_list(w.messages)
  end

  test "fetch_and_claim returns only workers belonging to the given user_id" do
    user_a = uid()
    user_b = uid()
    insert_worker(user_id: user_a, status: "running")
    insert_worker(user_id: user_b, status: "running")

    results_a = WorkerState.fetch_and_claim(user_a)
    assert length(results_a) == 1
    # user_b's worker untouched by user_a's claim
    results_b = WorkerState.fetch_and_claim(user_b)
    assert length(results_b) == 1
  end

  test "second fetch_and_claim after first returns empty (no double-claim)" do
    user_id = uid()
    insert_worker(user_id: user_id)
    WorkerState.fetch_and_claim(user_id)
    assert WorkerState.fetch_and_claim(user_id) == []
  end
end
