# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F30 — `/index` admin-only e2e (Primitive 0.2).
#
# Exercises the full chain:
#   POST /agent/chat with content="/index ..."
#     → Router → AgentChat handler
#     → Commands.dispatch → run_index → admin? check
#     → Permissions.can?(uid, :write_settings, "org_settings")
#
# Asserts:
#   * Non-admin gets a refusal ack persisted under kind="command_ack".
#   * `audit_log` gains a `denied` row with reason='index_admin_only'.
#   * No kb_sources row gets created (the refusal short-circuits before
#     any pipeline runs).

defmodule DmhAi.Flows.F30IndexAdminOnly do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F30"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F30")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id  = T.uid()
    email    = "u-#{user_id}@test.local" |> String.downcase()
    password = "p-#{user_id}"
    password_hash = DmhAi.AuthPlug.hash_password(password)

    # NON-admin member of the default org.
    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "Member User", "user", password_hash, 1,
       DmhAi.Constants.default_org_id(), "member",
       System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM session_progress WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, email: email, password: password}
  end

  test "non-admin /index → refusal ack + audit_log denial row",
       %{user_id: user_id, email: email, password: password} do
    token = login_for_token(email, password)
    session_id = T.uid()

    {:ok, _} =
      post_json("/sessions", %{"id" => session_id}, token: token)
      |> assert_ok()

    conn =
      post_json("/agent/chat",
                %{"sessionId" => session_id, "content" => "/index some inline text body"},
                token: token)

    assert conn.status == 200,
           "POST /agent/chat with /index for non-admin: expected 200, got #{conn.status} body=#{conn.resp_body}"

    decoded = Jason.decode!(conn.resp_body)
    assert decoded["handled"] == true, "expected handled=true; got #{inspect(decoded)}"

    # The refusal ack is persisted as a `kind: "command_ack"` row in
    # the session's messages JSON. Pull it back and check the text.
    [[messages_json]] =
      query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id]).rows

    messages = Jason.decode!(messages_json || "[]")

    ack =
      Enum.find(messages, fn m ->
        m["kind"] == "command_ack" and m["role"] == "assistant"
      end)

    assert ack, "expected a command_ack row in session messages; got #{inspect(messages)}"
    assert ack["content"] =~ "admin",
           "expected refusal ack to mention admin restriction; got #{inspect(ack["content"])}"

    # No kb_sources row was created.
    [[kb_count]] =
      query!(Repo, "SELECT COUNT(*) FROM kb_sources WHERE created_by_user_id=?", [user_id]).rows

    assert kb_count == 0,
           "non-admin /index must not create a kb_sources row; found #{kb_count}"

    # An audit_log denial row exists for this user.
    [[audit_n]] =
      query!(Repo, """
      SELECT COUNT(*) FROM audit_log
       WHERE user_id=? AND outcome='denied' AND reason='index_admin_only'
      """, [user_id]).rows

    assert audit_n >= 1,
           "expected at least one denied audit_log row with reason='index_admin_only'; got #{audit_n}"
  end

  # ─── HTTP helpers (copied from F01) ──────────────────────────────────────

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
    assert conn.status == 200, "login failed: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)["token"]
  end

  defp assert_ok(conn) do
    case conn.status do
      s when s in 200..299 -> {:ok, Jason.decode!(conn.resp_body)}
      _ -> flunk("expected 2xx, got #{conn.status}: #{conn.resp_body}")
    end
  end
end
