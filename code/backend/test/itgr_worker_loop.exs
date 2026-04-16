# Integration tests: Worker.run and Worker.run_from_checkpoint with stubbed LLM.
# Run with: MIX_ENV=test mix test test/itgr_worker_loop.exs

defmodule Itgr.WorkerLoop do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{Worker, WorkerState}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  # Minimal context map that Worker.run requires.
  defp make_ctx(overrides \\ []) do
    %{
      user_id:     Keyword.get(overrides, :user_id,     uid()),
      session_id:  Keyword.get(overrides, :session_id,  uid()),
      worker_id:   Keyword.get(overrides, :worker_id,   uid()),
      agent_pid:   Keyword.get(overrides, :agent_pid,   self()),
      description: "test task"
    }
  end

  defp db_status(worker_id) do
    r = query!(Dmhai.Repo, "SELECT status FROM worker_state WHERE worker_id=?", [worker_id])
    case r.rows do
      [[s]] -> s
      [] -> nil
    end
  end

  defp buffer_contents(session_id) do
    r = query!(Dmhai.Repo,
      "SELECT content FROM master_buffer WHERE session_id=? ORDER BY created_at",
      [session_id])
    Enum.map(r.rows, fn [c] -> c end)
  end

  # ─── One-shot response ────────────────────────────────────────────────────

  test "one-shot: LLM returns text immediately → result in MasterBuffer" do
    ctx = make_ctx()
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "Task finished successfully."} end)

    assert {:ok, "Task finished successfully."} == Worker.run("complete this task", ctx)
    assert "Task finished successfully." in buffer_contents(ctx.session_id)
  end

  test "one-shot: worker_state marked done after completion" do
    ctx = make_ctx()
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "Done."} end)

    Worker.run("task", ctx)
    assert db_status(ctx.worker_id) == "done"
  end

  test "one-shot: worker_state row created with status='running' then transitions to 'done'" do
    ctx = make_ctx()
    # Verify row doesn't exist yet
    assert db_status(ctx.worker_id) == nil

    T.stub_llm_call(fn _model, _msgs, _opts ->
      # During the run, the row should already be 'running'
      send(self(), {:mid_status, db_status(ctx.worker_id)})
      {:ok, "Done."}
    end)

    Worker.run("task", ctx)

    assert_received {:mid_status, "running"}
    assert db_status(ctx.worker_id) == "done"
  end

  # ─── Tool-call loop ───────────────────────────────────────────────────────

  test "tool-call then text: final result in MasterBuffer, status=done" do
    ctx = make_ctx()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0 do
        # Unknown tool → ToolRegistry returns {:error, "Unknown tool: ..."} → becomes "Error: ..." content
        {:ok, {:tool_calls, [T.tool_call("noop_tool", %{})]}}
      else
        {:ok, "All done after tool call."}
      end
    end)

    result = Worker.run("use a tool then finish", ctx)

    assert {:ok, "All done after tool call."} == result
    assert db_status(ctx.worker_id) == "done"
    assert "All done after tool call." in buffer_contents(ctx.session_id)
  end

  test "tool-call loop: checkpoint written after each tool-call iteration" do
    ctx = make_ctx()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("noop1", %{})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("noop2", %{})]}}
        _ -> {:ok, "Finished after 2 tool calls."}
      end
    end)

    Worker.run("multi-step task", ctx)

    r = query!(Dmhai.Repo, "SELECT iter FROM worker_state WHERE worker_id=?", [ctx.worker_id])
    [[iter]] = r.rows
    assert iter == 2
  end

  # ─── LLM error ───────────────────────────────────────────────────────────

  test "LLM error → error message in MasterBuffer, worker marked done" do
    ctx = make_ctx()
    T.stub_llm_call(fn _model, _msgs, _opts -> {:error, "API unavailable"} end)

    assert {:error, _} = Worker.run("task", ctx)
    assert db_status(ctx.worker_id) == "done"

    [content] = buffer_contents(ctx.session_id)
    assert String.contains?(content, "Worker error")
  end

  # ─── run_from_checkpoint ─────────────────────────────────────────────────

  test "run_from_checkpoint: resumes from existing messages, result in buffer" do
    user_id = uid(); wid = uid(); sid = uid()

    prior_msgs = [
      %{"role" => "system",    "content" => "sys prompt"},
      %{"role" => "user",      "content" => "resume this task"},
      %{"role" => "assistant", "content" => "",
        "tool_calls" => [%{"id" => "tc1", "function" => %{"name" => "bash", "arguments" => %{}}}]},
      %{"role" => "tool",      "content" => "step 1 done", "tool_call_id" => "tc1"}
    ]

    checkpoint = %{
      worker_id:       wid,
      session_id:      sid,
      user_id:         user_id,
      task:            "resume this task",
      messages:        prior_msgs,
      rolling_summary: nil,
      iter:            1,
      periodic:        false
    }

    # Pre-insert the DB row (simulates the row left by the crash)
    WorkerState.upsert(wid, sid, user_id, "resume this task", prior_msgs, 1, false, nil, "recovering")

    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "Resumed and completed."} end)

    result = Worker.run_from_checkpoint(checkpoint, self())

    assert {:ok, "Resumed and completed."} == result
    assert db_status(wid) == "done"
    assert "Resumed and completed." in buffer_contents(sid)
  end

  test "run_from_checkpoint: rolling summary is injected into effective messages" do
    user_id = uid(); wid = uid(); sid = uid()

    prior_msgs = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user",   "content" => "task"}
    ]

    checkpoint = %{
      worker_id:       wid,
      session_id:      sid,
      user_id:         user_id,
      task:            "task",
      messages:        prior_msgs,
      rolling_summary: "Prior work: finished step A",
      iter:            3,
      periodic:        false
    }

    WorkerState.upsert(wid, sid, user_id, "task", prior_msgs, 3, false, "Prior work: finished step A", "recovering")

    test_pid = self()
    T.stub_llm_call(fn _model, msgs, _opts ->
      # The rolling summary should appear as a transient prefix message
      has_summary = Enum.any?(msgs, fn m ->
        role = m[:role] || m.role
        content = m[:content] || m.content || ""
        role == "user" and String.contains?(content, "Prior work: finished step A")
      end)
      send(test_pid, {:saw_rolling_summary, has_summary})
      {:ok, "done"}
    end)

    Worker.run_from_checkpoint(checkpoint, self())

    assert_received {:saw_rolling_summary, true}
  end

  test "run_from_checkpoint: iter from checkpoint is preserved in context" do
    user_id = uid(); wid = uid(); sid = uid()

    prior_msgs = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user",   "content" => "task"}
    ]

    checkpoint = %{
      worker_id:       wid,
      session_id:      sid,
      user_id:         user_id,
      task:            "task",
      messages:        prior_msgs,
      rolling_summary: nil,
      iter:            7,
      periodic:        false
    }

    WorkerState.upsert(wid, sid, user_id, "task", prior_msgs, 7, false, nil, "recovering")

    # One tool call → iter should be 8 in the checkpoint written during recovery
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0, do: {:ok, {:tool_calls, [T.tool_call("noop", %{})]}}, else: {:ok, "done"}
    end)

    Worker.run_from_checkpoint(checkpoint, self())

    r = query!(Dmhai.Repo, "SELECT iter FROM worker_state WHERE worker_id=?", [wid])
    [[iter]] = r.rows
    assert iter == 8
  end
end
