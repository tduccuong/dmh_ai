# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F01 — Login + first chat (HTTP-handler level).
#
# Drives the live `DmhAi.Router` via synthesised `Plug.Conn`s — same
# shape as F24, but covers the auth + session-creation path the FE
# follows on a fresh login:
#
#   POST /auth/login           — get a Bearer token
#   POST /sessions             — open a new session under that user
#   POST /agent/chat           — first user message in the session
#
# Negative paths covered:
#
#   * POST /auth/login with the wrong password → 401
#   * POST /sessions without a token (or with a bad token) → 401
#   * POST /agent/chat for a session belonging to a DIFFERENT user
#     (cross-tenant safety net) → 403
#   * POST /agent/chat with empty content/files → 400
#
# What we DON'T assert: streaming chunks delivered through `/poll`.
# The chain runs asynchronously via `UserAgent.dispatch_assistant`;
# end-to-end "first answer streamed back" coverage lives in F25's
# stage smoke. F01's contract is "the user-message is persisted and
# a chain has been queued" — the live-path assertion is the BE-
# stamped `user_ts` echoing back in the response.

defmodule DmhAi.Flows.F01LoginFirstChat do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F01"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F01")
    on_exit(teardown)
    :ok
  end

  setup do
    # Each test gets its own user with a known password. Hash via
    # the production helper so verify_password/2 matches by
    # construction — never re-implement the format inline.
    user_id  = T.uid()
    # `T.uid()` uses Base.url_encode64 which can contain uppercase
    # letters; the login handler lowercases the incoming email
    # before lookup, so we store lowercased to match.
    email    = "u-#{user_id}@test.local" |> String.downcase()
    password = "correct-horse-staple-#{user_id}"
    password_hash = DmhAi.AuthPlug.hash_password(password)

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "Test User", "user", password_hash, 1,
       System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM session_progress WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM tasks WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, email: email, password: password}
  end

  describe "POST /auth/login" do
    test "wrong password → 401", %{email: email} do
      conn = post_json("/auth/login", %{"email" => email, "password" => "wrong"})

      assert conn.status == 401
      decoded = Jason.decode!(conn.resp_body)
      assert is_binary(decoded["error"])
    end

    test "correct password → 200 + token + user shape",
         %{email: email, password: password, user_id: user_id} do
      conn = post_json("/auth/login", %{"email" => email, "password" => password})

      assert conn.status == 200, "expected 200; got #{conn.status} body=#{conn.resp_body}"
      decoded = Jason.decode!(conn.resp_body)

      assert is_binary(decoded["token"]),
             "login response should include a token; got: #{inspect(decoded)}"
      assert String.length(decoded["token"]) == 64,
             "token should be 32 random bytes hex-encoded (64 chars); got: #{decoded["token"]}"

      user = decoded["user"]
      assert user["id"] == user_id
      assert user["email"] == email
      assert user["role"] == "user"
      assert user["passwordChanged"] == true,
             "this seeded user has password_changed=1; flag should round-trip; got: #{inspect(user)}"

      # Token is queryable via auth_tokens.
      %{rows: rows} =
        query!(Repo, "SELECT user_id FROM auth_tokens WHERE token=?", [decoded["token"]])
      assert rows == [[user_id]],
             "auth_tokens row should bind the new token to the seeded user; got: #{inspect(rows)}"
    end

    test "unknown email → 401" do
      conn = post_json("/auth/login", %{"email" => "ghost@test.local", "password" => "anything"})

      assert conn.status == 401
    end
  end

  describe "POST /sessions (token-gated)" do
    test "without Authorization header → 401", %{user_id: _} do
      conn = post_json("/sessions", %{"id" => T.uid()})

      assert conn.status == 401
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"] == "Unauthorized"
    end

    test "with bogus Bearer token → 401" do
      conn =
        post_json("/sessions", %{"id" => T.uid()}, token: "bogus-not-real")

      assert conn.status == 401
    end

    test "with valid token → 200, session row in DB",
         %{email: email, password: password, user_id: user_id} do
      token = login_for_token(email, password)
      session_id = T.uid()

      now = System.os_time(:millisecond)

      conn =
        post_json("/sessions",
          %{"id" => session_id, "name" => "first session", "createdAt" => now,
            "messages" => [], "mode" => "assistant"},
          token: token)

      assert conn.status == 200, "expected 200; got #{conn.status} body=#{conn.resp_body}"

      %{rows: rows} =
        query!(Repo,
          "SELECT user_id, mode FROM sessions WHERE id=?", [session_id])

      assert rows == [[user_id, "assistant"]],
             "session row should be bound to the authed user with the requested mode; got: #{inspect(rows)}"
    end
  end

  describe "POST /agent/chat — first message" do
    test "missing sessionId → 400",
         %{email: email, password: password} do
      token = login_for_token(email, password)

      conn = post_json("/agent/chat", %{"content" => "hi"}, token: token)

      assert conn.status == 400
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"] =~ "sessionId"
    end

    test "session belongs to a different user → 403",
         %{email: email, password: password} do
      # Create a foreign user + session under THEIR id.
      foreign_uid = T.uid()
      foreign_sid = T.uid()
      query!(Repo,
        "INSERT INTO users (id, email, name, role, password_hash, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?)",
        [foreign_uid, "foreign-#{foreign_uid}@test.local", "Foreign", "user",
         "deadbeef:cafe", System.os_time(:millisecond)])

      query!(Repo,
        "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [foreign_sid, foreign_uid, "assistant", "[]", "[]",
         System.os_time(:millisecond), System.os_time(:millisecond)])

      on_exit(fn ->
        query!(Repo, "DELETE FROM sessions WHERE id=?", [foreign_sid])
        query!(Repo, "DELETE FROM users WHERE id=?", [foreign_uid])
      end)

      our_token = login_for_token(email, password)

      conn =
        post_json("/agent/chat",
          %{"sessionId" => foreign_sid, "content" => "hello"},
          token: our_token)

      assert conn.status == 403,
             "cross-tenant chat must be rejected; got #{conn.status} body=#{conn.resp_body}"
    end

    test "happy path — user message persisted, BE-stamped user_ts returned",
         %{email: email, password: password, user_id: user_id} do
      token = login_for_token(email, password)
      session_id = T.uid()

      # Open an assistant-mode session.
      conn =
        post_json("/sessions",
          %{"id" => session_id, "name" => "F01 first chat",
            "createdAt" => System.os_time(:millisecond),
            "messages" => [], "mode" => "assistant"},
          token: token)
      assert conn.status == 200

      # Stub the LLM stream so the queued chain doesn't try to hit
      # a real model. The handler is fire-and-forget; the response
      # comes back as soon as the user message is persisted, so we
      # don't need to drive turn fns — a single empty-text response
      # is fine for the chain we won't observe completing.
      T.stub_llm_stream(fn _model, _msgs, _reply_pid, _opts ->
        {:ok, "ack."}
      end)

      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "RELATED"} end)

      conn =
        post_json("/agent/chat",
          %{"sessionId" => session_id, "content" => "hello, first message"},
          token: token)

      # `post_chat`'s assistant path is fire-and-forget — the user
      # message is persisted synchronously, then the chain dispatch
      # is fired into the background and the handler responds with
      # 202 Accepted carrying the BE-stamped `user_ts`.
      assert conn.status == 202,
             "fire-and-forget chat dispatch should ack with 202; got #{conn.status} body=#{conn.resp_body}"

      decoded = Jason.decode!(conn.resp_body)

      # The handler is fire-and-forget — its sync response carries
      # the BE-stamped user_ts so the FE can patch its optimistic
      # local copy. Sole load-bearing assertion at this layer.
      assert is_integer(decoded["user_ts"]),
             "expected BE-stamped user_ts in response; got: #{inspect(decoded)}"

      # The user message is persisted to session.messages with the
      # SAME ts. (Fire-and-forget chain spawns asynchronously, but
      # `UserAgentMessages.append` runs synchronously BEFORE the
      # response is sent — so we can read it here.)
      %{rows: [[messages_json]]} =
        query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
          [session_id, user_id])

      messages = Jason.decode!(messages_json || "[]")

      assert length(messages) >= 1,
             "session.messages should hold the just-posted user message; got: #{inspect(messages)}"

      first_msg = List.first(messages)
      assert (first_msg["role"] || first_msg[:role]) == "user"
      assert (first_msg["content"] || first_msg[:content]) =~ "hello, first message"
      assert (first_msg["ts"] || first_msg[:ts]) == decoded["user_ts"],
             "persisted user msg's ts should match the user_ts returned to the FE; " <>
               "msg=#{inspect(first_msg)} response_ts=#{decoded["user_ts"]}"

      # Wait for the queued chain to settle so `on_exit` doesn't
      # race a still-running task. We don't assert on the chain's
      # output here; F01's contract stops at "user message landed."
      :ok = wait_until_idle(user_id, 6_000)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  # `RateLimit` plug keys `/auth/*` on remote_ip; Hammer's bucket
  # persists across tests, so back-to-back runs on the same host
  # fill the 8/min bucket and follow-up tests get 429. Spread
  # traffic across IP buckets via a random-per-request remote_ip
  # in the private 10.x range.
  defp random_ip do
    {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(254)}
  end

  defp post_json(path, body, opts \\ []) do
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:post, path, json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, random_ip())

    conn =
      case Keyword.get(opts, :token) do
        nil -> conn
        tok -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> tok)
      end

    DmhAi.Router.call(conn, DmhAi.Router.init([]))
  end

  defp login_for_token(email, password) do
    conn = post_json("/auth/login", %{"email" => email, "password" => password})
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["token"]
  end

  defp wait_until_idle(user_id, timeout_ms) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_wait_until_idle(user_id, deadline, nil)
  end

  defp do_wait_until_idle(user_id, deadline, idle_since) do
    grace_ms = 200

    cond do
      System.os_time(:millisecond) > deadline ->
        :timeout

      DmhAi.Agent.UserAgent.current_turn_session_id(user_id) != nil ->
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
