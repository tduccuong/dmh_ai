# Integration tests: ContextEngine runtime blocks wired to tool_history state.
# Run with: MIX_ENV=test mix test test/itgr_context_tool_integration.exs
#
# Covers:
#  - AttachmentPaths.clean_spec/1 strips both line-start and inline 📎 refs
#  - ContextEngine injects "## Recently-extracted files" block when
#    tool_history contains extract_content entries, with task_num cross-ref
#  - The block is absent on sessions with no extractions

defmodule Itgr.ContextToolIntegration do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{ContextEngine, AttachmentPaths, UserAgent}
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_session(sid, uid_, tool_history_json \\ nil) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
      [sid, uid_, "assistant", "[]", tool_history_json, now, now])
  end

  # Build session_data the SAME WAY the production code path does — via
  # UserAgent.load_session/2 — so tests exercise the real wiring instead
  # of synthesising a map that happens to satisfy ContextEngine's
  # contract. The itgr_session_context_contract.exs suite protects the
  # contract itself; these tests focus on downstream logic.
  defp load_session_data(sid, uid_, extra_messages) do
    # Patch in the test's "current user message" by rewriting
    # sessions.messages — this keeps load_session/2 honest (it reads
    # messages from the DB row, not from a side channel).
    case extra_messages do
      [] ->
        :ok

      _ ->
        query!(Repo, "UPDATE sessions SET messages=? WHERE id=?",
               [Jason.encode!(extra_messages), sid])
    end

    {:ok, _model, sd} = UserAgent.load_session(sid, uid_)
    sd
  end

  defp find_msg(msgs, role, pred) do
    Enum.find(msgs, fn m -> m.role == role and pred.(m.content) end)
  end

  # ─── AttachmentPaths.clean_spec ──────────────────────────────────────────

  test "clean_spec strips 📎 at line start" do
    input = "what is this doc about?\n\n📎 workspace/foo.pdf"
    assert AttachmentPaths.clean_spec(input) == "what is this doc about?"
  end

  test "clean_spec strips 📎 inline (collapsed newline case)" do
    # Model flattens newlines; 📎 ends up mid-sentence. This was the
    # regression symptom that broke Phase-2 dedup.
    input = "what is this doc about? 📎 workspace/foo.pdf"
    assert AttachmentPaths.clean_spec(input) == "what is this doc about?"
  end

  test "clean_spec strips multiple 📎 refs" do
    input = "Look at 📎 workspace/a.pdf and 📎 data/b.txt together."
    out = AttachmentPaths.clean_spec(input)
    refute String.contains?(out, "📎")
    refute String.contains?(out, "workspace/a.pdf")
    refute String.contains?(out, "data/b.txt")
    assert String.contains?(out, "Look at")
    assert String.contains?(out, "together.")
  end

  test "clean_spec leaves spec untouched when no 📎 present" do
    input = "just a plain question with no attachment"
    assert AttachmentPaths.clean_spec(input) == input
  end

  test "clean_spec strips the [newly attached] transient marker too" do
    input = "question\n\n📎 [newly attached] workspace/foo.pdf"
    out = AttachmentPaths.clean_spec(input)
    refute String.contains?(out, "[newly attached]")
    refute String.contains?(out, "workspace/foo.pdf")
  end

  # ─── Recently-extracted files runtime block ─────────────────────────────

  test "absent when tool_history is empty (pure-chat session)" do
    sid = uid(); uid_ = uid()
    seed_session(sid, uid_)
    sd = load_session_data(sid, uid_, [user_msg("hi")])

    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: [], recent_done: [])
    refute find_msg(msgs, "user", &String.starts_with?(&1, "## Recently-extracted files"))
  end

  test "present with filename + task_num when tool_history has an extract_content entry" do
    sid = uid(); uid_ = uid()

    # One retained turn: model called extract_content + complete_task for the PDF.
    path = "workspace/HopDongCTV_CuongTruong_Adigitrans.pdf"
    task_id = "tsk_" <> uid()

    tool_history = [
      %{
        "assistant_ts" => 123_456,
        "messages" => [
          %{"role" => "assistant", "content" => "", "tool_calls" => [
            %{"id" => "c1",
              "function" => %{
                "name" => "extract_content",
                "arguments" => %{"path" => path}
              }}
          ]},
          %{"role" => "tool", "content" => "OCR output...", "tool_call_id" => "c1"},
          %{"role" => "assistant", "content" => "", "tool_calls" => [
            %{"id" => "c2",
              "function" => %{
                "name" => "complete_task",
                "arguments" => %{"task_id" => task_id, "task_result" => "done"}
              }}
          ]},
          %{"role" => "tool", "content" => "{\"ok\":true}", "tool_call_id" => "c2"}
        ]
      }
    ]

    seed_session(sid, uid_, Jason.encode!(tool_history))
    sd = load_session_data(sid, uid_, [user_msg("tell me more about task 1")])

    done_task = %{
      task_id: task_id, task_num: 1,
      task_title: "Adigitrans contract",
      task_status: "done", task_type: "one_off",
      task_spec: "what is this?", task_result: "…",
      time_to_pickup: nil, attachments: [path]
    }

    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: [], recent_done: [done_task])

    block = find_msg(msgs, "user", &String.starts_with?(&1, "## Recently-extracted files"))
    assert block != nil, "Recently-extracted block should be injected"
    assert String.contains?(block.content, path)
    assert String.contains?(block.content, "(1)"),
           "block should cross-reference the task_num (1) of the originating task"
  end

  test "dedupes entries when the same file was extracted in multiple retained turns" do
    sid = uid(); uid_ = uid()
    path = "workspace/foo.pdf"

    # Two retained turns, same file.
    entry = fn ts ->
      %{
        "assistant_ts" => ts,
        "messages" => [
          %{"role" => "assistant", "content" => "", "tool_calls" => [
            %{"id" => "c#{ts}",
              "function" => %{"name" => "extract_content", "arguments" => %{"path" => path}}}
          ]},
          %{"role" => "tool", "content" => "content...", "tool_call_id" => "c#{ts}"}
        ]
      }
    end

    tool_history = [entry.(100), entry.(200)]
    seed_session(sid, uid_, Jason.encode!(tool_history))
    sd = load_session_data(sid, uid_, [user_msg("hi")])

    msgs = ContextEngine.build_assistant_messages(sd, active_tasks: [], recent_done: [])
    block = find_msg(msgs, "user", &String.starts_with?(&1, "## Recently-extracted files"))

    assert block != nil
    # The path should appear exactly once in the block.
    occurrences = Regex.scan(~r/workspace\/foo\.pdf/, block.content) |> length()
    assert occurrences == 1
  end

  # ─── Helpers ─────────────────────────────────────────────────────────────

  defp user_msg(content), do: %{"role" => "user", "content" => content}
end
