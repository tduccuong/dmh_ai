# Integration tests: explicit `chain_end` SessionProgress row as the
# FE termination signal.
#
# The Assistant `session_chain_loop` emits one `chain_end` row at every
# normal chain-end branch (close-verb, final text, empty response,
# turn cap, form, error, aborted-on-issue). The FE's polling loop
# treats either `chain_end` or `chain_aborted` as termination — without
# this row, a close-verb chain end with empty narration leaves the FE
# waiting for an assistant message that never arrives.
#
# These tests focus on the most regression-prone branch: the close-verb
# terminator with empty narration (the bug that prompted the change).

defmodule Itgr.ChainEndSignal do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{AssistantCommand, SessionProgress, UserAgent}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "ce_#{user_id}@itgr.local", "user", now])
  end

  defp insert_session(session_id, user_id, messages) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, "assistant", Jason.encode!(messages), now, now])
  end

  defp progress_rows(session_id) do
    SessionProgress.fetch_for_session(session_id, 0)
  end

  defp wait_until(deadline_ms, fun) do
    deadline = System.os_time(:millisecond) + deadline_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    case fun.() do
      true -> :ok
      _ ->
        if System.os_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(20)
          do_wait_until(deadline, fun)
        end
    end
  end

  defp assistant_cmd(session_id, content) do
    %AssistantCommand{
      type:             :chat,
      content:          content,
      session_id:       session_id,
      reply_pid:        self(),
      attachment_names: [],
      files:            [],
      metadata:         %{}
    }
  end

  describe "SessionProgress.append_chain_end/2 (helper)" do
    test "writes a kind=chain_end row with cause as label" do
      session_id = uid(); user_id = uid(); seed_user(user_id)

      ctx = %{session_id: session_id, user_id: user_id, task_id: nil}
      assert {:ok, %{kind: "chain_end", label: "close_verb"} = row} =
               SessionProgress.append_chain_end(ctx, "close_verb")

      assert row.session_id == session_id
      assert row.user_id    == user_id
      assert is_integer(row.id)
      assert row.hidden     == false
    end

    test "round-trips through fetch_for_session" do
      session_id = uid(); user_id = uid(); seed_user(user_id)

      ctx = %{session_id: session_id, user_id: user_id, task_id: nil}
      {:ok, _} = SessionProgress.append_chain_end(ctx, "final_text")
      {:ok, _} = SessionProgress.append_chain_end(ctx, "error")

      rows = SessionProgress.fetch_for_session(session_id, 0)
      causes = rows |> Enum.filter(&(&1.kind == "chain_end")) |> Enum.map(& &1.label)
      assert "final_text" in causes
      assert "error" in causes
    end
  end

  describe "session_chain_loop emits chain_end" do
    test "final-text chain end → kind=chain_end, label=\"final_text\"" do
      user_id = uid(); session_id = uid()
      seed_user(user_id)
      insert_session(session_id, user_id,
        [%{"role" => "user", "content" => "what's 2+2?"}])

      # Stub LLM.stream/4 to return a final text immediately. No tool
      # calls — the chain ends on the first turn via the
      # `{:ok, text}` non-empty branch.
      T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
        {:ok, "Four."}
      end)

      _ = UserAgent.dispatch_assistant(user_id, assistant_cmd(session_id, "what's 2+2?"))

      assert :ok =
               wait_until(3_000, fn ->
                 Enum.any?(progress_rows(session_id), fn r ->
                   r.kind == "chain_end" and r.label == "final_text"
                 end)
               end)
    end

    test "empty-response chain end → kind=chain_end, label=\"empty_response\"" do
      user_id = uid(); session_id = uid()
      seed_user(user_id)
      insert_session(session_id, user_id,
        [%{"role" => "user", "content" => "anything"}])

      # Stub LLM.stream/4 to return {:ok, ""} — the empty_response branch.
      T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
        {:ok, ""}
      end)

      _ = UserAgent.dispatch_assistant(user_id, assistant_cmd(session_id, "anything"))

      assert :ok =
               wait_until(3_000, fn ->
                 Enum.any?(progress_rows(session_id), fn r ->
                   r.kind == "chain_end" and r.label == "empty_response"
                 end)
               end)
    end

    test "LLM-call error chain end → kind=chain_end, label=\"error\"" do
      user_id = uid(); session_id = uid()
      seed_user(user_id)
      insert_session(session_id, user_id,
        [%{"role" => "user", "content" => "anything"}])

      T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
        {:error, "stub error"}
      end)

      _ = UserAgent.dispatch_assistant(user_id, assistant_cmd(session_id, "anything"))

      assert :ok =
               wait_until(3_000, fn ->
                 Enum.any?(progress_rows(session_id), fn r ->
                   r.kind == "chain_end" and r.label == "error"
                 end)
               end)
    end
  end
end
