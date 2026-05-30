# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03KlaviyoTest do
  @moduledoc """
  Integration tests for the Klaviyo connector. Second Case-B connector
  that auth's via api_key rather than OAuth (after Stripe) — exercises
  the `MCPAdapter.Caller` api_key branch a second time and pins the
  Klaviyo-specific JSON:API error remap.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Klaviyo, as: KlaviyoConn
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(KlaviyoConn)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "klaviyo-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    # api_key credential — built at runtime from short literals so no
    # single string in source looks like a real secret (CLAUDE rule 13).
    fake_key = "pk_" <> "test_" <> "FAKEKEYFORTESTING1234567890"

    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "api_key:klaviyo", "", "api_key",
       Jason.encode!(%{"api_key" => fake_key}),
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    {:ok, %{admin_id: admin_id, fake_key: fake_key}}
  end

  describe "manifest" do
    test "validates clean", do: assert :ok = Manifest.validate(KlaviyoConn.manifest())

    test "region is universal" do
      assert KlaviyoConn.manifest().region == "universal"
    end

    test "declares 14 functions across profile/event/list/campaign/segment/flow/template/metric" do
      functions = KlaviyoConn.manifest().functions
      assert map_size(functions) == 14

      # Original 6
      assert Map.has_key?(functions, "profile.find")
      assert Map.has_key?(functions, "profile.create")
      assert Map.has_key?(functions, "profile.update")
      assert Map.has_key?(functions, "event.create")
      assert Map.has_key?(functions, "list.find")
      assert Map.has_key?(functions, "campaign.find")

      # +8 from the Klaviyo expansion
      assert Map.has_key?(functions, "list.create")
      assert Map.has_key?(functions, "list.add_profile")
      assert Map.has_key?(functions, "list.remove_profile")
      assert Map.has_key?(functions, "segment.find")
      assert Map.has_key?(functions, "flow.find")
      assert Map.has_key?(functions, "template.find")
      assert Map.has_key?(functions, "metric.find")
      assert Map.has_key?(functions, "event.find")
    end

    test "every write is callable_from: [:task] with idempotency_key required" do
      KlaviyoConn.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task], "write function #{name} must be task-only"
        assert v.idempotency_key == :required
      end)
    end

    test "credential_kind is :api_key (not OAuth2)" do
      assert KlaviyoConn.credential_kind() == :api_key
    end
  end

  describe "error remap" do
    test "duplicate_profile code → :duplicate" do
      assert :duplicate =
               KlaviyoConn.remap_error(%{
                 "errors" => [%{"code" => "duplicate_profile",
                                "title" => "Conflict",
                                "detail" => "A profile with this email exists."}]
               })
    end

    test "email_already_subscribed code → :duplicate" do
      assert :duplicate =
               KlaviyoConn.remap_error(%{"errors" => [%{"code" => "email_already_subscribed"}]})
    end

    test "not_authenticated code → :unauthorised" do
      assert :unauthorised =
               KlaviyoConn.remap_error(%{"errors" => [%{"code" => "not_authenticated"}]})
    end

    test "invalid_api_key code → :unauthorised" do
      assert :unauthorised =
               KlaviyoConn.remap_error(%{"errors" => [%{"code" => "invalid_api_key"}]})
    end

    test "resource_not_found code → :not_found" do
      assert :not_found =
               KlaviyoConn.remap_error(%{"errors" => [%{"code" => "resource_not_found"}]})
    end

    test "rate_limit_exceeded code → :rate_limited" do
      assert :rate_limited =
               KlaviyoConn.remap_error(%{"errors" => [%{"code" => "rate_limit_exceeded"}]})
    end

    test "throttled code → :rate_limited" do
      assert :rate_limited =
               KlaviyoConn.remap_error(%{"errors" => [%{"code" => "throttled"}]})
    end

    test "unknown code → :passthrough (so generic HTTP-status logic runs)" do
      assert :passthrough =
               KlaviyoConn.remap_error(%{"errors" => [%{"code" => "something_we_dont_map"}]})
    end

    test "HTTP 401 → :unauthorised" do
      assert :unauthorised = KlaviyoConn.remap_error({:http, 401, "Unauthorized"})
    end

    test "HTTP 403 → :unauthorised" do
      assert :unauthorised = KlaviyoConn.remap_error({:http, 403, "Forbidden"})
    end

    test "HTTP 404 → :not_found" do
      assert :not_found = KlaviyoConn.remap_error({:http, 404, "Not Found"})
    end

    test "HTTP 409 → :duplicate" do
      assert :duplicate = KlaviyoConn.remap_error({:http, 409, "Conflict"})
    end

    test "HTTP 429 → :rate_limited" do
      assert :rate_limited = KlaviyoConn.remap_error({:http, 429, "Too Many Requests"})
    end

    test "unrecognised term → :passthrough" do
      assert :passthrough = KlaviyoConn.remap_error(:something_else)
    end
  end

  describe "dispatcher registration" do
    test "register/1 succeeds (manifest validates + ETS entry inserted)" do
      Dispatcher.reset()
      assert :ok = Dispatcher.register(KlaviyoConn)
      assert {:ok, %{module: KlaviyoConn}} = Dispatcher.lookup("klaviyo")
    end
  end

  describe "dispatcher end-to-end (stubbed Caller, api_key creds)" do
    test "free-chat profile.find pulls api_key credential, not oauth",
         %{admin_id: admin_id, fake_key: fake_key} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "klaviyo", "profile.find", _args, creds ->
        # Caller hands the api_key map to the underlying transport.
        assert creds["api_key"] == fake_key
        {:ok, %{"profiles" => [%{"id" => "01PROFILEX", "email" => "x@y.test"}]}}
      end)

      assert {:ok, %{"profiles" => [%{"id" => "01PROFILEX"}]}} =
               Dispatcher.call("klaviyo.profile.find",
                               %{"email" => "x@y.test"},
                               %{user_id: admin_id})
    end

    test "profile.create without stub surfaces a structured error envelope",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` installed AND no real MCP server reachable
      # → the Caller's real-transport path fails and the adapter normalises
      # whatever it gets back into a typed envelope. The exact class isn't
      # the point; what matters is that the dispatcher SURFACES an error
      # envelope rather than crashing or returning {:ok, ...}.
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)

      assert {:error, %{error: err}} =
               Dispatcher.call("klaviyo.profile.create",
                               %{"email" => "x@y.test"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})

      assert is_binary(err)
      assert err != ""
    end

    test "profile.create in-task gets idempotency_key", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "klaviyo", "profile.create", args, _creds ->
        assert is_binary(args["__idempotency_key"])
        {:ok, %{"profile_id" => "01PROFILECREATED01"}}
      end)

      assert {:ok, %{"profile_id" => "01PROFILECREATED01"}} =
               Dispatcher.call("klaviyo.profile.create",
                               %{"email" => "x@y.test", "first_name" => "X"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end

    test "event.create in-task gets idempotency_key and carries args through",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "klaviyo", "event.create", args, _creds ->
        assert is_binary(args["__idempotency_key"])
        assert args["event_name"] == "Order Placed"
        assert args["profile_email"] == "x@y.test"
        {:ok, %{"event_id" => "01EVENTCREATED001"}}
      end)

      assert {:ok, %{"event_id" => "01EVENTCREATED001"}} =
               Dispatcher.call("klaviyo.event.create",
                               %{"event_name" => "Order Placed",
                                 "profile_email" => "x@y.test"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end

    test "vendor JSON:API error → canonical envelope via remap_error",
         %{admin_id: admin_id} do
      # Stub returns the Klaviyo-shaped JSON:API error body. The
      # adapter pipes it through `remap_error/1` (→ :duplicate) and
      # ErrorNormalizer envelopes it as `%{error: "duplicate"}`.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "klaviyo", "profile.create", _args, _creds ->
        {:error, %{"errors" => [%{"code" => "duplicate_profile",
                                    "title" => "Conflict",
                                    "detail" => "Profile exists.",
                                    "status" => 409}]}}
      end)

      assert {:error, %{error: "duplicate"}} =
               Dispatcher.call("klaviyo.profile.create",
                               %{"email" => "x@y.test"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end

    test "read function (metric.find) from free chat returns the inner metrics list",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "klaviyo", "metric.find", args, _creds ->
          assert args["limit"] == 25

          {:ok,
           %{"metrics" => [%{"id" => "MOCKMETRIC001", "name" => "Placed Order"}]}}
        end)

      assert {:ok, %{"metrics" => [%{"id" => "MOCKMETRIC001"}]}} =
               Dispatcher.call("klaviyo.metric.find",
                               %{"limit" => 25},
                               %{user_id: admin_id})
    end

    test "write function (list.create) in-task carries injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "klaviyo", "list.create", args, _creds ->
          assert is_binary(args["__idempotency_key"]),
                 "writes must carry idempotency_key injected by Dispatcher"
          assert args["name"] == "Newsletter Subscribers DE"

          {:ok, %{"list_id" => "MOCKLIST002"}}
        end)

      assert {:ok, %{"list_id" => "MOCKLIST002"}} =
               Dispatcher.call("klaviyo.list.create",
                               %{"name" => "Newsletter Subscribers DE"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end
  end
end
