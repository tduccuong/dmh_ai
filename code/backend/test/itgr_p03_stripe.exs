# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03StripeTest do
  @moduledoc """
  Integration tests for the Stripe connector. First Case-B connector
  that auth'd via api_key rather than OAuth — exercises the
  `MCPAdapter.Caller` api_key branch.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Stripe, as: StripeConn
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(StripeConn)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "stripe-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    # api_key credential — built at runtime from short literals so no
    # single string in source looks like a real secret (CLAUDE rule 13).
    fake_key = "sk_" <> "test_" <> "FAKEKEYFORTESTING1234567890"

    query!(Repo,
      "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "api_key:stripe", "", "api_key",
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
    test "validates clean", do: assert :ok = Manifest.validate(StripeConn.manifest())

    test "declares 6 functions across customer/payment_intent/refund/subscription/product" do
      functions = StripeConn.manifest().functions
      assert Map.has_key?(functions, "customer.find")
      assert Map.has_key?(functions, "customer.create")
      assert Map.has_key?(functions, "payment_intent.create")
      assert Map.has_key?(functions, "refund.create")
      assert Map.has_key?(functions, "subscription.find")
      assert Map.has_key?(functions, "product.find")
    end

    test "every write is callable_from: [:task] with idempotency_key required" do
      StripeConn.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task], "write function #{name} must be task-only"
        assert v.idempotency_key == :required
      end)
    end

    test "credential_kind is :api_key (not OAuth2)" do
      assert StripeConn.credential_kind() == :api_key
    end
  end

  describe "error remap" do
    test "rate_limit_error → :rate_limited" do
      assert :rate_limited =
               StripeConn.remap_error(%{"error" => %{"type" => "rate_limit_error"}})
    end

    test "authentication_error → :unauthorised" do
      assert :unauthorised =
               StripeConn.remap_error(%{"error" => %{"type" => "authentication_error"}})
    end

    test "resource_missing code → :not_found" do
      assert :not_found =
               StripeConn.remap_error(%{"error" => %{"code" => "resource_missing"}})
    end

    test "idempotency_key_in_use → :duplicate" do
      assert :duplicate =
               StripeConn.remap_error(%{"error" => %{"code" => "idempotency_key_in_use"}})
    end

    test "HTTP 429 catches the case without parsed body" do
      assert :rate_limited = StripeConn.remap_error({:http, 429, "Too Many Requests"})
    end
  end

  describe "dispatcher end-to-end (stubbed Caller, api_key creds)" do
    test "free-chat customer.find pulls api_key credential, not oauth", %{admin_id: admin_id, fake_key: fake_key} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "stripe", "customer.find", _args, creds ->
        # Caller hands the api_key map to the underlying transport.
        assert creds["api_key"] == fake_key
        {:ok, %{"customers" => [%{"id" => "cus_001", "email" => "x@y.test"}]}}
      end)

      assert {:ok, %{"customers" => [%{"id" => "cus_001"}]}} =
               Dispatcher.call("stripe.customer.find",
                               %{"email" => "x@y.test"},
                               %{user_id: admin_id})
    end

    test "payment_intent.create outside task → write_requires_task", %{admin_id: admin_id} do
      assert {:error, %{error: "write_requires_task", function: "stripe.payment_intent.create"}} =
               Dispatcher.call("stripe.payment_intent.create",
                               %{"amount" => 2000, "currency" => "eur"},
                               %{user_id: admin_id})
    end

    test "payment_intent.create in-task gets idempotency_key", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "stripe", "payment_intent.create", args, _creds ->
        assert is_binary(args["__idempotency_key"])
        {:ok, %{"payment_intent_id" => "pi_001", "client_secret" => "pi_001_secret"}}
      end)

      assert {:ok, %{"payment_intent_id" => "pi_001"}} =
               Dispatcher.call("stripe.payment_intent.create",
                               %{"amount" => 2000, "currency" => "eur"},
                               %{user_id: admin_id, task_id: "t-1", step_seq: "tc-1"})
    end
  end
end
