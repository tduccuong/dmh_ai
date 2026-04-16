# Integration tests: context compaction — worker rolling-summary and master compact!.
# Run with: MIX_ENV=test mix test test/itgr_compaction.exs

defmodule Itgr.Compaction do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{Worker, WorkerState, ContextEngine}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp make_ctx(overrides \\ []) do
    %{
      user_id:     Keyword.get(overrides, :user_id,     uid()),
      session_id:  Keyword.get(overrides, :session_id,  uid()),
      worker_id:   Keyword.get(overrides, :worker_id,   uid()),
      agent_pid:   Keyword.get(overrides, :agent_pid,   self()),
      description: "compaction test task"
    }
  end

  defp db_rolling_summary(worker_id) do
    r = query!(Dmhai.Repo, "SELECT rolling_summary FROM worker_state WHERE worker_id=?", [worker_id])
    case r.rows do
      [[s]] -> s
      []    -> nil
    end
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
  # Worker.run starts with [system, user] = 2 messages.
  # Each tool-call iteration appends 2 messages (assistant-with-calls + tool-result).
  # After 10 iterations: 2 + 20 = 22 > 20 → compaction fires at the START of iteration 11.
  #
  # LLM call sequence through stub_llm_call:
  #   calls 0–9  → tool_calls       (iterations 1–10, messages grow 2 → 22)
  #   call  10   → "Compacted."     (compaction: LLM.call inside update_rolling_summary)
  #   call  11   → tool_calls       (one post-compaction iteration so checkpoint persists
  #                                  the new rolling_summary to DB; messages 15 → 17)
  #   call  12   → "All done."      (final text response, loop exits)

  test "worker: 10 tool-call iterations trigger compaction; rolling_summary persisted after next checkpoint" do
    ctx = make_ctx()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      cond do
        n < 10  -> {:ok, {:tool_calls, [T.tool_call("noop", %{})]}}
        n == 10 -> {:ok, "Compacted: completed 10 steps, output was X."}
        n == 11 -> {:ok, {:tool_calls, [T.tool_call("noop", %{})]}}
        true    -> {:ok, "All done."}
      end
    end)

    assert {:ok, "All done."} == Worker.run("do the thing", ctx)

    summary = db_rolling_summary(ctx.worker_id)
    assert summary != nil and summary != ""
    assert String.contains?(summary, "Compacted:")
  end

  test "worker: after compaction, rolling_summary is injected as a prefix into the subsequent LLM call" do
    # Same 10-iteration build-up; call 10 is the compaction LLM call.
    # Call 11 is the first main worker LLM call after compaction — verify the
    # rolling_summary prefix is present in the messages it receives.
    ctx = make_ctx()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    T.stub_llm_call(fn _model, msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      cond do
        n < 10  -> {:ok, {:tool_calls, [T.tool_call("noop", %{})]}}
        n == 10 -> {:ok, "Summary of prior work: found X after 10 steps."}
        true    ->
          has_prefix = Enum.any?(msgs, fn m ->
            role    = m[:role]    || m["role"]    || ""
            content = m[:content] || m["content"] || ""
            role == "user" and String.starts_with?(content, "[Prior work summary]")
          end)
          send(test_pid, {:has_prefix, has_prefix})
          {:ok, "Done."}
      end
    end)

    Worker.run("task", ctx)
    assert_received {:has_prefix, true}
  end

  test "worker: second compaction receives the existing rolling_summary in its instruction and updates it" do
    # Start from a checkpoint that represents the state AFTER a first compaction:
    # 15 messages (system + 7 assistant/tool pairs) and rolling_summary already set.
    # Three more tool-call iterations push the count from 15 to 21 (> 20) → second
    # compaction fires. The compaction instruction must reference the existing summary.
    user_id = uid(); wid = uid(); sid = uid()

    prior_msgs =
      [%{"role" => "system", "content" => "worker system prompt"}] ++
      Enum.flat_map(1..7, fn i ->
        tc_id = "tc#{i}"
        [
          %{"role" => "assistant", "content" => "",
            "tool_calls" => [%{"id" => tc_id, "function" => %{"name" => "bash", "arguments" => %{}}}]},
          %{"role" => "tool", "content" => "result #{i}", "tool_call_id" => tc_id}
        ]
      end)

    # 1 system + 7*2 = 15 messages total.
    assert length(prior_msgs) == 15

    checkpoint = %{
      worker_id:       wid,
      session_id:      sid,
      user_id:         user_id,
      task:            "continue the task",
      messages:        prior_msgs,
      rolling_summary: "Prior summary: completed steps 1 through 7.",
      iter:            7,
      periodic:        false
    }

    WorkerState.upsert(wid, sid, user_id, "continue the task", prior_msgs, 7, false,
                       "Prior summary: completed steps 1 through 7.", "recovering")

    # LLM call sequence:
    #   0–2   → tool_calls  (msgs 15 → 21; compaction threshold crossed at end of call 2)
    #   3     → compaction call (second round; must reference "Prior summary:")
    #   4     → tool_calls  (one post-compaction iteration to checkpoint updated summary)
    #   5+    → "Done."
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    T.stub_llm_call(fn _model, msgs, _opts ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      cond do
        n < 3  -> {:ok, {:tool_calls, [T.tool_call("noop", %{})]}}
        n == 3 ->
          instruction = msgs |> List.last() |> then(&(&1[:content] || &1["content"] || ""))
          send(test_pid, {:saw_prior_in_instruction, String.contains?(instruction, "Prior summary:")})
          {:ok, "Updated summary: steps 1-7 done, plus 3 new steps."}
        n == 4 -> {:ok, {:tool_calls, [T.tool_call("noop", %{})]}}
        true   -> {:ok, "Done."}
      end
    end)

    Worker.run_from_checkpoint(checkpoint, self())

    assert_received {:saw_prior_in_instruction, true}

    summary = db_rolling_summary(wid)
    assert summary == "Updated summary: steps 1-7 done, plus 3 new steps."
  end

  # ─── Master (Confidant) compaction ───────────────────────────────────────────
  #
  # Master compaction threshold: recent_turns > 90 (default).
  # T.conversation(47) produces 94 messages (47 user+assistant pairs).
  # Adding 1 user message = 95 total > 90 → should_compact? is true.
  #
  # compact! keeps @keep_recent=20 most-recent messages untouched and summarises
  # the rest (msgs[0..74]) via a single LLM.call, then writes to sessions.context.

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
    # cutoff is the index of the last message that was summarised;
    # it must be within [0, length-@keep_recent-1]
    assert is_integer(ctx["summary_up_to_index"])
    assert ctx["summary_up_to_index"] > 0
    assert ctx["summary_up_to_index"] < length(messages) - 1
  end

  test "master: build_messages injects the compaction summary prefix after compact!" do
    user_id = uid(); sid = uid()
    messages = T.conversation(47) ++ [T.user_msg("latest question")]
    insert_session(sid, user_id, messages)

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, "A dense summary of the long conversation."}
    end)

    session_data = %{"messages" => messages, "context" => nil}
    :ok = ContextEngine.compact!(sid, user_id, session_data)

    ctx = session_context(sid, user_id)
    updated_session_data = %{"messages" => messages, "context" => ctx, "mode" => "confidant"}

    built_msgs = ContextEngine.build_messages(updated_session_data)

    summary_msg = Enum.find(built_msgs, fn m ->
      m.role == "user" and String.starts_with?(m.content, "[Summary of our conversation so far]")
    end)

    assert summary_msg != nil
    assert String.contains?(summary_msg.content, "A dense summary of the long conversation.")
  end
end
