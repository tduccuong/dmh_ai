# Multi-chain pivot integration test — the gap I called out for
# Phase C / Oracle. Drives `UserAgent.run_for_test/3` synchronously
# across TWO chains:
#
#   Chain 0:
#     - anchor = (1) ongoing task X
#     - user message is OFF-TOPIC to X
#     - Oracle stub → :unrelated
#     - Stub assistant LLM emits a non-exempt tool_call (web_search)
#         Police gate #8 rejects with `{:pivot_unrelated, …}`
#     - Stub assistant LLM retries with plain text push-back
#     - Chain ends, push-back text persisted
#     - PendingPivots stashed for this session
#     - Anchor still (1)
#
#   Chain 1 (user replied "yes pause"):
#     - Stub Oracle → :related
#     - Stub assistant LLM emits pause_task(1)
#     - pause_task succeeds → auto-create-task hook fires →
#       synthesised create_task with the off-topic msg as spec →
#       anchor flips to (2)
#     - Stub assistant LLM emits final text on the new anchor
#     - Chain ends; (2) is the live anchor; PendingPivots cleared;
#       cached Oracle verdict was forced to :related so any
#       subsequent in-chain tool would pass.
#
# All offline. The Swift classifier, the assistant model, the
# naming flow, and the profile extractor are all stubbed via the
# existing `LLM.call` / `LLM.stream` hooks.

