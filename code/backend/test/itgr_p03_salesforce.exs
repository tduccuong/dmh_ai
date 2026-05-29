# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03SalesforceTest do
  @moduledoc """
  Integration tests for the Salesforce connector (Universal Region,
  Case B). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific error remap: Salesforce's `errorCode`
      `DUPLICATE_VALUE` / `DUPLICATES_DETECTED` → canonical `:duplicate`.
    * The connector resolves via dispatcher namespace `salesforce.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Salesforce
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Salesforce)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "sf-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(Salesforce.manifest())
    end

    test "declares 11 functions at the Primitive 0.3 surface" do
      functions = Salesforce.manifest().functions

      assert Map.has_key?(functions, "lead.find")
      assert Map.has_key?(functions, "lead.create")
      assert Map.has_key?(functions, "contact.find")
      assert Map.has_key?(functions, "contact.create")
      assert Map.has_key?(functions, "account.find")
      assert Map.has_key?(functions, "account.create")
      assert Map.has_key?(functions, "opportunity.find")
      assert Map.has_key?(functions, "opportunity.create")
      assert Map.has_key?(functions, "opportunity.update")
      assert Map.has_key?(functions, "case.create")
      assert Map.has_key?(functions, "task.create")
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Salesforce.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "every function declares the coarse `api` scope" do
      Salesforce.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert v.scopes == ["api"],
               "function #{name} must declare scopes: [\"api\"]; got #{inspect(v.scopes)}"
      end)
    end

    test "region tag is `universal`" do
      assert Salesforce.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "salesforce" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Salesforce" do
      assert Salesforce in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "error remap" do
    test "Salesforce error array with DUPLICATE_VALUE maps to :duplicate" do
      assert :duplicate =
               Salesforce.remap_error([%{"message" => "duplicate value found",
                                         "errorCode" => "DUPLICATE_VALUE"}])
    end

    test "Salesforce error with DUPLICATES_DETECTED maps to :duplicate" do
      assert :duplicate =
               Salesforce.remap_error([%{"message" => "Use one of these records?",
                                         "errorCode" => "DUPLICATES_DETECTED"}])
    end

    test "HTTP 400 with DUPLICATE_VALUE body maps to :duplicate" do
      assert :duplicate =
               Salesforce.remap_error({:http, 400, ~s([{"errorCode":"DUPLICATE_VALUE"}])})
    end

    test "REQUEST_LIMIT_EXCEEDED in the decoded body maps to :rate_limited" do
      assert :rate_limited =
               Salesforce.remap_error([%{"errorCode" => "REQUEST_LIMIT_EXCEEDED"}])

      # Binary-body fallthrough: a status not caught by the explicit
      # 401/403/404/429 clauses still maps to :rate_limited when the
      # body carries the limit signal.
      assert :rate_limited =
               Salesforce.remap_error({:http, 500, ~s([{"errorCode":"REQUEST_LIMIT_EXCEEDED"}])})
    end

    test "an explicit auth status wins over a limit signal in the body (clause order)" do
      # Salesforce returns REQUEST_LIMIT_EXCEEDED as HTTP 403; the
      # explicit 403 → :unauthorised clause precedes the binary-body
      # limit check, so the status classification takes priority.
      assert :unauthorised =
               Salesforce.remap_error({:http, 403, ~s([{"errorCode":"REQUEST_LIMIT_EXCEEDED"}])})
    end

    test "unrelated errors fall through to :passthrough" do
      assert :passthrough = Salesforce.remap_error({:http, 500, "boom"})
      assert :passthrough = Salesforce.remap_error({:http, 400, ~s([{"errorCode":"MALFORMED_QUERY"}])})
      assert :passthrough = Salesforce.remap_error([%{"errorCode" => "MALFORMED_QUERY"}])
    end

    test "auth / not-found / rate-limit statuses map to canonical classes" do
      assert :unauthorised = Salesforce.remap_error({:http, 401, "x"})
      assert :unauthorised = Salesforce.remap_error({:http, 403, "x"})
      assert :not_found    = Salesforce.remap_error({:http, 404, "x"})
      assert :rate_limited = Salesforce.remap_error({:http, 429, "x"})
    end
  end

  describe "dispatcher → Salesforce end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:salesforce", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-salesforce-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (account.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "salesforce", "account.find", args, _creds ->
        assert args["query"] == "Beispiel"
        {:ok, %{"accounts" => [%{"id" => "001-1", "name" => "Beispiel Vertrieb GmbH"}]}}
      end)

      assert {:ok, %{"accounts" => [%{"id" => "001-1"}]}} =
               Dispatcher.call("salesforce.account.find",
                               %{"query" => "Beispiel"},
                               %{user_id: admin_id})
    end

    test "write function (lead.create) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("salesforce.lead.create",
                               %{"last_name" => "Beispiel", "company" => "Beispiel Vertrieb GmbH"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "salesforce", "lead.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"lead_id" => "00Q-42"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-lead", step_seq: 0}

      assert {:ok, %{"lead_id" => "00Q-42"}} =
               Dispatcher.call("salesforce.lead.create",
                               %{"last_name" => "Beispiel", "company" => "Beispiel Vertrieb GmbH"},
                               ctx)
    end

    test "duplicate collision surfaces as canonical :duplicate envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "salesforce", "contact.create", _args, _creds ->
        {:error, [%{"message" => "duplicate value found", "errorCode" => "DUPLICATE_VALUE"}]}
      end)

      ctx = %{user_id: admin_id, task_id: "t-dup", step_seq: 0}

      assert {:error, %{error: "duplicate"}} =
               Dispatcher.call("salesforce.contact.create",
                               %{"last_name" => "Beispiel", "email" => "existing@beispiel.de"},
                               ctx)
    end
  end
end
