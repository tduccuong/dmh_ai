# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03GoogleWorkspaceTest do
  @moduledoc """
  Integration tests for the Google Workspace connector. Same shape as
  the HubSpot / M365 suites — manifest validity, dispatcher
  registration, error remap, end-to-end stubbed call.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.GoogleWorkspace
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(GoogleWorkspace)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "gw-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "oauth:google_workspace", "", "oauth2",
       Jason.encode!(%{"access_token" => "fake-google-token"}),
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
    test "validates clean", do: assert :ok = Manifest.validate(GoogleWorkspace.manifest())

    test "declares 6 verbs across gmail/gcal/drive" do
      verbs = GoogleWorkspace.manifest().verbs
      assert Map.has_key?(verbs, "gmail.send")
      assert Map.has_key?(verbs, "gmail.search")
      assert Map.has_key?(verbs, "gcal.create_event")
      assert Map.has_key?(verbs, "gcal.find_free_slots")
      assert Map.has_key?(verbs, "drive.list")
      assert Map.has_key?(verbs, "drive.upload")
    end

    test "every write is callable_from: [:task] with idempotency_key required" do
      GoogleWorkspace.manifest().verbs
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task], "write verb #{name} must be task-only"
        assert v.idempotency_key == :required
      end)
    end
  end

  describe "error remap" do
    test "RESOURCE_EXHAUSTED → :rate_limited" do
      assert :rate_limited =
               GoogleWorkspace.remap_error(%{"error" => %{"status" => "RESOURCE_EXHAUSTED"}})
    end

    test "NOT_FOUND status → :not_found" do
      assert :not_found =
               GoogleWorkspace.remap_error(%{"error" => %{"status" => "NOT_FOUND"}})
    end

    test "v1 errors[].reason notFound → :not_found" do
      err = %{"error" => %{"errors" => [%{"reason" => "notFound"}]}}
      assert :not_found = GoogleWorkspace.remap_error(err)
    end

    test "PERMISSION_DENIED maps to unauthorised (insufficient OAuth scope)" do
      assert :unauthorised =
               GoogleWorkspace.remap_error(%{"error" => %{"status" => "PERMISSION_DENIED"}})
    end

    test "HTTP 403 catches the case without parsed body" do
      assert :unauthorised = GoogleWorkspace.remap_error({:http, 403, "Forbidden"})
    end

    test "unknown vendor codes fall through to :passthrough" do
      assert :passthrough =
               GoogleWorkspace.remap_error(%{"error" => %{"status" => "WEIRD"}})
    end
  end

  describe "dispatcher end-to-end (stubbed Caller)" do
    test "free-chat gmail.search succeeds without idempotency_key", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "google_workspace", "gmail.search", args, _ ->
        refute Map.has_key?(args, "__idempotency_key"), "reads must not get idempotency_key"
        {:ok, %{"messages" => [%{"subject" => "Test"}]}}
      end)

      assert {:ok, %{"messages" => [%{"subject" => "Test"}]}} =
               Dispatcher.call("google_workspace.gmail.search",
                               %{"query" => "label:inbox"},
                               %{user_id: admin_id})
    end

    test "write outside task → write_requires_task", %{admin_id: admin_id} do
      assert {:error, %{error: "write_requires_task", verb: "google_workspace.gmail.send"}} =
               Dispatcher.call("google_workspace.gmail.send",
                               %{"to" => "alice@example.com",
                                 "subject" => "Hi", "body" => "hello"},
                               %{user_id: admin_id})
    end

    test "write in-task gets idempotency_key", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "google_workspace", "gmail.send", args, _ ->
        assert is_binary(args["__idempotency_key"])
        {:ok, %{"message_id" => "gmsg-1"}}
      end)

      assert {:ok, %{"message_id" => "gmsg-1"}} =
               Dispatcher.call("google_workspace.gmail.send",
                               %{"to" => "alice@example.com",
                                 "subject" => "Hi", "body" => "hello"},
                               %{user_id: admin_id, task_id: "t-1", step_seq: "tc-1"})
    end
  end
end