defmodule Itgr.PivotTwoChains do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{AssistantCommand, PendingPivots, Tasks, UserAgent}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "pivot_#{user_id}@itgr.local", "user", now]
    )
  end

  defp seed_session(sid, user_id, msgs) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, user_id, "assistant", Jason.encode!(msgs), now, now]
    )
  end

  defp append_message(session_id, msg) do
    %{rows: [[json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    msgs = Jason.decode!(json || "[]")
    new = msgs ++ [msg]
    query!(Repo, "UPDATE sessions SET messages=? WHERE id=?", [Jason.encode!(new), session_id])
  end

  defp load_messages(session_id) do
    %{rows: [[json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    Jason.decode!(json || "[]")
  end

  defp tool_call(name, args, id \\ nil) do
    %{
      "id"       => id || uid(),
      "function" => %{"name" => name, "arguments" => args}
    }
  end

  # The stream stub gets called once per assistant turn. Each chain
  # drives its own scripted sequence; `:counters` is process-shared
  # by reference, so the increment is visible to the assistant LLM
  # call wherever it runs (the chain's own process). The script
  # itself is captured in the closure — closures (and their
  # bindings) cross process boundaries cleanly when the closure is
  # later invoked in another process.
  #
  # `verdict` is Swift's canned response for this install.
  # Captured in the closure → travels with it into the Swift Task
  # process. No Application env / process dict for cross-process
  # signalling — closure capture is idiomatic and avoids the
  # global-mutable-state anti-pattern the Application env hack
  # would be.
  defp install_stubs(scripts, verdict) when is_binary(verdict) do
    counter = :counters.new(1, [])

    T.stub_llm_stream(fn model_str, _messages, _reply_pid, _opts ->
      idx = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      case Enum.at(scripts, idx) do
        nil ->
          flunk("LLM.stream stub got call ##{idx + 1} model=#{model_str} but only #{length(scripts)} scripted responses")

        {:text, body} ->
          {:ok, body}

        {:tool_calls, calls} ->
          {:ok, {:tool_calls, calls}}
      end
    end)

    T.stub_llm_call(fn model_str, _messages, _opts ->
      cond do
        # Swift classifier (ministral). Verdict captured in this
        # closure — works cross-process because the closure carries
        # its bindings.
        String.contains?(model_str, "ministral") ->
          {:ok, verdict}

        true ->
          # Naming / profile-extractor / search-detection / any
          # other LLM.call usage in the chain — return a benign
          # text. The chain doesn't act on these for tool routing.
          {:ok, "ok"}
      end
    end)

    counter
  end

  setup do
    user_id = uid()
    sid = "pivot_two_" <> uid()
    seed_user(user_id)

    # Chain-start user message: off-topic ask while anchor is the HF
    # task. The text is what PendingPivots will stash + later use as
    # the auto-created task's spec.
    off_topic_msg = "why stock market soars today?"

    seed_session(sid, user_id, [
      %{"role" => "user", "content" => off_topic_msg, "ts" => System.os_time(:millisecond)}
    ])

    anchor_task_id =
      Tasks.insert(
        user_id: user_id,
        session_id: sid,
        task_title: "Search HF for sentiment models",
        task_spec:  "Search HuggingFace for sentiment analysis models"
      )

    Tasks.mark_ongoing(anchor_task_id)
    anchor_task_num = Tasks.get(anchor_task_id).task_num

    on_exit(fn ->
      PendingPivots.clear(sid)
      Process.delete(:dmh_ai_swift_verdict_cached)
    end)

    {:ok,
     user_id: user_id,
     sid: sid,
     anchor_task_id: anchor_task_id,
     anchor_task_num: anchor_task_num,
     off_topic_msg: off_topic_msg}
  end

  defp build_command(c, content) do
    %AssistantCommand{
      type:             :chat,
      content:          content,
      session_id:       c.sid,
      reply_pid:        self(),
      attachment_names: [],
      files:            [],
      metadata:         %{}
    }
  end

  defp drive_chain(c, command) do
    {:ok, _model, session_data} = UserAgent.load_session(c.sid, c.user_id)
    UserAgent.run_for_test(command, c.user_id, session_data)
  end

  # ─── Chain 0 — pivot detection + push-back ─────────────────────────────

  describe "chain 0: off-topic message during ongoing anchor → push-back" do
    test "Oracle :unrelated + non-exempt tool call → Police rejects → model pushes back as text", c do
      # Stream stub script: turn 0 emits web_search (gate-rejectable),
      # turn 1 emits the push-back text after seeing the rejection.
      script = [
        {:tool_calls, [tool_call("web_search", %{"query" => c.off_topic_msg})]},
        {:text, "I'm currently on task (#{c.anchor_task_num}). Want me to pause / cancel / stop it and handle this new request first, or finish (#{c.anchor_task_num}) before getting to it?"}
      ]

      install_stubs(script, "UNRELATED")

      command = build_command(c, c.off_topic_msg)
      assert {:chain_done, _watermark, _auto_pivot} = drive_chain(c, command)

      # PendingPivots stashed (set as side effect of the Swift Task).
      stash = PendingPivots.get(c.sid)
      assert is_map(stash), "expected a pending pivot; got nil"
      assert stash.user_msg == c.off_topic_msg
      assert stash.anchor_task_num == c.anchor_task_num

      # Final assistant text persisted.
      msgs = load_messages(c.sid)
      last = List.last(msgs)
      assert last["role"] == "assistant"
      assert last["content"] =~ "(#{c.anchor_task_num})"
      assert last["content"] =~ "pause"

      # Anchor still on (1) — model didn't actually run web_search,
      # didn't switch tasks.
      assert Tasks.get(c.anchor_task_id).task_status == "ongoing"
    end

    test "Oracle :unrelated + first call is an exempt verb → passes; tooling stays scoped to the rejection set", c do
      # The model could legitimately call `fetch_task` even on a
      # pivot turn (read-only). The exempt list lets it through.
      # We script: turn 0 emits fetch_task (allowed), then text
      # ending the chain.
      script = [
        {:tool_calls, [tool_call("fetch_task", %{"task_num" => c.anchor_task_num})]},
        {:text, "Anyway — switching topics to your stock-market question? I can pause this task first."}
      ]

      install_stubs(script, "UNRELATED")

      command = build_command(c, c.off_topic_msg)
      assert {:chain_done, _, _} = drive_chain(c, command)

      # The Oracle verdict still stashed the pending pivot (the
      # Task body fires the side effect regardless of which tools
      # the model ended up calling).
      stash = PendingPivots.get(c.sid)
      assert is_map(stash)
    end
  end

  # ─── Chain 1 — user confirms pause → auto-create-task → continues ──────

  describe "chain 1: user confirms pause → auto-create + anchor flip" do
    test "pause_task success triggers auto-create-task; new anchor emerges", c do
      # First, prime PendingPivots as if chain 0 had run.
      :ok = PendingPivots.put(c.sid, %{
        user_msg:        c.off_topic_msg,
        anchor_task_num: c.anchor_task_num
      })

      # Append the user reply to session.messages so chain 1 sees it.
      append_message(c.sid, %{
        "role" => "user", "content" => "yes pause",
        "ts" => System.os_time(:millisecond)
      })

      # Stream stub script across TWO chains under the close-verb
      # chain-termination rule (Y rule):
      #
      #   Chain 1 (driven by "yes pause"):
      #     turn 0 → pause_task → close-verb success → chain ENDS.
      #             auto-pivot synthesises create_task → :auto_resume_assistant
      #             signal sent (a no-op in this test process; we drive the
      #             follow-up chain manually below).
      #
      #   Chain 2 (the auto-resumed chain — driven explicitly here with an
      #   empty-content command, mirroring `handle_info({:auto_resume_assistant, _})`):
      #     turn 0 → final text on the new task. No tool_calls → chain ends naturally.
      script = [
        {:tool_calls, [tool_call("pause_task", %{"task_num" => c.anchor_task_num})]},
        {:text, "Paused (#{c.anchor_task_num}). Now answering your stock-market question (placeholder for the test)."}
      ]

      install_stubs(script, "RELATED")

      command = build_command(c, "yes pause")
      assert {:chain_done, _, _} = drive_chain(c, command)

      # Original anchor task is now PAUSED.
      assert Tasks.get(c.anchor_task_id).task_status == "paused"

      # A NEW task was created for the off-topic message via the
      # auto-create-task hook (synthesised inside the pause chain
      # before it terminated under the Y rule).
      active_in_session = Tasks.active_for_session(c.sid)
      new_tasks =
        active_in_session
        |> Enum.reject(&(&1.task_num == c.anchor_task_num))

      assert length(new_tasks) == 1, "expected 1 newly-created task, got #{length(new_tasks)}"
      [new_task] = new_tasks
      assert new_task.task_spec == c.off_topic_msg
      assert new_task.task_status == "ongoing"
      assert new_task.task_type == "one_off"

      # PendingPivots cleared.
      assert PendingPivots.get(c.sid) == nil

      # Drive the auto-resumed chain. In production the
      # `:auto_resume_assistant` message hits `UserAgent.handle_info/2`,
      # which builds a synthetic AssistantCommand with empty content
      # and runs it. We replicate that here by issuing an empty-content
      # command — the streaming stub then consumes the second script
      # entry (the final text) and the chain ends naturally on the
      # text-only turn.
      assert {:chain_done, _, _} = drive_chain(c, build_command(c, ""))

      # Final assistant text persisted by the auto-resumed chain.
      msgs = load_messages(c.sid)
      last = List.last(msgs)
      assert last["role"] == "assistant"
      assert is_binary(last["content"])
    end

    test "auto-create does NOT fire when pause_task succeeds without a pending pivot", c do
      # No PendingPivots stash this time.
      assert PendingPivots.get(c.sid) == nil

      append_message(c.sid, %{
        "role" => "user", "content" => "actually pause this for now",
        "ts" => System.os_time(:millisecond)
      })

      script = [
        {:tool_calls, [tool_call("pause_task", %{"task_num" => c.anchor_task_num})]},
        {:text, "Paused (#{c.anchor_task_num})."}
      ]

      install_stubs(script, "RELATED")

      command = build_command(c, "actually pause this for now")
      assert {:chain_done, _, _} = drive_chain(c, command)

      # Anchor task paused.
      assert Tasks.get(c.anchor_task_id).task_status == "paused"

      # No new task was created — auto-create only fires when a
      # pending pivot exists.
      active = Tasks.active_for_session(c.sid)
      assert active == [] or Enum.all?(active, &(&1.task_num == c.anchor_task_num))
    end
  end

  # ─── Full two-chain flow in one test (regression check) ────────────────

  describe "end-to-end pivot recovery across both chains" do
    test "chain 0 push-back + chain 1 confirm + auto-create + final text", c do
      # ── Chain 0 ────────────────────────────────────────────────
      script_chain0 = [
        {:tool_calls, [tool_call("web_search", %{"query" => c.off_topic_msg})]},
        {:text, "I'm currently on task (#{c.anchor_task_num}). Pause and switch?"}
      ]

      install_stubs(script_chain0, "UNRELATED")

      command0 = build_command(c, c.off_topic_msg)
      assert {:chain_done, _, _} = drive_chain(c, command0)

      assert PendingPivots.get(c.sid) != nil
      assert Tasks.get(c.anchor_task_id).task_status == "ongoing"

      # ── Chain 1 ────────────────────────────────────────────────
      append_message(c.sid, %{
        "role" => "user", "content" => "yes pause",
        "ts" => System.os_time(:millisecond)
      })

      # Reset the per-chain Oracle cache so chain 1 awaits a fresh verdict.
      Process.delete(:dmh_ai_swift_verdict_cached)

      script_chain1 = [
        {:tool_calls, [tool_call("pause_task", %{"task_num" => c.anchor_task_num})]},
        {:text, "Paused. Now on your new question."}
      ]

      install_stubs(script_chain1, "RELATED")

      command1 = build_command(c, "yes pause")
      result = drive_chain(c, command1)

      # The auto_pivot signal MUST carry the freshly-created task's id —
      # the chain-complete hook in UserAgent depends on it to route
      # through the silent-pickup path. Past regression: `Map.get(ctx,
      # :anchor_task_id)` used in the chain-end branch returned nil
      # (because :anchor_task_id was never a stored ctx field — the
      # codebase uses a derived getter instead), the hook's guard
      # `when is_binary(task_id)` failed, the case fell through to a
      # defensive catch-all and routed via normal user-msg auto-resume.
      # The replayed trailing user message ("yes pause") was then
      # interpreted as a fresh ask, making the model close-verb the
      # auto-pivoted task. Pin the shape so this can never silently
      # break again.
      assert {:chain_done, _watermark, {:auto_pivot, new_task_id}} = result
      assert is_binary(new_task_id)

      # Original anchor paused, new anchor ongoing, pending pivot cleared.
      assert Tasks.get(c.anchor_task_id).task_status == "paused"
      assert PendingPivots.get(c.sid) == nil

      new_tasks =
        Tasks.active_for_session(c.sid)
        |> Enum.reject(&(&1.task_num == c.anchor_task_num))

      assert length(new_tasks) == 1
      [new_task] = new_tasks
      assert new_task.task_spec == c.off_topic_msg
      assert new_task.task_status == "ongoing"
      # The id in the auto_pivot signal MUST point at the freshly-
      # created task — not the prior anchor, not a stale resolve.
      assert new_task_id == new_task.task_id
    end
  end
end
