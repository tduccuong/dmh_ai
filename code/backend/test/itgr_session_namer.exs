# Integration tests: auto session naming.
#
# Coverage:
#   - first_rename → simple prompt, no "Current session title" block
#   - refresh-rename → bridge prompt embeds the current title verbatim
#   - last N user messages collected (chronological), N = AgentSettings setting
#   - /memo and /wiki user messages excluded from the prompt
#   - assistant messages excluded
#   - empty message-list (no eligible user msgs) → no LLM call, returns name=nil
#   - LLM reply is sanitised (markdown bold, surrounding quotes stripped)
#   - 403 on cross-user access
#
# Run with:   MIX_ENV=test mix test test/itgr_session_namer.exs

defmodule Itgr.SessionNamer do
  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Agent.AgentSettings}
  alias DmhAi.Handlers.Data, as: DataHandler
  import Ecto.Adapters.SQL, only: [query!: 3]
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      """
      INSERT OR IGNORE INTO users (id, email, password_hash, role, created_at)
      VALUES (?,?,?,?,?)
      """,
      [user_id, "namer_#{user_id}@itgr.local", "", "user", now])
  end

  defp seed_session(session_id, user_id, name, msgs) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, name, messages, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
      [session_id, user_id, "confidant", name, Jason.encode!(msgs), now, now])
  end

  defp user_msg(ts, content), do: %{"role" => "user", "content" => content, "ts" => ts}
  defp assistant_msg(ts, content), do: %{"role" => "assistant", "content" => content, "ts" => ts}

  defp name_of(session_id) do
    %{rows: [[n]]} = query!(Repo, "SELECT name FROM sessions WHERE id=?", [session_id])
    n
  end

  defp call_name(user, session_id, body) do
    {:ok, encoded} = Jason.encode(body)

    conn(:post, "/sessions/#{session_id}/name", encoded)
    |> put_req_header("content-type", "application/json")
    |> DataHandler.post_name_session(user, session_id)
  end

  defp capture_llm_calls(reply \\ {:ok, "Some Title"}) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    T.stub_llm_call(fn _model, msgs, _opts ->
      Agent.update(agent, fn calls -> calls ++ [msgs] end)
      reply
    end)

    agent
  end

  defp captured_calls(agent), do: Agent.get(agent, & &1)
  defp first_prompt(agent), do: agent |> captured_calls() |> hd() |> hd() |> Map.fetch!(:content)

  # ─── first_rename: simple prompt, no current-title block ────────────────────

  test "first_rename: prompt is the simple-title shape, no 'Current session title' block" do
    uid_ = uid(); sid = uid()
    seed_user(uid_)
    seed_session(sid, uid_, "New chat", [
      user_msg(1000, "tell me about Berlin"),
      user_msg(2000, "what's good there in autumn"),
      assistant_msg(2100, "..."),
      user_msg(3000, "any food recommendations")
    ])

    agent = capture_llm_calls({:ok, "Autumn in Berlin"})
    user = %{id: uid_}
    call_name(user, sid, %{"first_rename" => true})

    text = first_prompt(agent)
    refute text =~ "Current session title"
    assert text =~ "Give a short title"
    assert text =~ "tell me about Berlin"
    assert text =~ "any food recommendations"

    assert name_of(sid) == "Autumn in Berlin"
  end

  # ─── refresh: bridge prompt with old title ─────────────────────────────────

  test "refresh-rename: bridge prompt carries the old title and the user batch" do
    uid_ = uid(); sid = uid()
    seed_user(uid_)
    seed_session(sid, uid_, "Berlin Trip Planning", [
      user_msg(1000, "actually we might shift to Munich"),
      user_msg(2000, "what's a good base for Bavaria day trips"),
      user_msg(3000, "do trains run on Sundays"),
      user_msg(4000, "do I need cash or are cards fine")
    ])

    agent = capture_llm_calls({:ok, "Berlin → Bavaria Pivot"})
    call_name(%{id: uid_}, sid, %{"first_rename" => false})

    text = first_prompt(agent)
    assert text =~ "Current session title: \"Berlin Trip Planning\""
    assert text =~ "actually we might shift to Munich"
    assert text =~ "do trains run on Sundays"
    # Bridge instruction wording must be present so the model knows the policy.
    assert text =~ "bridges the old title and the new direction"
    assert text =~ "lean toward continuity"
    assert text =~ "lean toward the new content"

    assert name_of(sid) == "Berlin → Bavaria Pivot"
  end

  # ─── batch size honours AgentSettings ──────────────────────────────────────

  test "only the last N user messages are passed; older ones drop out" do
    n = AgentSettings.session_namer_user_msg_count()
    uid_ = uid(); sid = uid()
    seed_user(uid_)

    msgs =
      for i <- 1..(n + 3) do
        user_msg(1000 + i * 100, "msg-#{i}")
      end

    seed_session(sid, uid_, "New chat", msgs)

    agent = capture_llm_calls()
    call_name(%{id: uid_}, sid, %{"first_rename" => true})

    text = first_prompt(agent)
    # The last N must appear; the first 3 must NOT.
    for i <- 4..(n + 3), do: assert text =~ "msg-#{i}"
    for i <- 1..3, do: refute text =~ "\"msg-#{i}\""
  end

  # ─── slash commands excluded ───────────────────────────────────────────────

  test "/memo and /wiki user messages are excluded from the prompt" do
    uid_ = uid(); sid = uid()
    seed_user(uid_)
    seed_session(sid, uid_, "New chat", [
      user_msg(1000, "/memo my coffee preference is oat milk"),
      user_msg(2000, "what's the weather in Berlin tomorrow"),
      user_msg(3000, "/wiki https://example.com/api"),
      user_msg(4000, "any cafe recommendations near Mitte")
    ])

    agent = capture_llm_calls()
    call_name(%{id: uid_}, sid, %{"first_rename" => true})

    text = first_prompt(agent)
    refute text =~ "/memo"
    refute text =~ "/wiki"
    assert text =~ "what's the weather in Berlin tomorrow"
    assert text =~ "any cafe recommendations near Mitte"
  end

  # ─── assistant messages ignored ────────────────────────────────────────────

  test "assistant messages do not bleed into the prompt" do
    uid_ = uid(); sid = uid()
    seed_user(uid_)
    seed_session(sid, uid_, "New chat", [
      user_msg(1000, "user-question-one"),
      assistant_msg(1100, "assistant-reply-one"),
      user_msg(2000, "user-question-two"),
      assistant_msg(2100, "assistant-reply-two"),
      user_msg(3000, "user-question-three"),
      user_msg(4000, "user-question-four")
    ])

    agent = capture_llm_calls()
    call_name(%{id: uid_}, sid, %{"first_rename" => true})

    text = first_prompt(agent)
    refute text =~ "assistant-reply-one"
    refute text =~ "assistant-reply-two"
    assert text =~ "user-question-one"
    assert text =~ "user-question-four"
  end

  # ─── no eligible user messages → no LLM call ───────────────────────────────

  test "session with no eligible user messages: no LLM call, name unchanged" do
    uid_ = uid(); sid = uid()
    seed_user(uid_)
    seed_session(sid, uid_, "New chat", [
      assistant_msg(1000, "hello there"),
      user_msg(2000, "/memo a"),
      user_msg(3000, "/wiki b")
    ])

    agent = capture_llm_calls()
    call_name(%{id: uid_}, sid, %{"first_rename" => true})

    assert captured_calls(agent) == []
    assert name_of(sid) == "New chat"
  end

  # ─── sanitisation ──────────────────────────────────────────────────────────

  test "sanitises markdown bold and surrounding quotes from the LLM reply" do
    uid_ = uid(); sid = uid()
    seed_user(uid_)
    seed_session(sid, uid_, "New chat", [
      user_msg(1000, "a"), user_msg(2000, "b"),
      user_msg(3000, "c"), user_msg(4000, "d")
    ])

    capture_llm_calls({:ok, "**\"Berlin Autumn Trip\"**"})
    call_name(%{id: uid_}, sid, %{"first_rename" => true})

    assert name_of(sid) == "Berlin Autumn Trip"
  end

  # ─── ownership: 403 on cross-user ──────────────────────────────────────────

  test "403 when the requesting user does not own the session" do
    owner = uid(); other = uid(); sid = uid()
    seed_user(owner); seed_user(other)
    seed_session(sid, owner, "New chat", [user_msg(1000, "x")])

    capture_llm_calls()
    conn = call_name(%{id: other}, sid, %{"first_rename" => true})

    assert conn.status == 403
    # And the session name must remain untouched.
    assert name_of(sid) == "New chat"
  end
end
