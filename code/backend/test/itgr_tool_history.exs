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

  # String-key normaliser to match the stored shape (JSON-decoded maps).
  defp stringify_keys(msg) do
    msg
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end
end
