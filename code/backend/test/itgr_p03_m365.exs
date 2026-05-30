# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03M365Test do
  @moduledoc """
  Integration tests for the Microsoft 365 connector. Same shape as
  the HubSpot suite — manifest validity, dispatcher registration,
  error remap, end-to-end stubbed call.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.M365
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(M365)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "m365-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "oauth:m365", "", "oauth2",
       Jason.encode!(%{"access_token" => "fake-graph-token"}),
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    {:ok, %{admin_id: admin_id}}
  end

  describe "manifest" do
    test "validates clean", do: assert :ok = Manifest.validate(M365.manifest())

    test "declares 6 functions across mail/cal/files" do
      functions = M365.manifest().functions
      assert Map.has_key?(functions, "mail.send")
      assert Map.has_key?(functions, "mail.search")
      assert Map.has_key?(functions, "cal.create_event")
      assert Map.has_key?(functions, "cal.find_free_slots")
      assert Map.has_key?(functions, "files.list")
      assert Map.has_key?(functions, "files.upload")
    end

    test "every write is callable_from: [:task] with idempotency_key required" do
      M365.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task], "write function #{name} must be task-only"
        assert v.idempotency_key == :required
      end)
    end
  end

  describe "error remap" do
    test "ItemNotFound → :not_found" do
      assert :not_found =
               M365.remap_error(%{"error" => %{"code" => "ItemNotFound", "message" => "no"}})
    end

    test "RateLimited → :rate_limited" do
      assert :rate_limited = M365.remap_error(%{"error" => %{"code" => "RateLimited"}})
    end

    test "InvalidAuthenticationToken → :unauthorised" do
      assert :unauthorised =
               M365.remap_error(%{"error" => %{"code" => "InvalidAuthenticationToken"}})
    end

    test "HTTP 429 passthrough catches the case without parsed body" do
      assert :rate_limited = M365.remap_error({:http, 429, "Retry-After: 30"})
    end

    test "unknown vendor codes fall through to :passthrough" do
      assert :passthrough = M365.remap_error(%{"error" => %{"code" => "WeirdSpecificError"}})
    end
  end

  describe "dispatcher end-to-end (stubbed Caller)" do
    test "free-chat mail.search succeeds without idempotency_key", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "m365", "mail.search", args, _ ->
        refute Map.has_key?(args, "__idempotency_key"), "reads must not get idempotency_key"
        {:ok, %{"messages" => [%{"subject" => "Test"}]}}
      end)

      assert {:ok, %{"messages" => [%{"subject" => "Test"}]}} =
               Dispatcher.call("m365.mail.search", %{"query" => "hello"}, %{user_id: admin_id})
    end

    test "write function (mail.send) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("m365.mail.send",
                               %{"to" => "alice@example.com",
                                 "subject" => "Hi", "body" => "hello"},
                               %{user_id: admin_id})
    end

    test "write in-task gets idempotency_key", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "m365", "mail.send", args, _ ->
        assert is_binary(args["__idempotency_key"])
        {:ok, %{"message_id" => "msg-1"}}
      end)

      assert {:ok, %{"message_id" => "msg-1"}} =
               Dispatcher.call("m365.mail.send",
                               %{"to" => "alice@example.com",
                                 "subject" => "Hi", "body" => "hello"},
                               %{user_id: admin_id, task_id: "t-1", step_seq: "tc-1"})
    end
  end
end
