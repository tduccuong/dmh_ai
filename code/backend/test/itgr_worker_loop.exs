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

  test "worker exits cleanly when job_signal(JOB_DONE) is called" do
    {ctx, job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan approval (required by phase gate)
    # n=1: job_signal(JOB_DONE) with result report
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0 do
        {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["complete the task", "finalize"], "rationale" => "simple"})]}}
      else
        {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "Task completed successfully."})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", "Task completed successfully."}} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "JOB_DONE"
    assert final.content == "Task completed successfully."
  end

  test "worker exits cleanly when job_signal(JOB_BLOCKED) is called" do
    {ctx, job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan approval; n=1: job_signal(JOB_BLOCKED)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0 do
        {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["attempt task", "finalize"], "rationale" => "simple"})]}}
      else
        {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_BLOCKED", "reason" => "API down"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_BLOCKED", "API down"}} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "JOB_BLOCKED"
    assert final.content == "API down"
  end

  test "missing job_id in ctx causes immediate error" do
    ctx = %{user_id: uid(), session_id: uid(), worker_id: uid()}
    assert {:error, :missing_job_id} = Worker.run("task", ctx)
  end

  # ─── Protocol violation: plain text instead of signal ─────────────────────

  test "plain text response is nudged, then BLOCKED after max nudges" do
    {ctx, job_id} = seed_job()

    # Always return text — never calls job_signal. Should nudge then force BLOCKED.
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

    # n=0: plan (1 tool_call + 1 tool_result)
    # n=1: job_signal(JOB_DONE) (1 tool_call + 1 tool_result + 1 final)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0 do
        {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["do task", "finalize"], "rationale" => "test"})]}}
      else
        {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    Worker.run("task", ctx)

    # iter 0: 1 tool_call + 1 tool_result (plan).
    # iter 1: 1 tool_call (job_signal) + 1 tool_result + 1 final.
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

  # ─── Plan step count validation ───────────────────────────────────────────

  test "plan with too few steps is rejected; model revises and succeeds" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan with 1 step (below planMinSteps=2) → rejected
    # n=1: plan with 2 valid steps → approved
    # n=2: job_signal(JOB_DONE)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["only one step"]})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step 1", "step 2"], "rationale" => "revised"})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", _}} = Worker.run("task", ctx)
  end

  test "plan with too many steps is rejected; model revises and succeeds" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    too_many = Enum.map(1..11, &"step #{&1}")  # 11 > planMaxSteps=10

    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => too_many})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step 1", "step 2"], "rationale" => "condensed"})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", _}} = Worker.run("task", ctx)
  end

  # ─── job_signal tool validation ───────────────────────────────────────────

  test "job_signal with invalid status returns tool error (loops for retry)" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["do task", "finalize"], "rationale" => "test"})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "WEIRD"})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", _}} = Worker.run("task", ctx)
  end

  # ─── step_signal batching ─────────────────────────────────────────────────

  test "step_signal batched with other tools is rejected; model corrects and succeeds" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan; n=1: bash + step_signal batched → rejected
    # n=2: step_signal alone (STEP_DONE, id=1) → ok; n=3: JOB_DONE
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step one", "finalize"], "rationale" => "test"})]}}
        1 -> {:ok, {:tool_calls, [
               T.tool_call("bash", %{"command" => "echo hi"}),
               T.tool_call("step_signal", %{"status" => "STEP_DONE", "id" => 1})
             ]}}
        2 -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "STEP_DONE", "id" => 1})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", _}} = Worker.run("task", ctx)
  end

  # ─── step_signal phase transitions ────────────────────────────────────────

  test "STEP_DONE advances current_step and worker completes with JOB_DONE" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan (steps 1 & 2)
    # n=1: step_signal(STEP_DONE, id=1) → advances to step 2
    # n=2: job_signal(JOB_DONE) from step 2
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step one", "step two"], "rationale" => "two steps"})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "STEP_DONE", "id" => 1})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", _}} = Worker.run("task", ctx)
  end

  test "STEP_DONE on last step nudges model to call job_signal with result" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    # n=0: plan (2 steps); n=1: STEP_DONE(1); n=2: STEP_DONE(2) — last step.
    # The worker must NOT exit yet; it injects a nudge and loops once more.
    # n=3: model sees the nudge and calls job_signal(JOB_DONE, result: "report").
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step one", "step two"], "rationale" => "two steps"})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "STEP_DONE", "id" => 1})]}}
        2 -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "STEP_DONE", "id" => 2})]}}
        3 ->
          send(test_pid, :job_signal_call)
          {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "Final report."})]}}
        _ ->
          send(test_pid, :unexpected_call)
          {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", "Final report."}} = Worker.run("task", ctx)
    assert_received :job_signal_call
    refute_received :unexpected_call
  end

  test "STEP_BLOCKED retries the step; success on retry" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan; n=1: STEP_BLOCKED(id=1); n=2: STEP_DONE(id=1); n=3: JOB_DONE
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step one", "finalize"], "rationale" => "simple"})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "STEP_BLOCKED", "id" => 1, "reason" => "network error"})]}}
        2 -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "STEP_DONE", "id" => 1})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", _}} = Worker.run("task", ctx)
  end

  test "STEP_BLOCKED exhausted forces JOB_BLOCKED" do
    {ctx, job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan; n=1,2,3: STEP_BLOCKED(id=1) three times (exhausts planStepMaxRetries=3)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step one", "finalize"], "rationale" => "simple"})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "STEP_BLOCKED", "id" => 1, "reason" => "persistent failure"})]}}
      end
    end)

    assert {:error, _} = Worker.run("task", ctx)

    final = final_row(job_id)
    assert final.signal_status == "BLOCKED"
    assert String.contains?(String.downcase(final.content), "step 1")
  end

  test "PLAN_REVISE resets plan phase and worker re-plans" do
    {ctx, _job_id} = seed_job()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # n=0: plan (steps 1 & 2); n=1: PLAN_REVISE (resets plan phase)
    # n=2: new plan (steps 1 & 2); n=3: JOB_DONE (last step)
    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      case n do
        0 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["step one", "step two"], "rationale" => "initial"})]}}
        1 -> {:ok, {:tool_calls, [T.tool_call("step_signal", %{"status" => "PLAN_REVISE", "new_steps" => ["revised one", "revised two"], "reason" => "scope changed"})]}}
        2 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => ["revised one", "revised two"], "rationale" => "revised"})]}}
        _ -> {:ok, {:tool_calls, [T.tool_call("job_signal", %{"status" => "JOB_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "JOB_DONE", _}} = Worker.run("task", ctx)
  end
end
