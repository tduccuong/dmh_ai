# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F46 — Stripe write verb refused outside task.

defmodule DmhAi.Flows.F46StripeWriteRefusal do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Stripe, as: StripeConn
  alias DmhAi.Tools.Dispatcher
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F46"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F46")
    Dispatcher.reset()
    :ok = Dispatcher.register(StripeConn)

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

    fake_key = "sk_" <> "test_" <> "FAKEKEYFORTESTING1234567890"

    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "api_key:stripe", "", "api_key",
       Jason.encode!(%{"api_key" => fake_key}),
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    %{admin_id: admin_id, email: email, password: password}
  end

  test "POST /tools/execute stripe.payment_intent.create WITHOUT task_id → write_requires_task",
       %{admin_id: admin_id, email: email, password: password} do
    Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _, _, _, _ ->
      flunk("Caller must NOT be invoked when dispatcher rejects pre-flight")
    end)

    token = login_for_token(email, password)

    conn = post_json("/tools/execute",
                     %{"name" => "stripe.payment_intent.create",
                       "args" => %{"amount" => 2000, "currency" => "eur"}},
                     token: token)

    assert conn.status == 400
    decoded = Jason.decode!(conn.resp_body)

    assert decoded["ok"] == false
    assert get_in(decoded, ["error", "error"]) == "write_requires_task"
    assert get_in(decoded, ["error", "verb"])  == "stripe.payment_intent.create"

    [[allowed_writes]] =
      query!(Repo, """
      SELECT COUNT(*) FROM audit_log
       WHERE user_id=? AND action='write' AND outcome='allowed'
      """, [admin_id]).rows

    assert allowed_writes == 0
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
