# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03ShopifyTest do
  @moduledoc """
  Integration tests for the Shopify connector (Universal Region,
  Case B). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific error remap: HTTP 422 "has already been taken"
      → canonical `:duplicate`.
    * The connector resolves via dispatcher namespace `shopify.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Shopify
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Shopify)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "shop-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    {:ok, %{admin_id: admin_id}}
  end

  describe "manifest" do
    test "validates clean" do
      assert :ok = Manifest.validate(Shopify.manifest())
    end

    test "declares 9 functions at the Primitive 0.3 surface" do
      functions = Shopify.manifest().functions

      assert Map.has_key?(functions, "product.find")
      assert Map.has_key?(functions, "product.create")
      assert Map.has_key?(functions, "product.update")
      assert Map.has_key?(functions, "order.find")
      assert Map.has_key?(functions, "order.fulfill")
      assert Map.has_key?(functions, "customer.find")
      assert Map.has_key?(functions, "customer.create")
      assert Map.has_key?(functions, "inventory.adjust")
      assert Map.has_key?(functions, "draft_order.create")
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Shopify.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "region tag is `universal`" do
      assert Shopify.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "shopify" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Shopify" do
      assert Shopify in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "error remap" do
    test "Shopify's `errors` map with 'has already been taken' maps to :duplicate" do
      assert :duplicate =
               Shopify.remap_error(%{"errors" => %{"email" => ["has already been taken"]}})
    end

    test "HTTP 422 with 'has already been taken' body maps to :duplicate" do
      assert :duplicate =
               Shopify.remap_error({:http, 422, ~s({"errors":{"email":["has already been taken"]}})})
    end

    test "unrelated errors fall through to :passthrough" do
      assert :passthrough = Shopify.remap_error({:http, 500, "boom"})
      assert :passthrough = Shopify.remap_error({:http, 422, ~s({"errors":{"price":["is not a number"]}})})
      assert :passthrough = Shopify.remap_error(%{"errors" => %{"price" => ["is not a number"]}})
    end

    test "auth / not-found / rate-limit statuses map to canonical classes" do
      assert :unauthorised = Shopify.remap_error({:http, 401, "x"})
      assert :unauthorised = Shopify.remap_error({:http, 403, "x"})
      assert :not_found    = Shopify.remap_error({:http, 404, "x"})
      assert :rate_limited = Shopify.remap_error({:http, 429, "x"})
    end
  end

  describe "dispatcher → Shopify end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:shopify", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-shopify-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (product.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "shopify", "product.find", args, _creds ->
        assert args["query"] == "hoodie"
        {:ok, %{"products" => [%{"id" => "p-1", "title" => "Hoodie"}]}}
      end)

      assert {:ok, %{"products" => [%{"id" => "p-1"}]}} =
               Dispatcher.call("shopify.product.find",
                               %{"query" => "hoodie"},
                               %{user_id: admin_id})
    end

    test "write function (product.create) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("shopify.product.create",
                               %{"title" => "New product"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "shopify", "product.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"product_id" => "p-42"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-product", step_seq: 0}

      assert {:ok, %{"product_id" => "p-42"}} =
               Dispatcher.call("shopify.product.create",
                               %{"title" => "New product"},
                               ctx)
    end

    test "duplicate-email collision surfaces as canonical :duplicate envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "shopify", "customer.create", _args, _creds ->
        {:error, %{"errors" => %{"email" => ["has already been taken"]}}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-dup", step_seq: 0}

      assert {:error, %{error: "duplicate"}} =
               Dispatcher.call("shopify.customer.create",
                               %{"email" => "existing@beispiel.de", "first_name" => "Existing"},
                               ctx)
    end
  end
end
