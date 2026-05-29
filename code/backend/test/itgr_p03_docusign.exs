# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03DocuSignTest do
  @moduledoc """
  Integration tests for the DocuSign connector (Universal Region,
  Case B — vendor MCP / REST bridge) covering envelopes, recipients,
  and templates. Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific error remap: DocuSign's `errorCode`-keyed body
      maps to canonical classes (`:unauthorised` / `:not_found` /
      `:rate_limited`), with HTTP-status tuples as the fallback.
    * Path-param ids (envelope_id) go through `safe_path_id/1` which
      whitelists `^[A-Za-z0-9-]+$` (DocuSign UUIDs carry dashes).
    * The connector resolves via dispatcher namespace `docusign.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.DocuSign
  alias DmhAi.Connectors.DocuSign.MCPHandler
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(DocuSign)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "ds-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(DocuSign.manifest())
    end

    test "declares 7 functions at the Primitive 0.3 surface" do
      functions = DocuSign.manifest().functions

      assert Map.has_key?(functions, "envelope.find")
      assert Map.has_key?(functions, "envelope.create")
      assert Map.has_key?(functions, "envelope.get")
      assert Map.has_key?(functions, "envelope.send")
      assert Map.has_key?(functions, "envelope.void")
      assert Map.has_key?(functions, "recipient.add")
      assert Map.has_key?(functions, "template.find")

      assert map_size(functions) == 7
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      DocuSign.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "read functions are callable from free chat" do
      reads = DocuSign.manifest().functions |> Enum.filter(fn {_, v} -> v.permission == :read end)

      assert reads != []

      Enum.each(reads, fn {name, v} ->
        assert :chat in v.callable_from,
               "read function #{name} should be callable_from chat; got #{inspect(v.callable_from)}"
      end)
    end

    test "every function declares the coarse `signature` scope" do
      DocuSign.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert v.scopes == ["signature"],
               "function #{name} should declare the coarse `signature` scope; got #{inspect(v.scopes)}"
      end)
    end

    test "region tag is `universal`" do
      assert DocuSign.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "docusign" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists DocuSign" do
      assert DocuSign in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "error remap (DocuSign error body — errorCode + HTTP status)" do
    test "auth-flavored errorCodes map to :unauthorised" do
      assert :unauthorised = DocuSign.remap_error(%{"errorCode" => "INVALID_TOKEN_FORMAT"})
      assert :unauthorised = DocuSign.remap_error(%{"errorCode" => "USER_AUTHENTICATION_FAILED"})
      assert :unauthorised = DocuSign.remap_error(%{"errorCode" => "INVALID_CLIENT_ID"})
    end

    test "not-found-flavored errorCodes map to :not_found" do
      assert :not_found = DocuSign.remap_error(%{"errorCode" => "ENVELOPE_DOES_NOT_EXIST"})
      assert :not_found = DocuSign.remap_error(%{"errorCode" => "INVALID_ENVELOPE_ID"})
      assert :not_found = DocuSign.remap_error(%{"errorCode" => "TEMPLATE_NOT_FOUND"})
    end

    test "rate-limit errorCode maps to :rate_limited" do
      assert :rate_limited = DocuSign.remap_error(%{"errorCode" => "RATE_LIMIT_EXCEEDED"})
    end

    test "an unrelated errorCode falls through to :passthrough" do
      assert :passthrough = DocuSign.remap_error(%{"errorCode" => "INVALID_REQUEST_BODY"})
      assert :passthrough = DocuSign.remap_error(%{"errorCode" => "UNKNOWN_VENDOR_ERROR"})
    end

    test "auth / not-found / rate-limit HTTP statuses map to canonical classes" do
      assert :unauthorised = DocuSign.remap_error({:http, 401, "x"})
      assert :unauthorised = DocuSign.remap_error({:http, 403, "x"})
      assert :not_found    = DocuSign.remap_error({:http, 404, "x"})
      assert :rate_limited = DocuSign.remap_error({:http, 429, "x"})
    end

    test "unrelated HTTP statuses / terms fall through to :passthrough" do
      assert :passthrough = DocuSign.remap_error({:http, 500, "boom"})
      assert :passthrough = DocuSign.remap_error("nope")
    end
  end

  describe "path-param ids (whitelisted via safe_path_id/1)" do
    # DocuSign envelope_ids are UUIDs WITH dashes — the whitelist
    # allows the hyphen.
    test "envelope.get interpolates a whitelisted dashed UUID" do
      url = MCPHandler.functions()["envelope.get"].url

      assert url.(%{"envelope_id" => "11111111-mock-envl-0000-000000000001"}) =~
               "/envelopes/11111111-mock-envl-0000-000000000001"
    end

    test "envelope.send and envelope.void share the same envelope URL shape" do
      send_url = MCPHandler.functions()["envelope.send"].url
      void_url = MCPHandler.functions()["envelope.void"].url

      args = %{"envelope_id" => "11111111-mock-envl-0000-000000000001"}

      assert send_url.(args) == void_url.(args)
    end

    test "recipient.add appends /recipients to the envelope path" do
      url = MCPHandler.functions()["recipient.add"].url

      assert url.(%{"envelope_id" => "11111111-mock-envl-0000-000000000001"}) =~
               "/envelopes/11111111-mock-envl-0000-000000000001/recipients"
    end

    test "an id with path-injection characters raises rather than building a URL" do
      url = MCPHandler.functions()["envelope.get"].url

      assert_raise ArgumentError, fn ->
        url.(%{"envelope_id" => "1/../../secret?x=1"})
      end
    end
  end

  describe "request body shapes" do
    test "envelope.void request body carries status=voided + voidedReason" do
      request = MCPHandler.functions()["envelope.void"].request

      [json: body] = request.(%{"envelope_id" => "11111111-mock-envl-0000-000000000001",
                                "voided_reason" => "Signed offline."}, %{})

      assert body == %{"status" => "voided", "voidedReason" => "Signed offline."}
    end

    test "envelope.send request body is the minimal status=sent" do
      request = MCPHandler.functions()["envelope.send"].request

      [json: body] = request.(%{"envelope_id" => "11111111-mock-envl-0000-000000000001"}, %{})

      assert body == %{"status" => "sent"}
    end
  end

  describe "dispatcher → DocuSign end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      # The token literal is a deliberately fake placeholder — kept
      # short + not in any vendor regex shape to avoid secret-scanner
      # false positives.
      fake_token = "fake-" <> "docusign-token"

      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:docusign", "", "oauth2",
         Jason.encode!(%{"access_token" => fake_token}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (envelope.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "docusign", "envelope.find", args, _creds ->
        assert args["limit"] == 5
        {:ok, %{"envelopes" => [%{"envelope_id" => "11111111-mock-envl-0000-000000000001",
                                  "status" => "sent",
                                  "email_subject" => "Beispiel Mock-Vertrag zur Unterschrift"}]}}
      end)

      assert {:ok, %{"envelopes" => [%{"envelope_id" => "11111111-mock-envl-0000-000000000001"}]}} =
               Dispatcher.call("docusign.envelope.find",
                               %{"limit" => 5},
                               %{user_id: admin_id})
    end

    test "write function (envelope.create) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("docusign.envelope.create",
                               %{"subject"    => "Beispiel-Vertrag",
                                 "recipients" => [],
                                 "documents"  => [],
                                 "status"     => "sent"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "docusign", "envelope.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"envelope_id" => "11111111-mock-envl-0000-000000000042"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-envelope", step_seq: 0}

      assert {:ok, %{"envelope_id" => "11111111-mock-envl-0000-000000000042"}} =
               Dispatcher.call("docusign.envelope.create",
                               %{"subject"    => "Beispiel-Vertrag",
                                 "recipients" => [],
                                 "documents"  => [],
                                 "status"     => "sent"},
                               ctx)
    end

    test "a DocuSign errorCode body surfaces as canonical :not_found envelope",
         %{admin_id: admin_id} do
      # The MCPHandler surfaces DocuSign's 4xx body as `{:error, body}`;
      # the dispatcher pipes that body through `DocuSign.remap_error/1`,
      # which keys off the `errorCode` and maps `ENVELOPE_DOES_NOT_EXIST`
      # to the canonical `:not_found` class.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "docusign", "envelope.send", _args, _creds ->
        {:error, %{"errorCode" => "ENVELOPE_DOES_NOT_EXIST",
                   "message"   => "The envelope could not be located."}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-not-found", step_seq: 0}

      assert {:error, %{error: "not_found"}} =
               Dispatcher.call("docusign.envelope.send",
                               %{"envelope_id" => "11111111-mock-envl-0000-000000000001"},
                               ctx)
    end
  end
end
