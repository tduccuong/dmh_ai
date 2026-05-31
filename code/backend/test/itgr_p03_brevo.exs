# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03BrevoTest do
  @moduledoc """
  Integration tests for the Brevo connector. Third Case-B connector
  that auth's via api_key rather than OAuth (after Stripe and Klaviyo) —
  exercises the `MCPAdapter.Caller` api_key branch a third time and
  pins the Brevo-specific flat-error remap (vendor returns
  `%{"code" => ..., "message" => ...}` rather than the JSON:API
  `errors[]` envelope Klaviyo uses).
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Brevo, as: BrevoConn
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(BrevoConn)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "brevo-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    # api_key credential — built at runtime from short literals so no
    # single string in source looks like a real secret.
    fake_key = "xkeysib-" <> "FAKEKEYFORTESTING" <> "1234567890abcdef"

    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "api_key:brevo", "", "api_key",
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
    test "validates clean", do: assert :ok = Manifest.validate(BrevoConn.manifest())

    test "region is universal" do
      assert BrevoConn.manifest().region == "universal"
    end

    test "declares 14 functions across contact/email/list/template/campaign/event" do
      functions = BrevoConn.manifest().functions
      assert map_size(functions) == 14

      # Original 6
      assert Map.has_key?(functions, "contact.find")
      assert Map.has_key?(functions, "contact.create")
      assert Map.has_key?(functions, "contact.update")
      assert Map.has_key?(functions, "email.send")
      assert Map.has_key?(functions, "list.find")
      assert Map.has_key?(functions, "list.create")

      # +8 from the Brevo expansion
      assert Map.has_key?(functions, "contact.delete")
      assert Map.has_key?(functions, "contact.add_to_list")
      assert Map.has_key?(functions, "contact.remove_from_list")
      assert Map.has_key?(functions, "email.send_template")
      assert Map.has_key?(functions, "template.find")
      assert Map.has_key?(functions, "campaign.find")
      assert Map.has_key?(functions, "campaign.create")
      assert Map.has_key?(functions, "transactional.event.find")
    end

    test "every write is callable_from: [:task] with idempotency_key required" do
      BrevoConn.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task], "write function #{name} must be task-only"
        assert v.idempotency_key == :required
      end)
    end

    test "credential_kind is :api_key (not OAuth2)" do
      assert BrevoConn.credential_kind() == :api_key
    end
  end

  describe "error remap" do
    test "duplicate_parameter code → :duplicate" do
      assert :duplicate =
               BrevoConn.remap_error(%{"code" => "duplicate_parameter",
                                       "message" => "Contact already exists"})
    end

    test "duplicate_request code → :duplicate" do
      assert :duplicate = BrevoConn.remap_error(%{"code" => "duplicate_request"})
    end

    test "unauthorized code → :unauthorised" do
      assert :unauthorised = BrevoConn.remap_error(%{"code" => "unauthorized"})
    end

    test "invalid_parameter code → :unauthorised" do
      assert :unauthorised = BrevoConn.remap_error(%{"code" => "invalid_parameter"})
    end

    test "document_not_found code → :not_found" do
      assert :not_found = BrevoConn.remap_error(%{"code" => "document_not_found"})
    end

    test "contact_not_found code → :not_found" do
      assert :not_found = BrevoConn.remap_error(%{"code" => "contact_not_found"})
    end

    test "too_many_requests code → :rate_limited" do
      assert :rate_limited = BrevoConn.remap_error(%{"code" => "too_many_requests"})
    end

    test "unknown code → :passthrough (so generic HTTP-status logic runs)" do
      assert :passthrough =
               BrevoConn.remap_error(%{"code" => "something_we_dont_map"})
    end

    test "HTTP 401 → :unauthorised" do
      assert :unauthorised = BrevoConn.remap_error({:http, 401, "Unauthorized"})
    end

    test "HTTP 403 → :unauthorised" do
      assert :unauthorised = BrevoConn.remap_error({:http, 403, "Forbidden"})
    end

    test "HTTP 404 → :not_found" do
      assert :not_found = BrevoConn.remap_error({:http, 404, "Not Found"})
    end

    test "HTTP 429 → :rate_limited" do
      assert :rate_limited = BrevoConn.remap_error({:http, 429, "Too Many Requests"})
    end

    test "HTTP 400 with body mentioning 'duplicate' → :duplicate" do
      assert :duplicate =
               BrevoConn.remap_error({:http, 400, "Contact is a duplicate of an existing record."})
    end

    test "HTTP 409 with body mentioning 'duplicate' → :duplicate" do
      assert :duplicate =
               BrevoConn.remap_error({:http, 409, "Conflict: duplicate email."})
    end

    test "HTTP 400 without duplicate prose → :passthrough" do
      assert :passthrough =
               BrevoConn.remap_error({:http, 400, "Missing required parameter"})
    end

    test "unrecognised term → :passthrough" do
      assert :passthrough = BrevoConn.remap_error(:something_else)
    end
  end

  describe "dispatcher registration" do
    test "register/1 succeeds (manifest validates + ETS entry inserted)" do
      Dispatcher.reset()
      assert :ok = Dispatcher.register(BrevoConn)
      assert {:ok, %{module: BrevoConn}} = Dispatcher.lookup("brevo")
    end
  end

  describe "dispatcher end-to-end (stubbed Caller, api_key creds)" do
    test "free-chat contact.find pulls api_key credential, not oauth",
         %{admin_id: admin_id, fake_key: fake_key} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "brevo", "contact.find", _args, creds ->
        # Caller hands the api_key map to the underlying transport.
        assert creds["api_key"] == fake_key
        {:ok, %{"contacts" => [%{"id" => 1_900_002, "email" => "x@y.test"}]}}
      end)

      assert {:ok, %{"contacts" => [%{"id" => 1_900_002}]}} =
               Dispatcher.call("brevo.contact.find",
                               %{"email" => "x@y.test"},
                               %{user_id: admin_id})
    end

    test "contact.create without stub surfaces a structured error envelope",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` installed AND no real MCP server reachable
      # → the Caller's real-transport path fails and the adapter normalises
      # whatever it gets back into a typed envelope. The exact class isn't
      # the point; what matters is that the dispatcher SURFACES an error
      # envelope rather than crashing or returning {:ok, ...}.
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)

      assert {:error, %{error: err}} =
               Dispatcher.call("brevo.contact.create",
                               %{"email" => "x@y.test"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})

      assert is_binary(err)
      assert err != ""
    end

    test "contact.create in-task gets idempotency_key", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "brevo", "contact.create", args, _creds ->
        assert is_binary(args["__idempotency_key"])
        {:ok, %{"contact_id" => "1900003"}}
      end)

      assert {:ok, %{"contact_id" => "1900003"}} =
               Dispatcher.call("brevo.contact.create",
                               %{"email" => "x@y.test",
                                 "attributes" => %{"FIRSTNAME" => "X"}},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end

    test "email.send in-task gets idempotency_key and carries args through",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "brevo", "email.send", args, _creds ->
        assert is_binary(args["__idempotency_key"])
        assert args["subject"] == "Order confirmation"
        assert args["to"] == [%{"email" => "x@y.test"}]
        {:ok, %{"message_id" => "<msg-x@brevo.test>"}}
      end)

      assert {:ok, %{"message_id" => "<msg-x@brevo.test>"}} =
               Dispatcher.call("brevo.email.send",
                               %{"to" => [%{"email" => "x@y.test"}],
                                 "subject" => "Order confirmation"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end

    test "vendor flat error → canonical envelope via remap_error",
         %{admin_id: admin_id} do
      # Stub returns the Brevo-shaped flat error body. The adapter
      # pipes it through `remap_error/1` (→ :duplicate) and
      # ErrorNormalizer envelopes it as `%{error: "duplicate"}`.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "brevo", "contact.create", _args, _creds ->
        {:error, %{"code" => "duplicate_parameter",
                   "message" => "Contact already exists with this email."}}
      end)

      assert {:error, %{error: "duplicate"}} =
               Dispatcher.call("brevo.contact.create",
                               %{"email" => "x@y.test"},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end

    test "read function (template.find) from free chat returns the inner templates list",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "brevo", "template.find", args, _creds ->
          assert args["limit"] == 25

          {:ok,
           %{"templates" => [%{"id" => 200_001, "name" => "Beispiel-Template Demo"}]}}
        end)

      assert {:ok, %{"templates" => [%{"id" => 200_001}]}} =
               Dispatcher.call("brevo.template.find",
                               %{"limit" => 25},
                               %{user_id: admin_id})
    end

    test "write function (contact.add_to_list) in-task carries injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "brevo", "contact.add_to_list", args, _creds ->
          assert is_binary(args["__idempotency_key"]),
                 "writes must carry idempotency_key injected by Dispatcher"
          assert args["list_id"] == 90_001
          assert args["emails"] == ["x@y.test", "z@y.test"]

          {:ok, %{"contacts_added" => 2}}
        end)

      assert {:ok, %{"contacts_added" => 2}} =
               Dispatcher.call("brevo.contact.add_to_list",
                               %{"list_id" => 90_001,
                                 "emails"  => ["x@y.test", "z@y.test"]},
                               %{user_id: admin_id, session_id: "s-1", step_seq: "step-1"})
    end
  end

  describe "inspect_property/3 — Layer B reader" do
    # Fixture rows mirror what `discover_metadata/1` writes — one row per
    # cache path. The `path` + `schema` shape matches the runtime caller's
    # `ctx[:vendor_metadata]` payload (see InspectFunctionProperty).
    setup do
      attributes_row = %{
        path: "contacts.attributes",
        schema: %{
          "object_type" => "contacts.attributes",
          "properties"  => [
            %{"name" => "FIRSTNAME", "type" => "text", "category" => "normal"},
            %{"name" => "LASTNAME",  "type" => "text", "category" => "normal"},
            %{"name" => "PREF",
              "type" => "category",
              "category" => "category",
              "options" => [
                %{"value" => 1, "label" => "Newsletter"},
                %{"value" => 2, "label" => "Promotions"}
              ]}
          ]
        }
      }

      lists_row = %{
        path: "contacts.lists",
        schema: %{
          "object_type" => "contacts.lists",
          "properties"  => [
            %{"name" => "list_id", "type" => "integer", "options" => [
              %{"value" => 12, "label" => "Newsletter"},
              %{"value" => 17, "label" => "VIP"}
            ]}
          ]
        }
      }

      {:ok, %{attributes_row: attributes_row, lists_row: lists_row}}
    end

    test "contact.create with dotted path resolves attribute from cache",
         %{attributes_row: attributes_row} do
      assert {:ok, %{type: "text", source: :vendor_metadata}} =
               BrevoConn.inspect_property(
                 "contact.create",
                 "attributes.FIRSTNAME",
                 %{vendor_metadata: [attributes_row]})
    end

    test "contact.update with bare attribute name resolves the same row",
         %{attributes_row: attributes_row} do
      assert {:ok, %{type: "text", source: :vendor_metadata}} =
               BrevoConn.inspect_property(
                 "contact.update",
                 "FIRSTNAME",
                 %{vendor_metadata: [attributes_row]})
    end

    test "category attribute returns its enumeration as the enum list",
         %{attributes_row: attributes_row} do
      assert {:ok, %{type: "category", enum: enum, source: :vendor_metadata}} =
               BrevoConn.inspect_property(
                 "contact.create",
                 "attributes.PREF",
                 %{vendor_metadata: [attributes_row]})

      assert enum == [1, 2]
    end

    test "contact.add_to_list resolves list_id with the lists enum",
         %{lists_row: lists_row} do
      assert {:ok, %{type: "integer", enum: enum, source: :vendor_metadata}} =
               BrevoConn.inspect_property(
                 "contact.add_to_list",
                 "list_id",
                 %{vendor_metadata: [lists_row]})

      assert enum == [12, 17]
    end

    test "contact.remove_from_list shares the lists cache row",
         %{lists_row: lists_row} do
      assert {:ok, %{type: "integer", source: :vendor_metadata}} =
               BrevoConn.inspect_property(
                 "contact.remove_from_list",
                 "list_id",
                 %{vendor_metadata: [lists_row]})
    end

    test "cache miss returns :not_supported", %{attributes_row: attributes_row} do
      assert {:error, :not_supported} =
               BrevoConn.inspect_property(
                 "contact.create",
                 "attributes.NONEXISTENT",
                 %{vendor_metadata: [attributes_row]})
    end

    test "function not in @function_to_cache returns :not_supported" do
      assert {:error, :not_supported} =
               BrevoConn.inspect_property(
                 "email.send",
                 "subject",
                 %{vendor_metadata: []})
    end

    test "empty vendor_metadata returns :not_supported" do
      assert {:error, :not_supported} =
               BrevoConn.inspect_property(
                 "contact.create",
                 "attributes.FIRSTNAME",
                 %{vendor_metadata: []})
    end
  end
end
