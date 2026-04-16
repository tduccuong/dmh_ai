# Integration tests: MasterBuffer read/write lifecycle.
# Run with: MIX_ENV=test mix test test/itgr_master_buffer.exs

defmodule Itgr.MasterBuffer do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.MasterBuffer

  defp uid, do: T.uid()

  # ─── append + fetch_unconsumed ─────────────────────────────────────────────

  test "append + fetch_unconsumed returns entry with correct fields" do
    sid = uid(); uid = uid(); wid = uid()
    MasterBuffer.append(sid, uid, "result text", "short summary", wid)

    entries = MasterBuffer.fetch_unconsumed(sid)
    assert length(entries) == 1
    [e] = entries
    assert e.content == "result text"
    assert e.worker_id == wid
    assert is_integer(e.id)
    assert is_integer(e.created_at)
  end

  test "multiple appends are returned in chronological order" do
    sid = uid(); uid = uid()
    MasterBuffer.append(sid, uid, "first",  nil, nil)
    MasterBuffer.append(sid, uid, "second", nil, nil)
    MasterBuffer.append(sid, uid, "third",  nil, nil)

    entries = MasterBuffer.fetch_unconsumed(sid)
    assert length(entries) == 3
    contents = Enum.map(entries, & &1.content)
    assert contents == ["first", "second", "third"]
  end

  test "fetch_unconsumed is isolated to the given session_id" do
    sid_a = uid(); sid_b = uid(); uid = uid()
    MasterBuffer.append(sid_a, uid, "for A", nil, nil)
    MasterBuffer.append(sid_b, uid, "for B", nil, nil)

    assert length(MasterBuffer.fetch_unconsumed(sid_a)) == 1
    assert length(MasterBuffer.fetch_unconsumed(sid_b)) == 1
    assert hd(MasterBuffer.fetch_unconsumed(sid_a)).content == "for A"
    assert hd(MasterBuffer.fetch_unconsumed(sid_b)).content == "for B"
  end

  # ─── mark_consumed ─────────────────────────────────────────────────────────

  test "mark_consumed prevents entry from appearing in fetch_unconsumed" do
    sid = uid(); uid = uid()
    MasterBuffer.append(sid, uid, "content", nil, nil)
    [e] = MasterBuffer.fetch_unconsumed(sid)

    MasterBuffer.mark_consumed([e.id])

    assert MasterBuffer.fetch_unconsumed(sid) == []
  end

  test "mark_consumed([]) is a no-op" do
    sid = uid(); uid = uid()
    MasterBuffer.append(sid, uid, "content", nil, nil)
    MasterBuffer.mark_consumed([])
    assert length(MasterBuffer.fetch_unconsumed(sid)) == 1
  end

  test "mark_consumed only affects given IDs, leaving others visible" do
    sid = uid(); uid = uid()
    MasterBuffer.append(sid, uid, "keep",   nil, nil)
    MasterBuffer.append(sid, uid, "consume",nil, nil)
    [e1, e2] = MasterBuffer.fetch_unconsumed(sid)

    MasterBuffer.mark_consumed([e2.id])
    remaining = MasterBuffer.fetch_unconsumed(sid)
    assert length(remaining) == 1
    assert hd(remaining).content == "keep"
    assert hd(remaining).id == e1.id
  end

  # ─── append_notification ───────────────────────────────────────────────────

  test "append_notification creates a consumed entry (not visible in fetch_unconsumed)" do
    sid = uid(); uid = uid()
    MasterBuffer.append_notification(sid, uid, "job done")
    assert MasterBuffer.fetch_unconsumed(sid) == []
  end

  # ─── fetch_notifications ───────────────────────────────────────────────────

  test "fetch_notifications returns entries since the given timestamp" do
    user_id = uid()
    sid_a   = uid()
    sid_b   = uid()
    before  = System.os_time(:millisecond)
    # Sleep 2ms so appends get a strictly later created_at than `before`.
    Process.sleep(2)

    MasterBuffer.append(sid_a, user_id, "content a", "summary a", nil)
    MasterBuffer.append(sid_b, user_id, "content b", "summary b", nil)

    notifs = MasterBuffer.fetch_notifications(user_id, before)
    assert length(notifs) >= 2
    summaries = Enum.map(notifs, & &1.summary)
    assert "summary a" in summaries
    assert "summary b" in summaries
  end

  test "fetch_notifications excludes entries older than since_ms" do
    user_id = uid()
    sid     = uid()
    MasterBuffer.append(sid, user_id, "old", "old summary", nil)
    # Sleep so the next append is strictly later, and `after_old` falls in between.
    Process.sleep(2)
    after_old = System.os_time(:millisecond)
    Process.sleep(2)
    MasterBuffer.append(sid, user_id, "new", "new summary", nil)

    notifs = MasterBuffer.fetch_notifications(user_id, after_old)
    summaries = Enum.map(notifs, & &1.summary)
    assert "new summary" in summaries
    refute "old summary" in summaries
  end

  test "fetch_notifications is scoped to user_id" do
    user_a = uid(); user_b = uid()
    sid_a  = uid(); sid_b  = uid()
    before = System.os_time(:millisecond)
    Process.sleep(2)
    MasterBuffer.append(sid_a, user_a, "c", "summary for A", nil)
    MasterBuffer.append(sid_b, user_b, "c", "summary for B", nil)

    notifs_a = MasterBuffer.fetch_notifications(user_a, before)
    assert Enum.all?(notifs_a, &(&1.summary == "summary for A"))
  end

  # ─── fetch_for_worker ──────────────────────────────────────────────────────

  test "fetch_for_worker returns only entries for the given worker_id" do
    sid    = uid(); uid = uid()
    wid_a  = uid(); wid_b = uid()
    MasterBuffer.append(sid, uid, "from A", nil, wid_a)
    MasterBuffer.append(sid, uid, "from B", nil, wid_b)

    results = MasterBuffer.fetch_for_worker(sid, wid_a)
    assert length(results) == 1
    assert hd(results).content == "from A"
  end

  test "fetch_for_worker returns entries in chronological order" do
    sid = uid(); uid = uid(); wid = uid()
    # Sleep between appends so each gets a distinct created_at, ensuring stable ORDER BY.
    MasterBuffer.append(sid, uid, "step 1", nil, wid); Process.sleep(2)
    MasterBuffer.append(sid, uid, "step 2", nil, wid); Process.sleep(2)
    MasterBuffer.append(sid, uid, "step 3", nil, wid)

    results = MasterBuffer.fetch_for_worker(sid, wid)
    contents = Enum.map(results, & &1.content)
    assert contents == ["step 1", "step 2", "step 3"]
  end

  test "fetch_for_worker respects limit parameter" do
    sid = uid(); uid = uid(); wid = uid()
    # Sleep between appends to guarantee distinct timestamps and stable ordering.
    Enum.each(1..5, fn i ->
      MasterBuffer.append(sid, uid, "item #{i}", nil, wid)
      if i < 5, do: Process.sleep(2)
    end)

    results = MasterBuffer.fetch_for_worker(sid, wid, 3)
    assert length(results) == 3
    # fetch_for_worker returns the N most recent in chronological order
    contents = Enum.map(results, & &1.content)
    assert contents == ["item 3", "item 4", "item 5"]
  end
end
