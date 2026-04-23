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
