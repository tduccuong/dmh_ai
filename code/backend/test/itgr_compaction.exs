# Integration tests: context compaction — worker rolling-summary and master compact!.
# Run with: MIX_ENV=test mix test test/itgr_compaction.exs

defmodule Itgr.Compaction do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{Tasks, Worker, ContextEngine}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  # Seed a jobs row and return ctx with task_id (required by new Worker.run).
  defp make_ctx(overrides \\ []) do
    user_id    = Keyword.get(overrides, :user_id, uid())
    session_id = Keyword.get(overrides, :session_id, uid())
    worker_id  = Keyword.get(overrides, :worker_id, uid())

    task_id =
      Tasks.insert(
        user_id:    user_id,
        session_id: session_id,
        task_type:   "one_off",
        intvl_sec:  0,
        task_title:  "compaction test",
        task_spec:   "compaction test task",
        task_status: "running"
      )

    %{
      user_id:    user_id,
      session_id: session_id,
      worker_id:  worker_id,
      task_id:     task_id,
      agent_pid:  self(),
      description: "compaction test task"
    }
  end

  defp insert_session(session_id, user_id, messages) do
    now = System.os_time(:millisecond)
    query!(Dmhai.Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, "confidant", Jason.encode!(messages), now, now])
  end

  defp session_context(session_id, user_id) do
    r = query!(Dmhai.Repo,
      "SELECT context FROM sessions WHERE id=? AND user_id=?",
      [session_id, user_id])
    case r.rows do
      [[nil]]  -> %{}
      [[json]] -> Jason.decode!(json)
      _        -> %{}
    end
  end

  # ─── Worker rolling-summary compaction ───────────────────────────────────────
  #
  # Default thresholds: n=8 (middle stub tier), m=6 (recent tier).
  # Compaction fires when total messages > 1 + 8 + 6 + 5 = 20.
  #
  # Worker.run starts with [system_placeholder, user] = 2 messages.
  # Each LLM call (plan or tool) appends 2 messages (assistant + tool-result).
  # The first call (n=0) must be a plan call (phase gate). Subsequent calls are
  # mid-execution replans with unique args. After 10 LLM calls: 2 + 20 = 22 > 20
  # → compaction fires at the START of the 11th main-loop iteration (LLM call n=10
  # goes to the compactor, n=11+ resumes the main worker).

  test "worker: 10 tool-call iterations trigger compaction; summary is generated" do
    ctx = make_ctx()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    # n=0: plan call → plan approved (required by phase gate).
    # n=1..9: mid-execution replans with unique args — different rationale
    # each time so Police's identical-call check doesn't trip. Each adds 2
    # messages (assistant + tool-result), accumulating to 22 > 20 threshold.
    # n=10: the compactor LLM call fires (update_rolling_summary).
    # n=11+: post-compaction main loop → signal.
    T.stub_llm_call(fn _model, msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      cond do
        n < 10  -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => [%{"step" => "step #{n}", "tools" => []}], "rationale" => "r#{n}"})]}}
        n == 10 ->
          instr = msgs |> List.last() |> then(&(&1[:content] || &1["content"] || ""))
          send(test_pid, {:compaction_instr, instr})
          {:ok, "Compacted: completed 10 steps, output was X."}
        n == 11 -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => [%{"step" => "final step", "tools" => []}], "rationale" => "post-compact"})]}}
        true    -> {:ok, {:tool_calls, [T.tool_call("task_signal", %{"status" => "TASK_DONE", "result" => "done"})]}}
      end
    end)

    assert {:ok, {:signal, "TASK_DONE", _}} = Worker.run("do the thing", ctx)
    assert_received {:compaction_instr, instr}
    assert String.contains?(instr, "Summarise") or String.contains?(instr, "activity")
  end

  test "worker: if compactor LLM fails, old messages are NOT dropped (no silent context loss)" do
    ctx = make_ctx()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    # n=0..9: 10 LLM calls accumulate 22 messages (plan + 9 replans).
    # n=10: compactor call → simulate failure.
    # n=11: main worker call after failed compaction — must see the full history.
    T.stub_llm_call(fn _model, msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      cond do
        n < 10 ->
          {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => [%{"step" => "step #{n}", "tools" => []}], "rationale" => "r#{n}"})]}}

        n == 10 ->
          {:error, "compactor unreachable"}

        true ->
          send(test_pid, {:post_compact_msg_count, length(msgs)})
          {:ok, {:tool_calls, [T.tool_call("task_signal", %{"status" => "TASK_DONE", "result" => "done"})]}}
      end
    end)

    Worker.run("task", ctx)

    # Expected: 22 messages before compaction (1 system + 10 × (assistant + tool)
    # + 1 user). With the fix, compaction fails → messages kept intact.
    assert_received {:post_compact_msg_count, count}
    assert count >= 20,
      "expected full history retained after compactor failure, got #{count} msgs"
  end

  test "worker: after compaction, rolling_summary is injected as a prefix into the subsequent LLM call" do
    ctx = make_ctx()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    T.stub_llm_call(fn _model, msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      cond do
        n < 10  -> {:ok, {:tool_calls, [T.tool_call("plan", %{"steps" => [%{"step" => "step #{n}", "tools" => []}], "rationale" => "r#{n}"})]}}
        n == 10 -> {:ok, "Summary of prior work: found X after 10 steps."}
        true    ->
          has_prefix = Enum.any?(msgs, fn m ->
            role    = m[:role]    || m["role"]    || ""
            content = m[:content] || m["content"] || ""
            role == "user" and String.starts_with?(content, "[Prior work summary]")
          end)
          send(test_pid, {:has_prefix, has_prefix})
          {:ok, {:tool_calls, [T.tool_call("task_signal", %{"status" => "TASK_DONE", "result" => "done"})]}}
      end
    end)

    Worker.run("task", ctx)
    assert_received {:has_prefix, true}
  end

  # ─── Master (Confidant) compaction ───────────────────────────────────────────

  test "master: compact! calls LLM and writes summary + cutoff index to sessions.context" do
    user_id = uid(); sid = uid()
    messages = T.conversation(47) ++ [T.user_msg("latest question")]
    assert length(messages) == 95
    insert_session(sid, user_id, messages)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, "Dense factual summary of the 95-message conversation."}
    end)

    session_data = %{"messages" => messages, "context" => nil}
    :ok = ContextEngine.compact!(sid, user_id, session_data)

    ctx = session_context(sid, user_id)
    assert ctx["summary"] == "Dense factual summary of the 95-message conversation."
    # keep_from = length(msgs) - @keep_recent(20) = 75 → summary_up_to_index = keep_from - 1 = 74
    assert ctx["summary_up_to_index"] == 74
  end
end
