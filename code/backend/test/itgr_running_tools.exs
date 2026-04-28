# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.RunningTools do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.RunningTools

  setup do
    RunningTools.init()
    sid = "rt-" <> T.uid()
    on_exit(fn -> RunningTools.clear(sid) end)
    {:ok, sid: sid}
  end

  test "lookup returns nil before register", %{sid: sid} do
    assert RunningTools.lookup(sid) == nil
  end

  test "register / lookup round trip", %{sid: sid} do
    entry = %{
      tool_call_id:    "call_abc",
      progress_row_id: 42,
      started_at_ms:   1_700_000_000_000,
      script_preview:  "echo hi",
      pid:             12345,
      run_id:          "deadbeef"
    }

    :ok = RunningTools.register(sid, entry)
    got = RunningTools.lookup(sid)

    assert got.tool_call_id == "call_abc"
    assert got.progress_row_id == 42
    assert got.started_at_ms == 1_700_000_000_000
    assert got.pid == 12345
  end

  test "clear removes the entry", %{sid: sid} do
    :ok = RunningTools.register(sid, %{
      tool_call_id: "x", progress_row_id: 1,
      started_at_ms: 1, script_preview: "", pid: 1, run_id: "r"
    })

    assert RunningTools.lookup(sid) != nil
    :ok = RunningTools.clear(sid)
    assert RunningTools.lookup(sid) == nil
  end

  test "register replaces a prior entry for the same session", %{sid: sid} do
    :ok = RunningTools.register(sid, %{
      tool_call_id: "first", progress_row_id: 1,
      started_at_ms: 1, script_preview: "", pid: 100, run_id: "r1"
    })

    :ok = RunningTools.register(sid, %{
      tool_call_id: "second", progress_row_id: 2,
      started_at_ms: 2, script_preview: "", pid: 200, run_id: "r2"
    })

    got = RunningTools.lookup(sid)
    assert got.tool_call_id == "second"
    assert got.pid == 200
  end

  test "different sessions are independent" do
    a = "rt-a-" <> T.uid()
    b = "rt-b-" <> T.uid()

    :ok = RunningTools.register(a, %{
      tool_call_id: "ca", progress_row_id: 1,
      started_at_ms: 1, script_preview: "", pid: 1, run_id: "ra"
    })

    :ok = RunningTools.register(b, %{
      tool_call_id: "cb", progress_row_id: 2,
      started_at_ms: 2, script_preview: "", pid: 2, run_id: "rb"
    })

    assert RunningTools.lookup(a).tool_call_id == "ca"
    assert RunningTools.lookup(b).tool_call_id == "cb"

    RunningTools.clear(a)
    assert RunningTools.lookup(a) == nil
    assert RunningTools.lookup(b).tool_call_id == "cb"

    RunningTools.clear(b)
  end

  test "kill_all_for_session returns :none when no entry", %{sid: sid} do
    assert RunningTools.kill_all_for_session(sid) == :none
  end

  test "kill_all_for_session clears the entry even when the kill itself is a no-op" do
    # Use a PID we know doesn't exist in any container — kill_all is
    # best-effort; the contract is "clear the ETS entry so the chain
    # never wedges on a stuck `kill -0` lookup". Real TERM/KILL
    # mechanics are tested by the integration suite (which requires
    # the sandbox container to actually be up).
    sid = "rt-kill-" <> T.uid()
    :ok = RunningTools.register(sid, %{
      tool_call_id: "x", progress_row_id: 99,
      started_at_ms: 1, script_preview: "", pid: 999_999_999, run_id: "rx"
    })

    assert {:killed, %{tool_call_id: "x"}} = RunningTools.kill_all_for_session(sid)
    assert RunningTools.lookup(sid) == nil
  end

  test "init/0 is idempotent" do
    assert :ok = RunningTools.init()
    assert :ok = RunningTools.init()
  end
end
