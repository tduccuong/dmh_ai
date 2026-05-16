# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03McpAdapterTest do
  @moduledoc """
  Integration tests for `DmhAi.Connectors.MCPAdapter` — the
  per-connector base shim used by every Case-B vendor MCP. Covers:

    * `__using__` macro wires `call/3` correctly.
    * `missing_credentials` envelope when user has no token.
    * Successful invoke → `:allowed` audit row written (write functions).
    * Read function successful → silent (no audit row, per volume policy).
    * Read function denied → audit row written.
    * Vendor error normalisation via the connector's `remap_error/1`
      AND fallthrough to the generic HTTP-status classifier.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Tools.{Dispatcher, Manifest}
  alias DmhAi.Tools.Manifest.Function
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  # ─── Stub connector that uses the real base ──────────────────────────────

  defmodule StubVendor do
    use DmhAi.Connectors.MCPAdapter
    alias DmhAi.Tools.Manifest
    alias DmhAi.Tools.Manifest.Function

    def manifest do
      %Manifest{
        connector: "stub_vendor",
        region:    "test",
        functions: %{
          "thing.find" => %Function{
            permission:    :read,
            callable_from: [:chat, :task]
          },
          "thing.create" => %Function{
            permission:      :write,
            callable_from:   [:task],
            idempotency_key: :required
          }
        }
      }
    end

    def mcp_slug, do: "stub_vendor"

    # Vendor maps "DUPLICATE_EMAIL" string to canonical :duplicate.
    def remap_error("DUPLICATE_EMAIL"), do: :duplicate
    def remap_error(_), do: :passthrough
  end

  # ─── Setup ───────────────────────────────────────────────────────────────

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(StubVendor)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "admin-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    {:ok, %{admin_id: admin_id}}
  end

  describe "missing credentials" do
    test "user without an oauth:<slug> credential row → missing_credentials envelope",
         %{admin_id: admin_id} do
      assert {:error, %{error: "missing_credentials", connector: "stub_vendor"}} =
               Dispatcher.call("stub_vendor.thing.find", %{}, %{user_id: admin_id})
    end

    test "denial writes an audit row with reason=missing_credentials", %{admin_id: admin_id} do
      {:error, _} = Dispatcher.call("stub_vendor.thing.find", %{}, %{user_id: admin_id})

      [[reason, outcome]] =
        query!(
          Repo,
          "SELECT reason, outcome FROM audit_log WHERE user_id=? ORDER BY id DESC LIMIT 1",
          [admin_id]
        ).rows

      assert outcome == "denied"
      assert reason == "missing_credentials"
    end
  end

  describe "successful call with stubbed caller" do
    setup %{admin_id: admin_id} do
      # Insert a fake OAuth credential row so lookup_credentials/2 succeeds.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:stub_vendor", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      # Caller stub: echoes args back so we can assert what reached the upstream.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn slug, function, args, _creds ->
        {:ok, %{"echo" => %{"slug" => slug, "function" => function, "args" => args}}}
      end)

      :ok
    end

    test "read function → :ok, no audit row (silent allowed-read)", %{admin_id: admin_id} do
      [[before_count]] =
        query!(Repo, "SELECT COUNT(*) FROM audit_log WHERE user_id=?", [admin_id]).rows

      assert {:ok, %{"echo" => echo}} =
               Dispatcher.call("stub_vendor.thing.find", %{"q" => "foo"}, %{user_id: admin_id})

      assert echo["function"] == "thing.find"
      assert echo["args"]["q"] == "foo"

      [[after_count]] =
        query!(Repo, "SELECT COUNT(*) FROM audit_log WHERE user_id=?", [admin_id]).rows

      assert after_count == before_count,
             "read+allowed must NOT write an audit row (volume policy)"
    end

    test "write function inside task → :ok, idempotency_key threaded, audit row written",
         %{admin_id: admin_id} do
      ctx = %{user_id: admin_id, task_id: "task-xyz", step_seq: 1}

      assert {:ok, %{"echo" => echo}} =
               Dispatcher.call("stub_vendor.thing.create", %{"value" => "v"}, ctx)

      assert is_binary(echo["args"]["__idempotency_key"]),
             "writes must carry an injected idempotency_key"

      [[action, outcome]] =
        query!(Repo,
               "SELECT action, outcome FROM audit_log WHERE user_id=? ORDER BY id DESC LIMIT 1",
               [admin_id]).rows

      assert action == "write"
      assert outcome == "allowed"
    end
  end

  describe "api_key credential kind" do
    defmodule ApiKeyStub do
      use DmhAi.Connectors.MCPAdapter
      alias DmhAi.Tools.Manifest
      alias DmhAi.Tools.Manifest.Function

      def manifest do
        %Manifest{
          connector: "apikey_stub",
          region:    "test",
          functions: %{
            "thing.find" => %Function{
              permission:    :read,
              callable_from: [:chat, :task]
            }
          }
        }
      end

      def mcp_slug, do: "apikey_stub"
      def credential_kind, do: :api_key
    end

    setup %{admin_id: admin_id} do
      DmhAi.Tools.Dispatcher.reset()
      :ok = DmhAi.Tools.Dispatcher.register(ApiKeyStub)

      # Seed an api_key credential under `api_key:apikey_stub`.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "api_key:apikey_stub", "", "api_key",
         Jason.encode!(%{"api_key" => "sk_test_FAKE"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "Caller pulls the api_key row (not the oauth2 row)", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _slug, _function, _args, creds ->
        assert creds["api_key"] == "sk_test_FAKE"
        {:ok, %{}}
      end)

      assert {:ok, _} =
               DmhAi.Tools.Dispatcher.call("apikey_stub.thing.find", %{}, %{user_id: admin_id})
    end

    test "missing api_key row → missing_credentials envelope", %{admin_id: admin_id} do
      # Wipe the api_key row to simulate a fresh user.
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?",
             [admin_id, "api_key:apikey_stub"])

      assert {:error, %{error: "missing_credentials", connector: "apikey_stub"}} =
               DmhAi.Tools.Dispatcher.call("apikey_stub.thing.find", %{}, %{user_id: admin_id})
    end
  end

  describe "error normalisation" do
    setup %{admin_id: admin_id} do
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:stub_vendor", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "vendor-specific remap → canonical :duplicate", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _slug, _function, _args, _creds ->
        {:error, "DUPLICATE_EMAIL"}
      end)

      assert {:error, %{error: "duplicate"}} =
               Dispatcher.call("stub_vendor.thing.create",
                               %{"value" => "v"},
                               %{user_id: admin_id, task_id: "t1", step_seq: 0})
    end

    test "HTTP 401 → :unauthorised", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _, _, _, _ ->
        {:error, {:http, 401, "Unauthorized"}}
      end)

      assert {:error, %{error: "unauthorised"}} =
               Dispatcher.call("stub_vendor.thing.find", %{}, %{user_id: admin_id})
    end

    test "HTTP 429 → :rate_limited", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _, _, _, _ ->
        {:error, {:http, 429, "Too Many Requests"}}
      end)

      assert {:error, %{error: "rate_limited"}} =
               Dispatcher.call("stub_vendor.thing.find", %{}, %{user_id: admin_id})
    end

    test "unrecognised → :upstream_5xx with detail", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn _, _, _, _ ->
        {:error, :something_weird}
      end)

      assert {:error, %{error: "upstream_5xx", detail: _}} =
               Dispatcher.call("stub_vendor.thing.find", %{}, %{user_id: admin_id})
    end
  end
end
