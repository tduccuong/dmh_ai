# Integration tests for the new conversational-session task runtime (#101).
# Covers Tasks CRUD, SessionProgress log, and TaskRuntime periodic scheduling.

defmodule Itgr.TaskRuntime do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{SessionProgress, Tasks, TaskRuntime}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_session(sid, user_id) do
    now = System.os_time(:millisecond)
    query!(Dmhai.Repo,
      "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, user_id, "assistant", "[]", now, now])
  end

  # ─── Tasks DB helpers ─────────────────────────────────────────────────────

  test "Tasks.insert + get round-trip preserves all fields" do
    sid = uid(); uid_ = uid()
    tid = Tasks.insert(
      user_id: uid_, session_id: sid,
      task_title: "hello", task_spec: "spec",
      task_type: "one_off", language: "vi"
    )

    t = Tasks.get(tid)
    assert t.task_id == tid
    assert t.task_type == "one_off"
    assert t.task_title == "hello"
    assert t.task_status == "pending"
    assert t.language == "vi"
    assert is_integer(t.time_to_pickup)
  end

  test "Tasks.mark_ongoing flips status" do
    tid = Tasks.insert(user_id: uid(), session_id: uid(), task_title: "x", task_spec: "s")
    Tasks.mark_ongoing(tid)
    assert Tasks.get(tid).task_status == "ongoing"
  end

  test "Tasks.mark_done on one_off sets done + clears pickup" do
    tid = Tasks.insert(user_id: uid(), session_id: uid(), task_title: "x", task_spec: "s")
    Tasks.mark_done(tid, "42")
    t = Tasks.get(tid)
    assert t.task_status == "done"
    assert t.task_result == "42"
    assert t.time_to_pickup == nil
  end

  test "Tasks.mark_done on periodic auto-reschedules (status=pending, pickup bumped)" do
    tid = Tasks.insert(user_id: uid(), session_id: uid(),
                       task_title: "hb", task_spec: "s",
                       task_type: "periodic", intvl_sec: 60)
    Tasks.mark_done(tid, "cycle complete")
    t = Tasks.get(tid)
    assert t.task_status == "pending"
    assert t.task_result == "cycle complete"
    assert is_integer(t.time_to_pickup)
    assert t.time_to_pickup > System.os_time(:millisecond)
  end

  # Regression lock for the periodic-burst-fire bug.
  #
  # Before the fix, a silent-turn pickup for a periodic task started with
  # the task in `pending` state (that's how the prior pickup's mark_done
  # left it). The turn relied on the model calling `update_task(status:
  # "done")` to advance it. When the model skipped that (nemotron-3-nano
  # routinely did), `auto_close_ongoing_tasks` at end of the text round
  # filtered for `status=="ongoing"` and found nothing → no mark_done →
  # `time_to_pickup` stayed stale → `maybe_trigger_next_due` re-fired
  # immediately → tight loop of silent turns burning tokens.
  #
  # The fix: `run_assistant_silent` now calls `Tasks.mark_ongoing/1` right
  # before `session_turn_loop`, making the "text round ended with task
  # still ongoing → reschedule" auto_close safety net work for periodic
  # pickups exactly like it already did for one_off tasks that models
  # forget to close.
  #
  # This test asserts the underlying mechanism: an `ongoing` periodic
  # processed by the `auto_close_ongoing_tasks` path (invoking
  # `Tasks.mark_done/2`) is rescheduled forward, not left stale.
  test "ongoing periodic → auto_close path via mark_done reschedules forward" do
    tid = Tasks.insert(user_id: uid(), session_id: uid(),
                       task_title: "joke every 30s", task_spec: "x",
                       task_type: "periodic", intvl_sec: 30)

    # Simulate what run_assistant_silent now does at pickup start.
    Tasks.mark_ongoing(tid)
    t = Tasks.get(tid)
    assert t.task_status == "ongoing"

    # Force an outdated time_to_pickup — this is the state that would
    # cause burst re-firing without the fix (fetch_next_due returns
    # the same task because time_to_pickup <= now).
    Ecto.Adapters.SQL.query!(Dmhai.Repo,
      "UPDATE tasks SET time_to_pickup=? WHERE task_id=?",
      [System.os_time(:millisecond) - 1_000, tid])

    # auto_close_ongoing_tasks → Tasks.mark_done path.
    Tasks.mark_done(tid, "joke delivered")
    after_close = Tasks.get(tid)

    # Periodic auto-reschedule: status flipped back to pending, pickup
    # pushed forward by intvl_sec. No more stale time_to_pickup.
    assert after_close.task_status == "pending"
    assert after_close.time_to_pickup > System.os_time(:millisecond),
           "time_to_pickup must advance into the future, preventing " <>
             "maybe_trigger_next_due from re-firing the same task " <>
             "immediately (which was the burst-fire bug)"
    assert after_close.task_result == "joke delivered"
  end

  test "Tasks.update_spec rewrites the description in place" do
    tid = Tasks.insert(user_id: uid(), session_id: uid(), task_title: "x", task_spec: "old")
    Tasks.update_spec(tid, "new spec")
    assert Tasks.get(tid).task_spec == "new spec"
  end

  test "Tasks.mark_cancelled clears pickup" do
    tid = Tasks.insert(user_id: uid(), session_id: uid(),
                       task_title: "x", task_spec: "s",
                       task_type: "periodic", intvl_sec: 60)
    Tasks.mark_cancelled(tid)
    t = Tasks.get(tid)
    assert t.task_status == "cancelled"
    assert t.time_to_pickup == nil
  end

  test "Tasks.active_for_session returns only non-terminal tasks, oldest first" do
    sid = uid(); uid_ = uid()
    a = Tasks.insert(user_id: uid_, session_id: sid, task_title: "a", task_spec: "s")
    b = Tasks.insert(user_id: uid_, session_id: sid, task_title: "b", task_spec: "s")
    Tasks.mark_ongoing(b)
    c = Tasks.insert(user_id: uid_, session_id: sid, task_title: "c", task_spec: "s")
    Tasks.mark_done(c, "done")

    active = Tasks.active_for_session(sid)
    ids    = Enum.map(active, & &1.task_id)
    assert a in ids
    assert b in ids
    refute c in ids
  end

  # ─── SessionProgress ─────────────────────────────────────────────────────

  test "SessionProgress.append_tool_pending + mark_tool_done" do
    sid = uid(); uid_ = uid()
    tid = Tasks.insert(user_id: uid_, session_id: sid, task_title: "x", task_spec: "s")
    ctx = %{session_id: sid, user_id: uid_, task_id: tid}

    {:ok, inserted} = SessionProgress.append_tool_pending(ctx, "web_fetch(example.com)")
    [row] = SessionProgress.fetch_for_task(tid)
    assert row.id == inserted.id
    assert row.kind == "tool"
    assert row.status == "pending"
    assert row.label == "web_fetch(example.com)"

    :ok = SessionProgress.mark_tool_done(inserted.id)
    [row2] = SessionProgress.fetch_for_task(tid)
    assert row2.status == "done"
  end

  test "SessionProgress truncates large labels" do
    sid = uid(); uid_ = uid()
    tid = Tasks.insert(user_id: uid_, session_id: sid, task_title: "x", task_spec: "s")
    ctx = %{session_id: sid, user_id: uid_, task_id: tid}
    big = String.duplicate("a", 10_000)
    {:ok, _} = SessionProgress.append_tool_pending(ctx, big)
    [row] = SessionProgress.fetch_for_task(tid)
    assert String.length(row.label) < 5_000
    assert String.ends_with?(row.label, "[truncated]")
  end

  test "SessionProgress.fetch_for_session filters by session_id + since_id cursor" do
    s1 = uid(); s2 = uid(); uid_ = uid()
    t1 = Tasks.insert(user_id: uid_, session_id: s1, task_title: "a", task_spec: "s")
    t2 = Tasks.insert(user_id: uid_, session_id: s2, task_title: "b", task_spec: "s")

    {:ok, a1} = SessionProgress.append_tool_pending(%{session_id: s1, user_id: uid_, task_id: t1}, "x")
    {:ok, _a2} = SessionProgress.append_tool_pending(%{session_id: s2, user_id: uid_, task_id: t2}, "y")
    {:ok, a3} = SessionProgress.append_tool_pending(%{session_id: s1, user_id: uid_, task_id: t1}, "z")

    # Full fetch: both of s1's rows, in insertion order.
    rows = SessionProgress.fetch_for_session(s1)
    assert Enum.map(rows, & &1.id) == [a1.id, a3.id]

    # Past-cursor fetch: cursor only suppresses id ≤ since for DONE rows;
    # pending rows are always re-emitted so the FE can pick up sub_labels
    # appended to an already-cached pending row (e.g. web_search's
    # parallel fetches streaming into the same progress row after it
    # was first seen).
    rows = SessionProgress.fetch_for_session(s1, a1.id)
    assert Enum.map(rows, & &1.id) == [a1.id, a3.id]

    # Flip a1 to done → now the cursor suppresses it.
    :ok = SessionProgress.mark_tool_done(a1.id)
    rows = SessionProgress.fetch_for_session(s1, a1.id)
    assert Enum.map(rows, & &1.id) == [a3.id]
  end

  # ─── delete_pending_for_session (interrupt zombie cleanup) ───────────────

  test "delete_pending_for_session removes zombie pending rows, leaves done rows intact" do
    s1 = uid(); s2 = uid(); uid_ = uid()
    seed_session(s1, uid_)
    seed_session(s2, uid_)
    t1 = Tasks.insert(user_id: uid_, session_id: s1, task_title: "x", task_spec: "s")
    t2 = Tasks.insert(user_id: uid_, session_id: s2, task_title: "y", task_spec: "s")

    # Seed s1 with two pending rows (simulating a killed mid-tool turn)
    # and one already-done row (tool that completed BEFORE the kill).
    {:ok, pending_a} = SessionProgress.append_tool_pending(
      %{session_id: s1, user_id: uid_, task_id: t1}, "web_search(q1)")
    {:ok, pending_b} = SessionProgress.append_tool_pending(
      %{session_id: s1, user_id: uid_, task_id: t1}, "web_fetch(url)")
    {:ok, done_c}    = SessionProgress.append_tool_pending(
      %{session_id: s1, user_id: uid_, task_id: t1}, "create_task(…)")
    :ok = SessionProgress.mark_tool_done(done_c.id)

    # Seed s2 with a pending row — MUST NOT be affected by s1's cleanup.
    {:ok, other_session_pending} = SessionProgress.append_tool_pending(
      %{session_id: s2, user_id: uid_, task_id: t2}, "unrelated(x)")

    :ok = SessionProgress.delete_pending_for_session(s1)

    # Both s1 pending rows are gone.
    s1_rows = SessionProgress.fetch_for_session(s1)
    s1_ids  = Enum.map(s1_rows, & &1.id)
    refute pending_a.id in s1_ids,
           "pending_a should have been deleted by the interrupt cleanup"
    refute pending_b.id in s1_ids,
           "pending_b should have been deleted by the interrupt cleanup"

    # The done row survived — interrupt cleanup is scoped to pending only.
    assert done_c.id in s1_ids,
           "done rows are audit trail and must NOT be touched by interrupt cleanup"

    # Other session's pending row is untouched — cleanup is session-scoped.
    s2_rows = SessionProgress.fetch_for_session(s2)
    assert other_session_pending.id in Enum.map(s2_rows, & &1.id),
           "delete_pending_for_session must not cross session boundaries"
  end

  test "delete_pending_for_session is a no-op on an unknown session (no rows, no crash)" do
    assert :ok = SessionProgress.delete_pending_for_session("does-not-exist-#{T.uid()}")
  end

  # ─── TaskRuntime periodic scheduling ─────────────────────────────────────

  test "TaskRuntime.schedule_pickup arms a timer (basic smoke test)" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)
    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "ping", task_spec: "s",
                       task_type: "periodic", intvl_sec: 1)
    # Just smoke-test that the cast doesn't crash; the actual timer fire is
    # gated on UserAgent.Supervisor in prod which we don't boot in tests.
    :ok = TaskRuntime.schedule_pickup(tid, System.os_time(:millisecond) + 60_000)
    :ok = TaskRuntime.cancel_pickup(tid)
  end

  # ─── Summariser (on-demand) ──────────────────────────────────────────────

  test "summarize_and_announce: writes a summary row from activity log" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)
    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "research", task_spec: "multi-step research")
    ctx = %{session_id: sid, user_id: uid_, task_id: tid}
    {:ok, a} = SessionProgress.append_tool_pending(ctx, "web_search(btc)")
    :ok      = SessionProgress.mark_tool_done(a.id)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, "Researching: fetching btc news."}
    end)

    {:ok, text} = TaskRuntime.summarize_and_announce(tid, force: true)
    assert String.contains?(text, "Researching")

    rows = SessionProgress.fetch_for_task(tid)
    assert Enum.any?(rows, fn r -> r.kind == "summary" end)
  end

  test "summarize_and_announce(force: false) is a no-op when nothing new" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)
    tid = Tasks.insert(user_id: uid_, session_id: sid, task_title: "x", task_spec: "s")
    assert :ok = TaskRuntime.summarize_and_announce(tid, force: false)
  end

  test "summarize_and_announce(force: true) emits canned message when nothing new" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)
    tid = Tasks.insert(user_id: uid_, session_id: sid, task_title: "quiet", task_spec: "s")
    {:ok, text} = TaskRuntime.summarize_and_announce(tid, force: true)
    assert String.contains?(text, "No new activity") or String.contains?(text, "Không có")
  end
end
