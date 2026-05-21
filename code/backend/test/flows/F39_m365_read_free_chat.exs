# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F39 — Microsoft 365 read verb e2e via POST /tools/execute.
#
# Mirrors F36's contract for the M365 connector: `mail.search` is
# callable from free chat (no task_id), the dispatcher does NOT
# inject an idempotency_key on reads, and no audit_log denial fires.

defmodule DmhAi.Flows.F39M365ReadFreeChat do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.M365
  alias DmhAi.Tools.Dispatcher
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F39"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F39")
    Dispatcher.reset()
    :ok = Dispatcher.register(M365)

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      teardown.()
    end)

    :ok
  end

  setup do
    admin_id = T.uid()
    email    = "u-#{admin_id}@test.local" |> String.downcase()
    password = "p-#{admin_id}"

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, email, "Admin", "user", DmhAi.AuthPlug.hash_password(password), 1,
       DmhAi.Constants.default_org_id(), "admin",
       System.os_time(:millisecond)])

    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "oauth:m365", "", "oauth2",
       Jason.encode!(%{"access_token" => "fake-graph-token"}),
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    %{admin_id: admin_id, email: email, password: password}
  end

  test "POST /tools/execute m365.mail.search (read, free chat) → 200 with messages",
       %{admin_id: admin_id, email: email, password: password} do
    Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "m365", "mail.search", args, _creds ->
      refute Map.has_key?(args, "__idempotency_key"),
             "read verbs MUST NOT carry an injected idempotency_key"
      assert args["query"] == "invoice"

      {:ok, %{"messages" => [%{"id" => "m-001", "subject" => "Invoice draft", "from" => "ops@acme.test"}]}}
    end)

    token = login_for_token(email, password)

    conn = post_json("/tools/execute",
                     %{"name" => "m365.mail.search",
                       "args" => %{"query" => "invoice"}},
                     token: token)

    assert conn.status == 200, "execute: #{conn.status} #{conn.resp_body}"
    decoded = Jason.decode!(conn.resp_body)

    assert decoded["ok"] == true
    assert get_in(decoded, ["result", "messages"]) |> is_list()
    assert hd(decoded["result"]["messages"])["id"] == "m-001"

    [[denied_count]] =
      query!(Repo, "SELECT COUNT(*) FROM audit_log WHERE user_id=? AND outcome='denied'",
             [admin_id]).rows

    assert denied_count == 0
  end

  defp random_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(254)}

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
end
