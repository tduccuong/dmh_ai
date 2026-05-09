# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F05 — Confidant turn with an attached file.
#
# Confidant's file-attachment contract:
#
#   * The FE extracts text content client-side (PDF.js for PDFs,
#     plain reads for text). The HTTP handler's `parse_files/1`
#     accepts only the `[%{"name" => ..., "content" => ...}]` shape;
#     anything else is dropped silently.
#   * `ConfidantCommand.files` carries that list verbatim into
#     `run_confidant`. `ContextEngine.build_confidant_messages/2`
#     folds every entry into the LLM's user-role message body
#     (filename + content per file).
#   * The user-role message persisted to `session.messages` carries
#     ONLY the text the user typed — file content stays in the LLM
#     prompt, never on the displayed scrollback (FE shows a per-
#     attachment chip rendered separately).
#
# F05 validates the contract end-to-end via `dispatch_confidant`:
#   1. File content reaches the LLM (asserted by the stream stub
#      seeing the file body).
#   2. Final assistant text is persisted.
#   3. Persisted user message does NOT contain the file body —
#      prompt-only delivery is load-bearing for chat compaction
#      (otherwise the same file contents accumulate verbatim across
#      every confidant turn that referenced it).

defmodule DmhAi.Flows.F05ConfidantWithFile do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{ConfidantCommand, UserAgent, UserAgentMessages}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F05"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F05")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       System.os_time(:millisecond)])

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [session_id, user_id, "confidant", "[]", "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "attached file content reaches LLM context but not session.messages",
       %{user_id: user_id, session_id: session_id} do
    # Planner stub — no web search needed for this test.
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "SEARCH: NO"} end)

    # A clearly-fingerprintable string the test asserts on. Has to
    # be unusual enough that an accidental match against system-
    # prompt boilerplate is impossible.
    file_body =
      "FILE_FINGERPRINT_#{T.uid()} — Q3 revenue was 8.4M EUR; up 12% YoY."

    file_seen = :counters.new(1, [:atomics])

    T.stub_llm_stream(fn _model, msgs, _reply_pid, _opts ->
      msg_dump =
        msgs
        |> Enum.map_join("\n", fn m -> to_string(m["content"] || m[:content] || "") end)

      if String.contains?(msg_dump, file_body) do
        :counters.add(file_seen, 1, 1)
      end

      # The model gives a grounded answer that quotes the figure.
      {:ok, "Q3 revenue was 8.4M EUR (12% YoY growth) — per the attached report."}
    end)

    user_text = "summarise the attached Q3 report in one sentence"

    drive_confidant_with_file(user_id, session_id, user_text,
      filename: "q3-report.txt",
      content:  file_body)

    # 1. File body reached the LLM context.
    assert :counters.get(file_seen, 1) >= 1,
           "attached file content must be folded into the confidant LLM's user-role message"

    # 2. Final assistant text persisted with the grounded answer.
    final_assistant = read_final_assistant(session_id)
    assert final_assistant =~ "8.4M" or final_assistant =~ "Q3" or final_assistant =~ "revenue",
           "confidant should produce a grounded answer; got: #{inspect(final_assistant)}"

    # 3. Persisted user message contains ONLY the text the user
    #    typed. File body must NOT be inlined into session.messages
    #    — chat history doesn't accumulate file contents per turn.
    persisted_user = read_first_user(session_id)
    assert persisted_user == user_text,
           "persisted user message should be exactly what the user typed, not the file body; " <>
             "got: #{inspect(persisted_user)}"

    refute String.contains?(persisted_user, file_body),
           "file body must not leak into the persisted user message — would compound across turns"

    # 4. Session count: exactly one user msg + one assistant msg.
    %{rows: [[messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])
    messages = Jason.decode!(messages_json || "[]")

    user_count = Enum.count(messages, fn m -> (m["role"] || m[:role]) == "user" end)
    assistant_count = Enum.count(messages, fn m -> (m["role"] || m[:role]) == "assistant" end)
    assert user_count == 1, "expected one persisted user message; got: #{user_count}"
    assert assistant_count == 1, "expected one persisted assistant message; got: #{assistant_count}"
  end

  test "files=[] degrades gracefully — confidant runs as a plain text turn",
       %{user_id: user_id, session_id: session_id} do
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "SEARCH: NO"} end)

    T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
      {:ok, "Hi! What can I help you with today?"}
    end)

    drive_confidant(user_id, session_id, "hello")

    final = read_final_assistant(session_id)
    assert final =~ "help" or final =~ "Hi",
           "confidant should still produce a reply with no file attachment; got: #{inspect(final)}"
  end

  test "malformed file entries (missing :content) are dropped before reaching the LLM",
       %{user_id: user_id, session_id: session_id} do
    T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "SEARCH: NO"} end)

    leak_marker = "MALFORMED_BODY_#{T.uid()}"

    T.stub_llm_stream(fn _model, msgs, _reply_pid, _opts ->
      msg_dump =
        msgs
        |> Enum.map_join("\n", fn m -> to_string(m["content"] || m[:content] || "") end)

      refute String.contains?(msg_dump, leak_marker),
             "a file entry without a :content key must NEVER reach the LLM context " <>
               "(the HTTP handler's parse_files/1 drops it; defensive at the inner layer too)"

      {:ok, "answered without the (dropped) attachment"}
    end)

    # Build a malformed file entry — has `name` but no `content`.
    # `parse_files/1` would have dropped this at the HTTP boundary,
    # but here we shove it directly into ConfidantCommand to test
    # the inner layer's defence.
    malformed_file = %{"name" => "broken.txt", "leaked_field" => leak_marker}

    drive_confidant_with_files(user_id, session_id, "what's in there?",
      [malformed_file])

    final = read_final_assistant(session_id)
    assert final =~ "answered",
           "confidant should still produce a reply when files are malformed; got: #{inspect(final)}"
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp drive_confidant(user_id, session_id, content),
    do: drive_confidant_with_files(user_id, session_id, content, [])

  defp drive_confidant_with_file(user_id, session_id, content, opts) do
    file = %{
      "name"    => Keyword.fetch!(opts, :filename),
      "content" => Keyword.fetch!(opts, :content)
    }

    drive_confidant_with_files(user_id, session_id, content, [file])
  end

  defp drive_confidant_with_files(user_id, session_id, content, files) do
    test_pid = self()

    {:ok, _ts} =
      UserAgentMessages.append(session_id, user_id, %{role: "user", content: content})

    cmd = %ConfidantCommand{
      type:        :chat,
      content:     content,
      session_id:  session_id,
      reply_pid:   test_pid,
      images:      [],
      image_names: [],
      files:       files,
      has_video:   false
    }

    spawn_link(fn ->
      _ = UserAgent.dispatch_confidant(user_id, cmd)
    end)

    :ok = wait_until_idle(user_id, 8_000)
  end

  defp read_final_assistant(session_id) do
    %{rows: [[messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    messages = Jason.decode!(messages_json || "[]")

    case messages
         |> Enum.filter(fn m -> (m["role"] || m[:role]) == "assistant" end)
         |> List.last() do
      nil -> ""
      msg -> (msg["content"] || msg[:content]) |> to_string()
    end
  end

  defp read_first_user(session_id) do
    %{rows: [[messages_json]]} =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

    messages = Jason.decode!(messages_json || "[]")

    case messages
         |> Enum.filter(fn m -> (m["role"] || m[:role]) == "user" end)
         |> List.first() do
      nil -> ""
      msg -> (msg["content"] || msg[:content]) |> to_string()
    end
  end

  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        flunk("F05: confidant turn never reached idle within deadline")

      UserAgent.current_turn_session_id(user_id) != nil ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, nil)

      is_nil(idle_since) ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, System.os_time(:millisecond))

      System.os_time(:millisecond) - idle_since >= grace_ms ->
        :ok

      true ->
        Process.sleep(25)
        do_wait_until_idle(user_id, deadline, idle_since)
    end
  end
end
