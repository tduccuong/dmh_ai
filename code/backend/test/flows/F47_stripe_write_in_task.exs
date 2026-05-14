# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F47 — Stripe write verb succeeds inside task. Includes the
# api_key→Caller hop AND the idempotency_key injection contract.

defmodule DmhAi.Flows.F47StripeWriteInTask do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Stripe, as: StripeConn
  alias DmhAi.Tools.Dispatcher
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F47"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F47")
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

    %{admin_id: admin_id, email: email, password: password, fake_key: fake_key}
  end

  test "POST /tools/execute stripe.payment_intent.create with task_id → success + idempotency_key",
       %{admin_id: admin_id, email: email, password: password, fake_key: fake_key} do
    keys_table = :ets.new(:f47_keys, [:public, :set])

    Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "stripe", "payment_intent.create", args, creds ->
      assert creds["api_key"] == fake_key
      :ets.insert(keys_table, {System.unique_integer([:monotonic]), args["__idempotency_key"]})
      {:ok, %{"payment_intent_id" => "pi_42", "client_secret" => "pi_42_secret"}}
    end)

    token = login_for_token(email, password)

    tool_call_id = "tc-test-" <> T.uid()
    body = %{
      "name"         => "stripe.payment_intent.create",
      "args"         => %{"amount" => 2000, "currency" => "eur"},
      "task_id"      => "task-f47",
      "tool_call_id" => tool_call_id
    }

    conn = post_json("/tools/execute", body, token: token)

    assert conn.status == 200, "execute: #{conn.status} #{conn.resp_body}"
    decoded = Jason.decode!(conn.resp_body)

    assert decoded["ok"] == true
    assert decoded["result"]["payment_intent_id"] == "pi_42"

    [{_, captured_key}] = :ets.tab2list(keys_table)
    expected_key =
      :crypto.hash(:sha256, "task-f47\0#{tool_call_id}\0stripe.payment_intent.create")
      |> Base.encode16(case: :lower)

    assert captured_key == expected_key

    [[action, outcome]] =
      query!(Repo,
             "SELECT action, outcome FROM audit_log WHERE user_id=? ORDER BY id DESC LIMIT 1",
             [admin_id]).rows

    assert action  == "write"
    assert outcome == "allowed"

    {:ok, _} = post_json("/tools/execute", body, token: token)
                |> case do conn -> {:ok, Jason.decode!(conn.resp_body)} end

    keys = :ets.tab2list(keys_table) |> Enum.map(fn {_, k} -> k end)
    assert length(keys) == 2
    assert Enum.uniq(keys) |> length() == 1
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
