# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F37 — HubSpot write verb refused outside an active task (HARD Rule 2).
#
# POST /tools/execute with hubspot.deal.create and NO task_id in the
# body. The full chain enforces the gate:
#
#   Router → Tools.handler → Registry.execute → Dispatcher
#     → check_callable_from finds [:task] only and no active task_id
#     → returns write_requires_task envelope, never reaches the MCP caller.
#
# Asserts:
#   * HTTP 400 with the canonical envelope shape.
#   * MCP Caller stub is NEVER invoked.
#   * No audit_log row for an allowed write (it never happened).

defmodule DmhAi.Flows.F37HubspotWriteRefusal do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.HubSpot
  alias DmhAi.Tools.Dispatcher
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F37"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F37")
    Dispatcher.reset()
    :ok = Dispatcher.register(HubSpot)

    Process.register(self(), :f37_observer)
    Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _, _, _, _ ->
      send(:f37_observer, :caller_invoked)
      {:ok, %{}}
    end)

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      if Process.whereis(:f37_observer), do: Process.unregister(:f37_observer)
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
      [admin_id, "oauth:hubspot", "", "oauth2",
       Jason.encode!(%{"access_token" => "fake"}),
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    %{admin_id: admin_id, email: email, password: password}
  end

  test "POST /tools/execute hubspot.deal.create with NO task_id → write_requires_task",
       %{admin_id: admin_id, email: email, password: password} do
    token = login_for_token(email, password)

    conn = post_json("/tools/execute",
                     %{"name" => "hubspot.deal.create",
                       "args" => %{"contact_id" => "c-1", "amount" => 5000}},
                     token: token)

    assert conn.status == 400, "execute: #{conn.status} #{conn.resp_body}"
    decoded = Jason.decode!(conn.resp_body)

    assert decoded["ok"] == false
    err = decoded["error"]
    assert err["error"] == "write_requires_task"
    assert err["function"] == "hubspot.deal.create"
    assert is_binary(err["hint"])

    refute_received :caller_invoked, "MCP caller MUST NOT be invoked when gate refuses"

    # No allowed-write audit row (the only audit row, if any, would
    # be from the dispatcher's down-stack permission_denied path —
    # which doesn't fire here because callable_from runs first).
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
