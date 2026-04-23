# Integration tests: BE side of periodic-task delivery visibility.
# Run with: MIX_ENV=test mix test test/itgr_poll_periodic_delivery.exs
#
# Covers the regression where periodic-task-delivered assistant messages
# landed in sessions.messages but the FE only ever rendered the first
# one. Root cause on the BE was that `/poll`'s `is_working` flag went
# false between periodic firings (fetch_next_due returns nil when the
# next pickup is in the future), dropping the FE from 500 ms to 5 s
# idle polling. This file locks in:
#
#   - has_pending_periodic_for_session/1 accurately reports armed
#     periodic tasks regardless of whether their pickup is due yet.
#   - Cross-session isolation (one session's armed periodic doesn't
#     mark another session as "working").
#   - Status / type filtering: only pending + periodic counts.
#
# The FE scroll / render resilience is tested by manual verification
# against the symptom; those are pure-JS changes with no BE counterpart.

defmodule Itgr.PollPeriodicDelivery do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.Tasks
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_session(sid, user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, user_id, "assistant", "[]", now, now])
  end

  # ─── has_pending_periodic_for_session ────────────────────────────────────

  test "true when a periodic task is pending with a FUTURE pickup time" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)

    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "joke every 30s", task_spec: "tell jokes",
                       task_type: "periodic", intvl_sec: 30)

    # Fresh periodic task: status=pending, time_to_pickup = now + 30s (future).
    t = Tasks.get(tid)
    assert t.task_status == "pending"
    assert t.task_type == "periodic"
    assert is_integer(t.time_to_pickup)

    assert Tasks.has_pending_periodic_for_session(sid),
           "armed periodic in the future MUST be visible to is_working logic"
  end

  test "true even when the pickup is already due (belt-and-braces with fetch_next_due)" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)

    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "hb", task_spec: "x",
                       task_type: "periodic", intvl_sec: 1)

    # Force pickup into the past — simulating a task that's overdue.
    now = System.os_time(:millisecond)
    query!(Repo, "UPDATE tasks SET time_to_pickup=? WHERE task_id=?",
           [now - 5_000, tid])

    assert Tasks.has_pending_periodic_for_session(sid)
  end

  test "false when the only periodic task is DONE" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)

    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "one-shot", task_spec: "x",
                       task_type: "periodic", intvl_sec: 30)
    Tasks.mark_done(tid, "final cycle complete")

    # mark_done on a periodic auto-reschedules (status=pending again), so
    # to simulate a fully-terminal periodic we flip it manually.
    query!(Repo, "UPDATE tasks SET task_status='done', time_to_pickup=NULL WHERE task_id=?",
           [tid])

    refute Tasks.has_pending_periodic_for_session(sid),
           "done periodics should not keep the session flagged as working"
  end

  test "false when the only periodic task was CANCELLED" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)

    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "hb", task_spec: "x",
                       task_type: "periodic", intvl_sec: 30)
    Tasks.mark_cancelled(tid)

    refute Tasks.has_pending_periodic_for_session(sid),
           "cancelled periodics must not extend is_working"
  end

  test "false for one-off tasks regardless of status" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)

    # pending one-off with a future pickup — exists only for periodic tasks
    # normally, but simulate the edge case anyway.
    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "once", task_spec: "x",
                       task_type: "one_off")
    now = System.os_time(:millisecond)
    query!(Repo, "UPDATE tasks SET time_to_pickup=? WHERE task_id=?",
           [now + 60_000, tid])

    refute Tasks.has_pending_periodic_for_session(sid),
           "one-off tasks should never drive is_working via the periodic check"
  end

  test "cross-session isolation — one session's periodic does NOT flag another" do
    s1 = uid(); s2 = uid(); uid_ = uid()
    seed_session(s1, uid_); seed_session(s2, uid_)

    # s1 has an armed periodic; s2 has no tasks at all.
    _tid = Tasks.insert(user_id: uid_, session_id: s1,
                        task_title: "ticker", task_spec: "x",
                        task_type: "periodic", intvl_sec: 30)

    assert Tasks.has_pending_periodic_for_session(s1)
    refute Tasks.has_pending_periodic_for_session(s2),
           "sessions without a periodic must not be flagged"
  end

  test "periodic with NULL time_to_pickup is NOT counted (not actually armed)" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)

    tid = Tasks.insert(user_id: uid_, session_id: sid,
                       task_title: "limbo", task_spec: "x",
                       task_type: "periodic", intvl_sec: 30)
    query!(Repo, "UPDATE tasks SET time_to_pickup=NULL WHERE task_id=?", [tid])

    refute Tasks.has_pending_periodic_for_session(sid),
           "periodic w/o an armed pickup ts is not scheduled; don't flag"
  end

  # ─── session_active_periodic (single-periodic policy) ────────────────────

  describe "session_active_periodic/1" do
    test "returns the pending periodic task" do
      sid = uid(); uid_ = uid()
      seed_session(sid, uid_)
      tid = Tasks.insert(user_id: uid_, session_id: sid,
                         task_title: "jokes", task_spec: "x",
                         task_type: "periodic", intvl_sec: 30)

      assert %{task_id: ^tid, task_title: "jokes", task_type: "periodic"} =
               Tasks.session_active_periodic(sid)
    end

    test "returns the ongoing periodic task (mid-turn)" do
      sid = uid(); uid_ = uid()
      seed_session(sid, uid_)
      tid = Tasks.insert(user_id: uid_, session_id: sid,
                         task_title: "still working", task_spec: "x",
                         task_type: "periodic", intvl_sec: 30)
      Tasks.mark_ongoing(tid)

      assert %{task_id: ^tid, task_status: "ongoing"} =
               Tasks.session_active_periodic(sid)
    end

    test "returns the paused periodic task (user explicitly suspended)" do
      sid = uid(); uid_ = uid()
      seed_session(sid, uid_)
      tid = Tasks.insert(user_id: uid_, session_id: sid,
                         task_title: "on hold", task_spec: "x",
                         task_type: "periodic", intvl_sec: 30)
      Tasks.mark_paused(tid)

      assert %{task_id: ^tid, task_status: "paused"} =
               Tasks.session_active_periodic(sid)
    end

    test "returns nil when the only periodic is cancelled" do
      sid = uid(); uid_ = uid()
      seed_session(sid, uid_)
      tid = Tasks.insert(user_id: uid_, session_id: sid,
                         task_title: "stopped", task_spec: "x",
                         task_type: "periodic", intvl_sec: 30)
      Tasks.mark_cancelled(tid)

      assert Tasks.session_active_periodic(sid) == nil
    end

    test "returns nil when the only task is one_off (policy only applies to periodic)" do
      sid = uid(); uid_ = uid()
      seed_session(sid, uid_)
      _tid = Tasks.insert(user_id: uid_, session_id: sid,
                          task_title: "once", task_spec: "x",
                          task_type: "one_off")

      assert Tasks.session_active_periodic(sid) == nil
    end

    test "returns the OLDEST active periodic (stable across polls)" do
      sid = uid(); uid_ = uid()
      seed_session(sid, uid_)
      t1 = Tasks.insert(user_id: uid_, session_id: sid,
                        task_title: "first", task_spec: "x",
                        task_type: "periodic", intvl_sec: 30)
      Process.sleep(5)
      _t2 = Tasks.insert(user_id: uid_, session_id: sid,
                         task_title: "second", task_spec: "x",
                         task_type: "periodic", intvl_sec: 30)

      assert %{task_id: ^t1, task_title: "first"} =
               Tasks.session_active_periodic(sid)
    end

    test "cross-session isolation" do
      s1 = uid(); s2 = uid(); uid_ = uid()
      seed_session(s1, uid_); seed_session(s2, uid_)
      _tid = Tasks.insert(user_id: uid_, session_id: s1,
                          task_title: "s1 periodic", task_spec: "x",
                          task_type: "periodic", intvl_sec: 30)

      assert %{task_title: "s1 periodic"} = Tasks.session_active_periodic(s1)
      assert Tasks.session_active_periodic(s2) == nil
    end
  end
end
