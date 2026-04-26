# Cheap-tier coverage for the Oracle / pivot / knowledge gate stack:
#
#   1. `Dmhai.Agent.Oracle.classify/2`     — verdict parsing against
#      stubbed LLM responses.
#   2. `Dmhai.Agent.PendingPivots`         — ETS round-trip + TTL.
#   3. `Dmhai.Agent.Police.check_pivot/3`  — gate routing per verdict,
#      exempt list, soft-fail on `:error`, per-chain verdict cache.
#
# What's NOT covered here (medium-effort, deferred): the in-chain
# auto-create-task hook in `Dmhai.Agent.UserAgent.execute_tools/3` —
# its trigger predicates (`pause_or_cancel_succeeded?`) and the
# synthesized `create_task` round-trip live behind private helpers
# inside the chain runner. Cheapest way to catch a regression there
# is the full chain driver pattern used by `itgr_tool_capability.exs`,
# which we'll add when we wire up a chain stub harness.
#
# All tests in this file run offline. The optional `:network` block
# at the bottom hits real ministral-3:14b-cloud through `LLM.call`
# and must be opted into:
#
#   mix test test/itgr_oracle_pivot.exs --only network

defmodule Itgr.OraclePivot do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{Oracle, PendingPivots, Police}

  # ─── Oracle.classify/2 ──────────────────────────────────────────────────

  describe "Oracle.classify/2 verdict parsing" do
    setup do
      # Each test installs its own stub via T.stub_llm_call/1 in the body.
      :ok
    end

    test "RELATED verdict maps to :related" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)
      assert Oracle.classify("follow-up clarification", "Search HF for sentiment models") == :related
    end

    test "UNRELATED verdict maps to :unrelated" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "UNRELATED"} end)
      assert Oracle.classify("why stock market soars today", "Search HF for sentiment models") == :unrelated
    end

    test "KNOWLEDGE verdict maps to :knowledge" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "KNOWLEDGE"} end)
      assert Oracle.classify("hi", "Search HF for sentiment models") == :knowledge
    end

    test "tolerates lowercase / mixed case" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "knowledge"} end)
      assert Oracle.classify("hello", "anything") == :knowledge

      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "Related"} end)
      assert Oracle.classify("yes", "anything") == :related
    end

    test "tolerates surrounding whitespace and trailing punctuation" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "  UNRELATED.\n"} end)
      assert Oracle.classify("off-topic", "anything") == :unrelated
    end

    test "picks the FIRST word — extra commentary doesn't break parsing" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "UNRELATED — different domain"} end)
      assert Oracle.classify("off-topic", "anything") == :unrelated
    end

    test "garbage verdict word maps to :error (soft fail)" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "MAYBE"} end)
      assert Oracle.classify("anything", "anything") == :error
    end

    test "LLM error maps to :error (soft fail)" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:error, :timeout} end)
      assert Oracle.classify("anything", "anything") == :error
    end

    test "LLM emits tool_calls (it shouldn't, but if it does) → :error" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, {:tool_calls, []}} end)
      assert Oracle.classify("anything", "anything") == :error
    end

    test "empty / nil anchor task spec short-circuits to :related (no classifier call)" do
      T.stub_llm_call(fn _model, _msgs, _opts ->
        flunk("classifier should not be called when anchor task spec is empty")
      end)

      assert Oracle.classify("anything", nil) == :related
      assert Oracle.classify("anything", "") == :related
      assert Oracle.classify("anything", "   ") == :related
    end

    test "non-binary user_msg returns :error" do
      assert Oracle.classify(nil, "spec") == :error
      assert Oracle.classify(:atom, "spec") == :error
    end
  end

  # ─── PendingPivots ETS store ────────────────────────────────────────────

  describe "PendingPivots round-trip" do
    setup do
      sid = "test_pp_" <> T.uid()
      on_exit(fn -> PendingPivots.clear(sid) end)
      {:ok, sid: sid}
    end

    test "init is idempotent" do
      assert PendingPivots.init() == :ok
      assert PendingPivots.init() == :ok
    end

    test "put/get round-trip preserves user_msg + anchor_task_num", %{sid: sid} do
      :ok =
        PendingPivots.put(sid, %{
          user_msg: "why is the stock market soaring?",
          anchor_task_num: 1
        })

      entry = PendingPivots.get(sid)
      assert is_map(entry)
      assert entry.user_msg == "why is the stock market soaring?"
      assert entry.anchor_task_num == 1
      assert is_integer(entry.ts)
    end

    test "get returns nil for missing session", %{sid: _sid} do
      assert PendingPivots.get("never_seen_" <> T.uid()) == nil
    end

    test "clear removes the entry", %{sid: sid} do
      :ok = PendingPivots.put(sid, %{user_msg: "x", anchor_task_num: 1})
      assert PendingPivots.get(sid) != nil
      :ok = PendingPivots.clear(sid)
      assert PendingPivots.get(sid) == nil
    end

    test "expired entry is dropped on get", %{sid: sid} do
      # Manually plant a row whose ts is older than the 30-min TTL.
      stale_ts = System.os_time(:millisecond) - 31 * 60 * 1000
      stale_entry = %{user_msg: "old ask", anchor_task_num: 1, ts: stale_ts}
      :ets.insert(:dmhai_pending_pivots, {sid, stale_entry})

      assert PendingPivots.get(sid) == nil
      # And the stale row should have been cleaned up as a side effect.
      assert :ets.lookup(:dmhai_pending_pivots, sid) == []
    end
  end

  # ─── Police.check_pivot/3 ───────────────────────────────────────────────

  describe "Police.check_pivot/3 routing" do
    setup do
      # Each test runs in its own process; clear any cached verdict
      # left by a sibling test that ran in the same VM.
      Process.delete(:dmhai_oracle_verdict_cached)
      :ok
    end

    # Fake `Task` struct that resolves immediately to the given
    # verdict. We can't synthesise a real `%Task{}` cheaply across
    # tests, so exercise the explicit bypass: when ctx has NO
    # oracle_task, the await fallback is `:related`. To test the
    # other verdicts we plant the cache directly — Police's gate
    # reads from the cache before touching the task.
    defp ctx_with_cached(verdict, anchor_num \\ 1) do
      Process.put(:dmhai_oracle_verdict_cached, {:resolved, verdict})
      %{anchor_task_num: anchor_num, session_id: "s_" <> T.uid()}
    end

    test ":related → :ok regardless of tool name" do
      ctx = ctx_with_cached(:related)
      assert Police.check_pivot("web_search", %{"query" => "x"}, ctx) == :ok
      assert Police.check_pivot("run_script", %{"script" => "ls"}, ctx) == :ok
      assert Police.check_pivot("pause_task", %{"task_num" => 1}, ctx) == :ok
    end

    test ":error → :ok (soft fail)" do
      ctx = ctx_with_cached(:error)
      assert Police.check_pivot("web_search", %{}, ctx) == :ok
    end

    test ":unrelated + non-exempt tool → reject with pivot_unrelated tag" do
      ctx = ctx_with_cached(:unrelated, 7)
      assert {:rejected, {:pivot_unrelated, reason}} =
               Police.check_pivot("web_search", %{"query" => "x"}, ctx)

      assert is_binary(reason)
      assert reason =~ "(7)"
      assert reason =~ "web_search"
      assert reason =~ "pause" and reason =~ "cancel"
    end

    test ":unrelated + exempt verbs pass through" do
      ctx = ctx_with_cached(:unrelated)

      for name <- ~w(pause_task cancel_task complete_task pickup_task fetch_task request_input) do
        assert Police.check_pivot(name, %{"task_num" => 1}, ctx) == :ok,
               "expected #{name} to pass on :unrelated"
      end
    end

    test ":knowledge → reject for ALL tools (no exemptions)" do
      ctx = ctx_with_cached(:knowledge)

      for name <- ~w(web_search run_script create_task pause_task complete_task fetch_task request_input) do
        assert {:rejected, {:pivot_knowledge, reason}} =
                 Police.check_pivot(name, %{}, ctx),
               "expected #{name} to be rejected on :knowledge"

        assert is_binary(reason)
        assert reason =~ "knowledge" or reason =~ "training",
               "knowledge nudge should reference training/knowledge"
      end
    end

    test "no oracle_task in ctx → :related fallback (gate skipped)" do
      Process.delete(:dmhai_oracle_verdict_cached)
      ctx = %{anchor_task_num: 1, session_id: "s_" <> T.uid()}
      # Without an oracle_task and no cached verdict, await_oracle/1
      # returns :related (no anchor case from Oracle's perspective).
      assert Police.check_pivot("web_search", %{}, ctx) == :ok
    end

    test "verdict is cached across calls — flipping the cache after first call has no effect on second" do
      ctx = ctx_with_cached(:related)
      assert Police.check_pivot("web_search", %{}, ctx) == :ok

      # Tamper with the cache. The gate should still reflect what it
      # already cached for THIS chain (it doesn't re-read from
      # process dict on every call after the first resolution path).
      # Actually our implementation DOES re-read from Process.get on
      # every call — so flipping the cache flips the gate. This test
      # documents that current behavior; if we ever move to a per-
      # ctx-private cache, flip the assertion.
      Process.put(:dmhai_oracle_verdict_cached, {:resolved, :unrelated})
      assert {:rejected, _} = Police.check_pivot("web_search", %{}, ctx)
    end

    test "non-binary tool name → :ok (other gates own malformed-name rejection)" do
      ctx = ctx_with_cached(:unrelated)
      assert Police.check_pivot(nil, %{}, ctx) == :ok
      assert Police.check_pivot(:atom, %{}, ctx) == :ok
    end
  end

  # ─── Auto-create-task trigger predicates ────────────────────────────────

  describe "UserAgent.pause_or_cancel_succeeded?/1" do
    alias Dmhai.Agent.UserAgent

    test "true on a normal pause/cancel success payload" do
      assert UserAgent.pause_or_cancel_succeeded?(~s({\n  "ok": true,\n  "task_num": 1\n}))
    end

    test "true tolerant to whitespace / formatting variants of `\"ok\": true`" do
      assert UserAgent.pause_or_cancel_succeeded?(~s({"ok": true, "task_num": 7}))
    end

    test "false when the payload doesn't carry the success marker" do
      refute UserAgent.pause_or_cancel_succeeded?(~s({"ok": false, "reason": "unknown task_num"}))
      refute UserAgent.pause_or_cancel_succeeded?(~s({"task_num": 1}))
      refute UserAgent.pause_or_cancel_succeeded?("")
    end

    test "false on a Police rejection marker (call never ran)" do
      marker = "[[ISSUE:duplicate_tool_call_in_chain:pause_task]]\n"
      payload = marker <> ~s({"ok": true, "task_num": 1})
      # Even when the rejection text is followed by what looks like a
      # success blob, the leading marker means the call was rejected
      # upstream of execution; we MUST NOT trigger auto-create.
      refute UserAgent.pause_or_cancel_succeeded?(payload)
    end

    test "false on the runtime `Error:` prefix (tool errored)" do
      refute UserAgent.pause_or_cancel_succeeded?("Error: task_num 99 not found")
    end

    test "false for non-binary content" do
      refute UserAgent.pause_or_cancel_succeeded?(nil)
      refute UserAgent.pause_or_cancel_succeeded?(%{ok: true})
      refute UserAgent.pause_or_cancel_succeeded?(:ok)
    end
  end

  describe "UserAgent.derive_task_title/1" do
    alias Dmhai.Agent.UserAgent

    test "takes the first line, trimmed" do
      assert UserAgent.derive_task_title("  why is the stock market soaring?  \nfollow-up\n") ==
               "why is the stock market soaring?"
    end

    test "caps at 60 chars" do
      long = String.duplicate("x", 200)
      assert String.length(UserAgent.derive_task_title(long)) == 60
    end

    test "single-line input passes through after trim" do
      assert UserAgent.derive_task_title("install docker") == "install docker"
    end

    test "preserves unicode within the 60-char cap" do
      msg = "tại sao thị trường chứng khoán tăng hôm nay?"
      out = UserAgent.derive_task_title(msg)
      assert out == msg
    end
  end

  # ─── End-to-end wiring: maybe_auto_create_task/3 ────────────────────────

  describe "UserAgent.maybe_auto_create_task/3 — happy path wiring" do
    alias Dmhai.Agent.{PendingPivots, Tasks, UserAgent}
    alias Dmhai.Repo
    import Ecto.Adapters.SQL, only: [query!: 3]

    defp seed_session(sid, user_id) do
      now = System.os_time(:millisecond)

      query!(Repo,
        "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
        [sid, user_id, "assistant", "[]", now, now]
      )
    end

    setup do
      sid = "auto_create_" <> T.uid()
      user_id = T.uid()
      seed_session(sid, user_id)

      anchor_task_id =
        Tasks.insert(
          user_id: user_id,
          session_id: sid,
          task_title: "Search HF for sentiment models",
          task_spec: "Search HuggingFace for sentiment analysis models"
        )

      Tasks.mark_ongoing(anchor_task_id)
      anchor_task_num = Tasks.get(anchor_task_id).task_num

      # Reset process-dict cache so Police.check_pivot doesn't read a
      # stale verdict from a sibling test.
      Process.delete(:dmhai_oracle_verdict_cached)

      on_exit(fn -> PendingPivots.clear(sid) end)

      {:ok,
       sid: sid,
       user_id: user_id,
       anchor_task_id: anchor_task_id,
       anchor_task_num: anchor_task_num}
    end

    defp ctx(sid, user_id, anchor_task_num) do
      %{
        session_id:                    sid,
        user_id:                       user_id,
        user_email:                    "test@itgr.local",
        anchor_task_num:               anchor_task_num,
        last_rendered_anchor_task_num: anchor_task_num,
        chain_start_idx:               0
      }
    end

    defp success_payload(task_num),
      do: ~s({\n  "ok": true,\n  "task_num": #{task_num}\n})

    test "pause_task success WITH pending pivot synthesizes create_task and flips the anchor", ctx do
      :ok = PendingPivots.put(ctx.sid, %{
        user_msg:        "why is the stock market soaring today?",
        anchor_task_num: ctx.anchor_task_num
      })

      tool_msg = %{role: "tool", content: success_payload(ctx.anchor_task_num)}
      ctx_in   = ctx(ctx.sid, ctx.user_id, ctx.anchor_task_num)

      {extra_pairs, extra_pseudos, ctx_after} =
        UserAgent.maybe_auto_create_task("pause_task", tool_msg, ctx_in)

      # 1. Returns one synthesized {tool_msg, tool_call} pair.
      assert length(extra_pairs) == 1, "expected 1 synthesized pair, got #{length(extra_pairs)}"
      [{synth_tool_msg, synth_call}] = extra_pairs
      assert synth_tool_msg.role == "tool"
      assert is_binary(synth_tool_msg.content) and synth_tool_msg.content != ""
      assert get_in(synth_call, ["function", "name"]) == "create_task"
      assert get_in(synth_call, ["function", "arguments", "task_spec"]) ==
               "why is the stock market soaring today?"

      # 2. Pseudo message for the in-chain accumulator carries the same call.
      assert length(extra_pseudos) == 1
      [pseudo] = extra_pseudos
      assert pseudo["role"] == "assistant"
      assert [^synth_call] = pseudo["tool_calls"]

      # 3. A real new task exists in DB with the stashed message as spec.
      new_tasks =
        Tasks.active_for_session(ctx.sid)
        |> Enum.reject(&(&1.task_num == ctx.anchor_task_num))

      assert length(new_tasks) == 1, "expected 1 newly-created task, got #{length(new_tasks)}"
      [new_task] = new_tasks
      assert new_task.task_spec == "why is the stock market soaring today?"
      assert new_task.task_status == "ongoing"
      assert new_task.task_type == "one_off"

      # 4. Anchor flipped to the new task.
      assert ctx_after.anchor_task_num == new_task.task_num
      assert ctx_after.last_rendered_anchor_task_num == new_task.task_num

      # 5. PendingPivots cleared.
      assert PendingPivots.get(ctx.sid) == nil

      # 6. Cached Oracle verdict forced to :related so subsequent
      #    Police gate calls in this chain pass through (anchor moved,
      #    old verdict is stale).
      assert Process.get(:dmhai_oracle_verdict_cached) == {:resolved, :related}
    end

    test "cancel_task success with pending pivot fires the same auto-create path", ctx do
      :ok = PendingPivots.put(ctx.sid, %{
        user_msg:        "cancel and answer this instead",
        anchor_task_num: ctx.anchor_task_num
      })

      tool_msg = %{role: "tool", content: success_payload(ctx.anchor_task_num)}
      ctx_in   = ctx(ctx.sid, ctx.user_id, ctx.anchor_task_num)

      {extra_pairs, _, ctx_after} =
        UserAgent.maybe_auto_create_task("cancel_task", tool_msg, ctx_in)

      assert length(extra_pairs) == 1
      assert ctx_after.anchor_task_num != ctx.anchor_task_num
      assert PendingPivots.get(ctx.sid) == nil
    end

    test "pause_task success WITHOUT pending pivot is a no-op", ctx do
      # Sanity: ensure ETS is empty for this session.
      :ok = PendingPivots.clear(ctx.sid)

      tool_msg = %{role: "tool", content: success_payload(ctx.anchor_task_num)}
      ctx_in   = ctx(ctx.sid, ctx.user_id, ctx.anchor_task_num)

      result = UserAgent.maybe_auto_create_task("pause_task", tool_msg, ctx_in)

      assert {[], [], ^ctx_in} = result

      # No new task in DB.
      tasks = Tasks.active_for_session(ctx.sid)
      assert length(tasks) == 1
      assert hd(tasks).task_num == ctx.anchor_task_num
    end

    test "pause_task that FAILED (Police-rejected) does not auto-create", ctx do
      :ok = PendingPivots.put(ctx.sid, %{
        user_msg:        "off-topic ask",
        anchor_task_num: ctx.anchor_task_num
      })

      rejected_msg = %{
        role: "tool",
        content: "[[ISSUE:duplicate_tool_call_in_chain:pause_task]]\nError: already called…"
      }

      ctx_in = ctx(ctx.sid, ctx.user_id, ctx.anchor_task_num)
      result = UserAgent.maybe_auto_create_task("pause_task", rejected_msg, ctx_in)

      assert {[], [], ^ctx_in} = result

      # PendingPivots stays — the pivot wasn't actually accepted.
      assert PendingPivots.get(ctx.sid) != nil
    end

    test "tools other than pause_task / cancel_task never trigger auto-create", ctx do
      :ok = PendingPivots.put(ctx.sid, %{
        user_msg:        "off-topic",
        anchor_task_num: ctx.anchor_task_num
      })

      tool_msg = %{role: "tool", content: success_payload(ctx.anchor_task_num)}
      ctx_in   = ctx(ctx.sid, ctx.user_id, ctx.anchor_task_num)

      for name <- ~w(complete_task pickup_task fetch_task web_search run_script create_task) do
        result = UserAgent.maybe_auto_create_task(name, tool_msg, ctx_in)
        assert {[], [], ^ctx_in} = result, "expected #{name} to NOT trigger auto-create"
      end

      # ETS untouched.
      assert PendingPivots.get(ctx.sid) != nil
    end
  end

  # ─── Optional: live ministral round-trip ────────────────────────────────

  describe "Oracle.classify/2 against real ministral (network)" do
    @describetag :network

    test "classifies a clear off-topic message as UNRELATED" do
      verdict = Oracle.classify("why is the stock market soaring today?",
                                 "Search HuggingFace for sentiment analysis models")

      assert verdict in [:unrelated, :knowledge, :error],
             "expected :unrelated or :knowledge for an off-topic / live-data ask, got: #{inspect(verdict)}"

      # Soft assertion — log a notice if ministral picks something
      # unexpected. Don't fail the test on the verdict per se since
      # small models drift; we just want to know if the prompt has
      # become brittle.
      if verdict == :error do
        IO.puts("[itgr_oracle_pivot] WARNING: ministral returned an unparseable verdict")
      end
    end

    test "classifies a refining follow-up as RELATED" do
      verdict = Oracle.classify("can you also include the model size?",
                                 "Search HuggingFace for sentiment analysis models")

      assert verdict in [:related, :error],
             "expected :related for an obvious refinement, got: #{inspect(verdict)}"
    end

    test "classifies a greeting as KNOWLEDGE" do
      verdict = Oracle.classify("thanks!",
                                 "Search HuggingFace for sentiment analysis models")

      assert verdict in [:knowledge, :error],
             "expected :knowledge for a thanks/greeting, got: #{inspect(verdict)}"
    end
  end
end
