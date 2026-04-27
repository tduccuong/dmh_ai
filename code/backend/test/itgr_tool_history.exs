# Integration tests: ToolHistory save / load / inject semantics.
# Run with: MIX_ENV=test mix test test/itgr_tool_history.exs
#
# Tool-result retention is a critical runtime op — it's what lets the
# Assistant answer immediate follow-ups without re-running extract_content.
# Stub messages are shaped like real production data (OpenAI-style
# tool_calls, tool_call_id, UTF-8 Vietnamese content in extract results).

defmodule Itgr.ToolHistory do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.ToolHistory
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp insert_session(sid, uid_) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, uid_, "assistant", "[]", now, now])
  end

  # Realistic tool-round messages: one assistant with tool_calls, one tool
  # result. Content length approximates real-world OCR/web_search output.
  defp stub_extract_messages(task_id, path, content) do
    [
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{
          "id" => "call_" <> T.uid(),
          "function" => %{
            "name" => "extract_content",
            "arguments" => %{"path" => path}
          }
        }]
      },
      %{
        role: "tool",
        content: content,
        tool_call_id: "call_result"
      },
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{
          "id" => "call_" <> T.uid(),
          "function" => %{
            "name" => "complete_task",
            "arguments" => %{"task_id" => task_id, "task_result" => "done"}
          }
        }]
      },
      %{role: "tool", content: "{\"ok\":true}", tool_call_id: "call_result2"}
    ]
  end

  # ─── save + load ─────────────────────────────────────────────────────────

  test "save_turn + load: round-trips messages with expected structure" do
    sid = uid(); uid_ = uid()
    insert_session(sid, uid_)

    msgs = stub_extract_messages("t_" <> uid(), "workspace/foo.pdf", "extracted content")
    :ok = ToolHistory.save_turn(sid, uid_, 1_776_946_063_050, msgs)

    [entry] = ToolHistory.load(sid)
    assert entry["assistant_ts"] == 1_776_946_063_050
    assert length(entry["messages"]) == 4
  end

  test "save_turn is a no-op for empty message list (pure-chat turn)" do
    sid = uid(); uid_ = uid()
    insert_session(sid, uid_)

    :ok = ToolHistory.save_turn(sid, uid_, 1_776_946_063_050, [])
    assert ToolHistory.load(sid) == []
  end

  test "load returns [] for sessions with no tool_history column value" do
    sid = uid(); uid_ = uid()
    insert_session(sid, uid_)
    assert ToolHistory.load(sid) == []
  end

  test "load returns [] on malformed JSON in the column" do
    sid = uid(); uid_ = uid()
    insert_session(sid, uid_)
    # Force-write garbage directly to the column.
    query!(Repo, "UPDATE sessions SET tool_history=? WHERE id=?", ["not json {{{", sid])
    assert ToolHistory.load(sid) == []
  end

  # ─── Turn-cap eviction ───────────────────────────────────────────────────

  test "save_turn trims to toolResultRetentionTurns (oldest-first)" do
    sid = uid(); uid_ = uid()
    insert_session(sid, uid_)

    n = Dmhai.Agent.AgentSettings.tool_result_retention_turns()

    # Write N+2 entries; oldest two should be evicted by the turn cap.
    for i <- 1..(n + 2) do
      msgs = stub_extract_messages("t#{i}", "workspace/f#{i}.pdf", "c#{i}")
      :ok = ToolHistory.save_turn(sid, uid_, 1_000 + i, msgs)
    end

    entries = ToolHistory.load(sid)
    assert length(entries) == n
    # The EARLIEST retained ts should be (2+1) = 3 (turns 1 and 2 evicted).
    assert hd(entries)["assistant_ts"] == 1_000 + 3
    # And the latest is the most recent.
    assert List.last(entries)["assistant_ts"] == 1_000 + n + 2
  end

  # ─── Byte-budget eviction ────────────────────────────────────────────────

  test "save_turn byte-budget evicts oldest when combined size exceeds cap" do
    sid = uid(); uid_ = uid()
    insert_session(sid, uid_)

    # Construct messages that alone exceed half the byte budget so two of
    # them can't both fit. Uses a printable ASCII blob for deterministic size.
    half_cap = div(Dmhai.Agent.AgentSettings.tool_result_retention_bytes(), 2)
    big_payload = String.duplicate("x", half_cap + 200)

    for i <- 1..3 do
      msgs = stub_extract_messages("t#{i}", "workspace/f#{i}.pdf", big_payload)
      :ok = ToolHistory.save_turn(sid, uid_, 2_000 + i, msgs)
    end

    entries = ToolHistory.load(sid)
    # With 3 massive entries each > half the budget, only one fits.
    assert length(entries) <= 2
    # The most recent is retained (oldest-first eviction).
    assert List.last(entries)["assistant_ts"] == 2_003
  end

  # ─── inject: interleave into history_llm ────────────────────────────────

  test "inject places retained messages immediately before the matching assistant ts" do
    user_msg = %{role: "user", content: "what is this?", ts: 100}
    assistant_msg = %{role: "assistant", content: "It's a contract.", ts: 200}

    history = [user_msg, assistant_msg]

    retained_msgs = stub_extract_messages("tX", "workspace/x.pdf", "OCR output")
    tool_history = [
      %{"assistant_ts" => 200, "messages" => Enum.map(retained_msgs, &stringify_keys/1)}
    ]

    out = ToolHistory.inject(history, tool_history)

    # Should now be: [user, <retained...>, assistant]
    assert List.first(out) == user_msg
    assert List.last(out) == assistant_msg
    # Retained messages sit between.
    between = Enum.slice(out, 1, length(out) - 2)
    assert length(between) == length(retained_msgs)
    assert Enum.at(between, 0).role == "assistant"
  end

  test "inject skips entries with no matching assistant ts in history" do
    history = [%{role: "user", content: "hi", ts: 100},
               %{role: "assistant", content: "hey", ts: 200}]

    # tool_history has an orphan ts (999) that doesn't correspond to any msg.
    tool_history = [
      %{"assistant_ts" => 999,
        "messages" => [%{"role" => "assistant", "content" => "", "tool_calls" => []}]}
    ]

    out = ToolHistory.inject(history, tool_history)
    # Unchanged — no injection happened.
    assert out == history
  end

  test "inject is a no-op when tool_history is empty" do
    history = [%{role: "user", content: "hi", ts: 100},
               %{role: "assistant", content: "hey", ts: 200}]

    assert ToolHistory.inject(history, []) == history
  end

  test "inject handles multiple matching entries in correct positional order" do
    history = [
      %{role: "user", content: "q1", ts: 100},
      %{role: "assistant", content: "a1", ts: 200},
      %{role: "user", content: "q2", ts: 300},
      %{role: "assistant", content: "a2", ts: 400}
    ]

    th1 = stub_extract_messages("t1", "workspace/a.pdf", "content1")
    th2 = stub_extract_messages("t2", "workspace/b.pdf", "content2")

    tool_history = [
      %{"assistant_ts" => 200, "messages" => Enum.map(th1, &stringify_keys/1)},
      %{"assistant_ts" => 400, "messages" => Enum.map(th2, &stringify_keys/1)}
    ]

    out = ToolHistory.inject(history, tool_history)

    # Find positions of a1 and a2 in output and verify retained msgs sit right before each.
    assert Enum.at(out, 0).ts == 100
    # Retained block for a1 follows, then a1.
    # Retained block for a2 follows, then a2.
    a1_idx = Enum.find_index(out, fn m -> m[:ts] == 200 and m[:role] == "assistant" end)
    a2_idx = Enum.find_index(out, fn m -> m[:ts] == 400 and m[:role] == "assistant" end)

    assert is_integer(a1_idx) and is_integer(a2_idx)
    assert a2_idx > a1_idx
    # Messages between user1 and a1 are th1 (length 4).
    assert a1_idx == 1 + length(th1)
  end

  # ─── fetch_task pair stripping in save_turn ─────────────────────────────

  describe "save_turn strips fetch_task pairs" do
    test "drops a fetch_task tool_call and its matching tool_result" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)

      msgs = [
        %{
          role: "assistant", content: "",
          tool_calls: [%{
            "id" => "ft1",
            "function" => %{"name" => "fetch_task", "arguments" => %{"task_num" => 2}}
          }]
        },
        %{role: "tool", tool_call_id: "ft1", content: "TASK_2_ARCHIVE_CONTENT (large)"}
      ]

      :ok = ToolHistory.save_turn(sid, uid_, 1_777_100_000_000, msgs)
      assert ToolHistory.load(sid) == [], "pure-fetch chain leaves nothing to save"
    end

    test "preserves non-fetch_task tool_calls in the same batch; drops only fetch's pair" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)

      msgs = [
        %{
          role: "assistant", content: "",
          tool_calls: [
            %{"id" => "rs1", "function" => %{"name" => "run_script", "arguments" => %{"script" => "echo ok"}}},
            %{"id" => "ft1", "function" => %{"name" => "fetch_task", "arguments" => %{"task_num" => 3}}}
          ]
        },
        %{role: "tool", tool_call_id: "rs1", content: "ok"},
        %{role: "tool", tool_call_id: "ft1", content: "TASK_3_ARCHIVE (would dup)"}
      ]

      :ok = ToolHistory.save_turn(sid, uid_, 1_777_101_000_000, msgs)
      [entry] = ToolHistory.load(sid)
      stored = entry["messages"]

      # Assistant message kept, with run_script remaining only.
      asst = Enum.find(stored, &(&1["role"] == "assistant"))
      assert asst != nil
      assert length(asst["tool_calls"]) == 1
      assert hd(asst["tool_calls"])["function"]["name"] == "run_script"

      # Only the run_script tool_result survives.
      tool_results = Enum.filter(stored, &(&1["role"] == "tool"))
      assert length(tool_results) == 1
      assert hd(tool_results)["tool_call_id"] == "rs1"
      refute Enum.any?(tool_results, fn t -> String.contains?(t["content"], "TASK_3_ARCHIVE") end),
             "fetch_task result content must not appear in saved entry"
    end

    test "drops the entire assistant message when fetch_task was its sole tool_call" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)

      msgs = [
        # Solo fetch_task message — drops entirely.
        %{role: "assistant", content: "",
          tool_calls: [%{"id" => "ft1",
                         "function" => %{"name" => "fetch_task", "arguments" => %{"task_num" => 5}}}]},
        %{role: "tool", tool_call_id: "ft1", content: "fetched data"},
        # Followed by a real run_script — stays.
        %{role: "assistant", content: "",
          tool_calls: [%{"id" => "rs1",
                         "function" => %{"name" => "run_script", "arguments" => %{"script" => "echo hi"}}}]},
        %{role: "tool", tool_call_id: "rs1", content: "hi"}
      ]

      :ok = ToolHistory.save_turn(sid, uid_, 1_777_102_000_000, msgs)
      [entry] = ToolHistory.load(sid)
      stored = entry["messages"]

      # Only the run_script pair remains — 1 assistant + 1 tool.
      assert length(stored) == 2
      asst = Enum.at(stored, 0)
      tool = Enum.at(stored, 1)
      assert asst["role"] == "assistant"
      assert hd(asst["tool_calls"])["function"]["name"] == "run_script"
      assert tool["role"] == "tool"
      assert tool["tool_call_id"] == "rs1"
    end

    test "passthrough when no fetch_task is present" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)

      msgs = stub_extract_messages("t_" <> uid(), "workspace/x.pdf", "extracted")
      :ok = ToolHistory.save_turn(sid, uid_, 1_777_103_000_000, msgs)
      [entry] = ToolHistory.load(sid)
      assert length(entry["messages"]) == 4, "non-fetch chain stored verbatim"
    end
  end

  # ─── flush_for_task ──────────────────────────────────────────────────────

  describe "flush_for_task/2" do
    alias Dmhai.Agent.{Tasks, TaskTurnArchive}

    defp insert_task(sid, uid_) do
      Tasks.insert(%{
        session_id:  sid,
        user_id:     uid_,
        task_title:  "T",
        task_spec:   "spec",
        task_status: "ongoing",
        task_type:   "one_off"
      })
    end

    test "moves matching task's entries from rolling window to task_turn_archive" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)
      task_id = insert_task(sid, uid_)
      task = Tasks.get(task_id)

      msgs = stub_extract_messages(task_id, "workspace/foo.pdf", "extracted content")
      :ok = ToolHistory.save_turn(sid, uid_, 1_777_000_000_000, msgs, task.task_num)

      assert length(ToolHistory.load(sid)) == 1
      assert TaskTurnArchive.fetch_for_task(task_id) == []

      :ok = ToolHistory.flush_for_task(sid, task.task_num)

      assert ToolHistory.load(sid) == [], "task's entries should be removed from rolling window"
      archive = TaskTurnArchive.fetch_for_task(task_id)
      assert length(archive) == 4, "task's tool messages should land in task_turn_archive"
    end

    test "leaves entries from other tasks in place" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)
      task_a = Tasks.get(insert_task(sid, uid_))
      task_b = Tasks.get(insert_task(sid, uid_))

      :ok = ToolHistory.save_turn(sid, uid_, 1_777_001_000_000,
              stub_extract_messages(task_a.task_id, "a.pdf", "A content"), task_a.task_num)
      :ok = ToolHistory.save_turn(sid, uid_, 1_777_002_000_000,
              stub_extract_messages(task_b.task_id, "b.pdf", "B content"), task_b.task_num)

      assert length(ToolHistory.load(sid)) == 2

      :ok = ToolHistory.flush_for_task(sid, task_a.task_num)

      retained = ToolHistory.load(sid)
      assert length(retained) == 1, "task B's entry should still be in rolling window"
      assert hd(retained)["task_num"] == task_b.task_num

      assert length(TaskTurnArchive.fetch_for_task(task_a.task_id)) == 4
      assert TaskTurnArchive.fetch_for_task(task_b.task_id) == []
    end

    test "no-op when nil task_num" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)
      task = Tasks.get(insert_task(sid, uid_))
      :ok = ToolHistory.save_turn(sid, uid_, 1_777_003_000_000,
              stub_extract_messages(task.task_id, "x.pdf", "x"), task.task_num)

      :ok = ToolHistory.flush_for_task(sid, nil)

      assert length(ToolHistory.load(sid)) == 1
    end

    test "no-op when task_num doesn't match anything in retention" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)
      task = Tasks.get(insert_task(sid, uid_))
      :ok = ToolHistory.save_turn(sid, uid_, 1_777_004_000_000,
              stub_extract_messages(task.task_id, "x.pdf", "x"), task.task_num)

      :ok = ToolHistory.flush_for_task(sid, 9999)

      assert length(ToolHistory.load(sid)) == 1, "no match → no flush"
    end
  end

  # ─── Tasks.mark_done / mark_cancelled wire-through ──────────────────────

  describe "task close → flush integration" do
    alias Dmhai.Agent.{Tasks, TaskTurnArchive}

    test "mark_done flushes the task's tool_history into the archive" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)
      task_id = Tasks.insert(%{
        session_id:  sid, user_id: uid_,
        task_title:  "T", task_spec: "spec",
        task_status: "ongoing", task_type: "one_off"
      })
      task = Tasks.get(task_id)

      :ok = ToolHistory.save_turn(sid, uid_, 1_777_005_000_000,
              stub_extract_messages(task_id, "doc.pdf", "x"), task.task_num)
      assert length(ToolHistory.load(sid)) == 1

      Tasks.mark_done(task_id, "completed")

      assert ToolHistory.load(sid) == []
      assert length(TaskTurnArchive.fetch_for_task(task_id)) == 4
    end

    test "mark_cancelled flushes the task's tool_history into the archive" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)
      task_id = Tasks.insert(%{
        session_id:  sid, user_id: uid_,
        task_title:  "T", task_spec: "spec",
        task_status: "ongoing", task_type: "one_off"
      })
      task = Tasks.get(task_id)

      :ok = ToolHistory.save_turn(sid, uid_, 1_777_006_000_000,
              stub_extract_messages(task_id, "doc.pdf", "x"), task.task_num)
      assert length(ToolHistory.load(sid)) == 1

      Tasks.mark_cancelled(task_id, "user stopped")

      assert ToolHistory.load(sid) == []
      assert length(TaskTurnArchive.fetch_for_task(task_id)) == 4
    end

    test "periodic mark_done flushes too (next cycle starts with clean rolling window)" do
      sid = uid(); uid_ = uid()
      insert_session(sid, uid_)
      task_id = Tasks.insert(%{
        session_id:  sid, user_id: uid_,
        task_title:  "P", task_spec: "spec",
        task_status: "ongoing", task_type: "periodic", intvl_sec: 60
      })
      task = Tasks.get(task_id)

      :ok = ToolHistory.save_turn(sid, uid_, 1_777_007_000_000,
              stub_extract_messages(task_id, "doc.pdf", "x"), task.task_num)
      assert length(ToolHistory.load(sid)) == 1

      Tasks.mark_done(task_id, "cycle 1 complete")

      # Periodic re-arm: status flipped to pending, but tool_history flushed.
      assert ToolHistory.load(sid) == []
      assert length(TaskTurnArchive.fetch_for_task(task_id)) == 4
      # And the task is still alive (re-armed for next cycle).
      assert Tasks.get(task_id).task_status == "pending"
    end
  end

  # String-key normaliser to match the stored shape (JSON-decoded maps).
  defp stringify_keys(msg) do
    msg
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end
end
