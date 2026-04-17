# Integration tests for the one-off Worker loop with stubbed LLM.
# Run with: MIX_ENV=test mix test test/itgr_worker_loop.exs

defmodule Itgr.WorkerLoop do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{Jobs, Worker}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  # Seed a jobs row and return ctx + job_id for Worker.run.
  defp seed_job(opts \\ []) do
    user_id    = Keyword.get(opts, :user_id, uid())
    session_id = Keyword.get(opts, :session_id, uid())
    worker_id  = Keyword.get(opts, :worker_id, uid())

    job_id =
      Jobs.insert(
        user_id:    user_id,
        session_id: session_id,
        job_type:   "one_off",
        intvl_sec:  0,
        job_title:  "test job",
        job_spec:   Keyword.get(opts, :job_spec, "do something"),
        job_status: "running"
      )

    ctx = %{
      user_id:     user_id,
      session_id:  session_id,
      worker_id:   worker_id,
      job_id:      job_id,
      agent_pid:   self(),
      description: "test job"
    }

    {ctx, job_id}
  end

  defp final_row(job_id) do
    r = query!(Dmhai.Repo,
      "SELECT kind, content, signal_status FROM worker_status WHERE job_id=? AND kind='final' ORDER BY id DESC LIMIT 1",
      [job_id])
    case r.rows do
      [[k, c, s]] -> %{kind: k, content: c, signal_status: s}
      _ -> nil
    end
  end

  defp status_count(job_id, kind) do
    r = query!(Dmhai.Repo,
      "SELECT COUNT(*) FROM worker_status WHERE job_id=? AND kind=?",
      [job_id, kind])
    [[n]] = r.rows
    n
  end

  # ─── Signal contract ──────────────────────────────────────────────────────

  test "worker exits cleanly when signal(JOB_DONE) is called" do
    {ctx, job_id} = seed_job()

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, {:tool_calls, [
        T.tool_call("signal", %{"status" => "JOB_DONE", "result" => "all done"})
      ]}}
    end)

    assert {:ok, {:signal, "JOB_DONE", "all done"}} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "JOB_DONE"
    assert final.content == "all done"
  end

  test "worker exits cleanly when signal(BLOCKED) is called" do
    {ctx, job_id} = seed_job()

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, {:tool_calls, [
        T.tool_call("signal", %{"status" => "BLOCKED", "reason" => "API down"})
      ]}}
    end)

    assert {:ok, {:signal, "BLOCKED", "API down"}} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "BLOCKED"
    assert final.content == "API down"
  end

  test "missing job_id in ctx causes immediate error" do
    ctx = %{user_id: uid(), session_id: uid(), worker_id: uid()}
    assert {:error, :missing_job_id} = Worker.run("task", ctx)
  end

  # ─── Protocol violation: plain text instead of signal ─────────────────────

  test "plain text response is nudged, then BLOCKED after max nudges" do
    {ctx, job_id} = seed_job()

    # Always return text — never calls signal. Should nudge then force BLOCKED.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "Here's my answer."} end)

    assert {:error, :no_signal_after_nudges} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "BLOCKED"
    assert String.contains?(final.content, "refused to call signal")
  end

  # ─── Worker_status progress rows ──────────────────────────────────────────

  test "each tool call produces tool_call + tool_result rows" do
    {ctx, job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0 do
        {:ok, {:tool_calls, [T.tool_call("datetime", %{})]}}
      else
        {:ok, {:tool_calls, [
          T.tool_call("signal", %{"status" => "JOB_DONE", "result" => "done"})
        ]}}
      end
    end)

    Worker.run("task", ctx)

    # iter 1: 1 tool_call + 1 tool_result.
    # iter 2: 1 tool_call (signal) + 1 tool_result + 1 final.
    assert status_count(job_id, "tool_call")   == 2
    assert status_count(job_id, "tool_result") == 2
    assert status_count(job_id, "final")       == 1
  end

  # ─── LLM error ────────────────────────────────────────────────────────────

  test "LLM error synthesizes a BLOCKED final row" do
    {ctx, job_id} = seed_job()
    T.stub_llm_call(fn _model, _msgs, _opts -> {:error, "API unavailable"} end)

    assert {:error, _} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "BLOCKED"
    assert String.contains?(final.content, "API unavailable")
  end

  test "empty LLM response synthesizes a BLOCKED final row" do
    {ctx, job_id} = seed_job()
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, ""} end)

    assert {:error, :empty_response} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "BLOCKED"
  end

  # ─── Signal tool validation ───────────────────────────────────────────────

  test "signal with invalid status returns tool error (loops for retry)" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0 do
        # Invalid status → Signal.execute returns {:error, ...} → content="Error: ..."
        {:ok, {:tool_calls, [T.tool_call("signal", %{"status" => "WEIRD"})]}}
      else
        {:ok, {:tool_calls, [T.tool_call("signal", %{"status" => "JOB_DONE", "result" => "ok"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", "ok"}} = Worker.run("task", ctx)
  end
end
