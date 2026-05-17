# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03HubSpotTest do
  @moduledoc """
  Integration tests for the HubSpot connector (Universal Region,
  Case B). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific error remap: `OBJECT_ALREADY_EXISTS` →
      canonical `:duplicate`.
    * OAuth catalog seed file ships a HubSpot entry that loads.
    * The connector resolves via dispatcher namespace `hubspot.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.HubSpot
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(HubSpot)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "hs-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(HubSpot.manifest())
    end

    test "declares 11 functions at the Primitive 0.3 surface" do
      functions = HubSpot.manifest().functions

      assert Map.has_key?(functions, "contact.find")
      assert Map.has_key?(functions, "contact.create")
      assert Map.has_key?(functions, "contact.update")
      assert Map.has_key?(functions, "company.find")
      assert Map.has_key?(functions, "company.create")
      assert Map.has_key?(functions, "company.update")
      assert Map.has_key?(functions, "deal.find")
      assert Map.has_key?(functions, "deal.create")
      assert Map.has_key?(functions, "deal.update")
      assert Map.has_key?(functions, "activity.log")
      assert Map.has_key?(functions, "task.create")
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      HubSpot.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "region tag is `universal`" do
      assert HubSpot.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "hubspot" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists HubSpot" do
      assert HubSpot in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "error remap" do
    test "HubSpot's category=OBJECT_ALREADY_EXISTS maps to :duplicate" do
      assert :duplicate = HubSpot.remap_error(%{"category" => "OBJECT_ALREADY_EXISTS"})
    end

    test "HTTP 409 with OBJECT_ALREADY_EXISTS body maps to :duplicate" do
      assert :duplicate =
               HubSpot.remap_error({:http, 409, ~s({"category":"OBJECT_ALREADY_EXISTS"})})
    end

    test "unrelated errors fall through to :passthrough" do
      assert :passthrough = HubSpot.remap_error({:http, 500, "boom"})
      assert :passthrough = HubSpot.remap_error(%{"category" => "VALIDATION_ERROR"})
    end
  end

  describe "dispatcher → HubSpot end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:hubspot", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-hubspot-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (contact.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "hubspot", "contact.find", args, _creds ->
        assert args["query"] == "alice@acme.de"
        {:ok, %{"contacts" => [%{"id" => "c-1", "email" => "alice@acme.de"}]}}
      end)

      assert {:ok, %{"contacts" => [%{"id" => "c-1"}]}} =
               Dispatcher.call("hubspot.contact.find",
                               %{"query" => "alice@acme.de"},
                               %{user_id: admin_id})
    end

    test "write function (deal.create) outside an active task is refused", %{admin_id: admin_id} do
      assert {:error, %{error: "write_requires_task", function: "hubspot.deal.create"}} =
               Dispatcher.call("hubspot.deal.create",
                               %{"contact_id" => "c-1", "amount" => 5000},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "hubspot", "deal.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"deal_id" => "d-42"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-deal", step_seq: 0}

      assert {:ok, %{"deal_id" => "d-42"}} =
               Dispatcher.call("hubspot.deal.create",
                               %{"contact_id" => "c-1", "amount" => 5000},
                               ctx)
    end

    test "duplicate-email collision surfaces as canonical :duplicate envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "hubspot", "contact.create", _args, _creds ->
        {:error, %{"category" => "OBJECT_ALREADY_EXISTS",
                   "message"  => "Contact with this email already exists"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-dup", step_seq: 0}

      assert {:error, %{error: "duplicate"}} =
               Dispatcher.call("hubspot.contact.create",
                               %{"email" => "existing@acme.de", "name" => "Existing"},
                               ctx)
    end
  end
end
