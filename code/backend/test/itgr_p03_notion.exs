# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03NotionTest do
  @moduledoc """
  Integration tests for the Notion connector (Universal Region,
  Case B). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific quirks: search / query reads unwrap the
      `"results"` list; every request builder injects the mandatory
      `Notion-Version` header.
    * Error remap: Notion answers normal HTTP status codes with a body
      `%{"object" => "error", "code" => ..., ...}`; the `code` drives
      the canonical class, with HTTP status as the fallback.
    * The connector resolves via dispatcher namespace `notion.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Notion
  alias DmhAi.Connectors.Notion.MCPHandler
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  # Notion's mandatory request header — a request without it 400s.
  @notion_version "2022-06-28"

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Notion)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "nt-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(Notion.manifest())
    end

    test "declares 16 functions at the Primitive 0.3 surface" do
      functions = Notion.manifest().functions

      # Original 8
      assert Map.has_key?(functions, "page.find")
      assert Map.has_key?(functions, "page.get")
      assert Map.has_key?(functions, "page.create")
      assert Map.has_key?(functions, "page.update")
      assert Map.has_key?(functions, "block.append")
      assert Map.has_key?(functions, "database.find")
      assert Map.has_key?(functions, "database.query")
      assert Map.has_key?(functions, "comment.create")

      # +8 from the Notion expansion
      assert Map.has_key?(functions, "page.archive")
      assert Map.has_key?(functions, "database.create")
      assert Map.has_key?(functions, "database.update")
      assert Map.has_key?(functions, "block.get")
      assert Map.has_key?(functions, "block.delete")
      assert Map.has_key?(functions, "user.list")
      assert Map.has_key?(functions, "user.find_by_email")
      assert Map.has_key?(functions, "comment.find")

      assert map_size(functions) == 16
    end

    test "identity_lookup/0 resolves to user.find_by_email" do
      assert %{function: "notion.user.find_by_email",
               by_arg: :email,
               emit_field: "id"} = Notion.identity_lookup()
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Notion.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "read functions are callable from free chat" do
      reads = Notion.manifest().functions |> Enum.filter(fn {_, v} -> v.permission == :read end)

      assert reads != []

      Enum.each(reads, fn {name, v} ->
        assert :chat in v.callable_from,
               "read function #{name} should be callable_from chat; got #{inspect(v.callable_from)}"
      end)
    end

    test "every function declares at least one OAuth scope" do
      Notion.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert is_list(v.scopes) and v.scopes != [],
               "function #{name} must declare a non-empty scopes list; got #{inspect(v.scopes)}"
      end)
    end

    test "Notion's no-scope model declares `default` on every function" do
      Notion.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert v.scopes == ["default"],
               "function #{name} should declare the placeholder `default` scope; got #{inspect(v.scopes)}"
      end)
    end

    test "region tag is `universal`" do
      assert Notion.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "notion" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Notion" do
      assert Notion in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "the `Notion-Version` header (every request builder)" do
    # Every Notion request MUST carry the version header or it 400s.
    # A search read builds a JSON body + the version header.
    test "page.find request includes the Notion-Version header" do
      request = MCPHandler.functions()["page.find"].request

      [json: _body, headers: headers] = request.(%{"query" => "Demo"}, %{})

      assert {"Notion-Version", @notion_version} in headers
    end

    # A read GET carries no body, but still injects the version header.
    test "page.get request (a GET) still includes the Notion-Version header" do
      request = MCPHandler.functions()["page.get"].request

      [headers: headers] = request.(%{"page_id" => "00000000-mock-page-0000-000000000001"}, %{})

      assert {"Notion-Version", @notion_version} in headers
    end

    # A write builder injects the version header alongside its body.
    test "page.create request includes the Notion-Version header" do
      request = MCPHandler.functions()["page.create"].request

      [json: _body, headers: headers] =
        request.(%{"parent_id" => "00000000-mock-page-0000-000000000001", "title" => "Demo"}, %{})

      assert {"Notion-Version", @notion_version} in headers
    end
  end

  describe "response unwrap (search / query `results`, single-object id)" do
    # A search read unwraps the `results` list, not the wrapper.
    test "page.find unwraps `results` to the inner list" do
      response = MCPHandler.functions()["page.find"].response

      vendor_body = %{"results" => [%{"object" => "page", "id" => "00000000-mock-page-0000-000000000001"}]}

      assert {:ok, %{"pages" => [%{"id" => "00000000-mock-page-0000-000000000001"}]}} =
               response.(200, vendor_body)
    end

    # A query read unwraps the `results` list under the canonical key.
    test "database.query unwraps `results` to the inner list" do
      response = MCPHandler.functions()["database.query"].response

      vendor_body = %{"object" => "list", "results" => [%{"id" => "row-1"}]}

      assert {:ok, %{"results" => [%{"id" => "row-1"}]}} = response.(200, vendor_body)
    end

    # A single-object read returns the page object at the top level.
    test "page.get returns the page object" do
      response = MCPHandler.functions()["page.get"].response

      vendor_body = %{"object" => "page", "id" => "00000000-mock-page-0000-000000000001"}

      assert {:ok, %{"page" => %{"id" => "00000000-mock-page-0000-000000000001"}}} =
               response.(200, vendor_body)
    end

    # A write echoes the created object's id from the top-level body.
    test "page.create maps the top-level id to page_id" do
      response = MCPHandler.functions()["page.create"].response

      vendor_body = %{"object" => "page", "id" => "00000000-mock-page-0000-000000000099"}

      assert {:ok, %{"page_id" => "00000000-mock-page-0000-000000000099"}} =
               response.(200, vendor_body)
    end
  end

  describe "path-param ids (whitelisted via safe_path_id/1)" do
    # Notion ids are UUIDs WITH dashes — the whitelist allows the hyphen.
    test "page.get interpolates a whitelisted dashed UUID" do
      url = MCPHandler.functions()["page.get"].url

      assert url.(%{"page_id" => "00000000-mock-page-0000-000000000001"}) ==
               "https://api.notion.com/v1/pages/00000000-mock-page-0000-000000000001"
    end

    test "database.query interpolates a whitelisted dashed UUID" do
      url = MCPHandler.functions()["database.query"].url

      assert url.(%{"database_id" => "00000000-mock-db00-0000-000000000001"}) ==
               "https://api.notion.com/v1/databases/00000000-mock-db00-0000-000000000001/query"
    end

    test "an id with path-injection characters raises rather than building a URL" do
      url = MCPHandler.functions()["page.update"].url

      assert_raise ArgumentError, fn ->
        url.(%{"page_id" => "1/../../secret?x=1"})
      end
    end
  end

  describe "error remap (Notion error body — code + HTTP status)" do
    test "a Notion error `code` maps to the canonical class" do
      assert :duplicate    = Notion.remap_error(%{"code" => "conflict_error"})
      assert :unauthorised = Notion.remap_error(%{"code" => "unauthorized"})
      assert :unauthorised = Notion.remap_error(%{"code" => "restricted_resource"})
      assert :not_found    = Notion.remap_error(%{"code" => "object_not_found"})
      assert :rate_limited = Notion.remap_error(%{"code" => "rate_limited"})
      assert :passthrough  = Notion.remap_error(%{"code" => "validation_error"})
    end

    test "HTTP-status tuples classify" do
      assert :unauthorised = Notion.remap_error({:http, 401, "x"})
      assert :unauthorised = Notion.remap_error({:http, 403, "x"})
      assert :not_found    = Notion.remap_error({:http, 404, "x"})
      assert :duplicate    = Notion.remap_error({:http, 409, "x"})
      assert :rate_limited = Notion.remap_error({:http, 429, "x"})
      assert :passthrough  = Notion.remap_error({:http, 500, "boom"})
    end
  end

  describe "dispatcher → Notion end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:notion", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-notion-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (page.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "notion", "page.find", args, _creds ->
        assert args["query"] == "Demo"
        # The Caller hands the connector the already-mapped shape; the
        # MCPHandler's `results` unwrap happens on the real-transport
        # path, so the stub returns the post-unwrap canonical shape.
        {:ok, %{"pages" => [%{"id" => "00000000-mock-page-0000-000000000001"}]}}
      end)

      assert {:ok, %{"pages" => [%{"id" => "00000000-mock-page-0000-000000000001"}]}} =
               Dispatcher.call("notion.page.find",
                               %{"query" => "Demo"},
                               %{user_id: admin_id})
    end

    test "write function (page.create) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("notion.page.create",
                               %{"parent_id" => "00000000-mock-page-0000-000000000001",
                                 "title" => "Demo"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "notion", "page.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"page_id" => "00000000-mock-page-0000-000000000001"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-page", step_seq: 0}

      assert {:ok, %{"page_id" => "00000000-mock-page-0000-000000000001"}} =
               Dispatcher.call("notion.page.create",
                               %{"parent_id" => "00000000-mock-page-0000-000000000001",
                                 "title" => "Demo"},
                               ctx)
    end

    test "a not-found HTTP status surfaces as canonical :not_found envelope",
         %{admin_id: admin_id} do
      # The MCPHandler surfaces Notion's 4xx `{"object":"error",...}`
      # body as `{:error, {:http, 404, body}}`; the dispatcher pipes
      # that through `Notion.remap_error/1`, which maps the
      # `object_not_found` code to the canonical `:not_found` class.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "notion", "page.update", _args, _creds ->
        {:error, {:http, 404, %{"object" => "error", "code" => "object_not_found", "message" => "Not Found"}}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-nf", step_seq: 0}

      assert {:error, %{error: "not_found"}} =
               Dispatcher.call("notion.page.update",
                               %{"page_id" => "00000000-mock-page-0000-000000000001",
                                 "patch" => %{"title" => "x"}},
                               ctx)
    end

    test "an auth-failure HTTP status surfaces as canonical :unauthorised envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "notion", "page.create", _args, _creds ->
        {:error, {:http, 401, %{"object" => "error", "code" => "unauthorized", "message" => "Not Authorized"}}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-auth", step_seq: 0}

      assert {:error, %{error: "unauthorised"}} =
               Dispatcher.call("notion.page.create",
                               %{"parent_id" => "00000000-mock-page-0000-000000000001",
                                 "title" => "Demo"},
                               ctx)
    end

    test "read function (user.list) from free chat returns the inner users list",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "notion", "user.list", args, _creds ->
          assert args["limit"] == 25

          # The Caller hands the connector the already-mapped shape;
          # MCPHandler's `results` unwrap fires on the real transport
          # path, so the stub returns the post-unwrap shape.
          {:ok,
           %{
             "users" => [
               %{
                 "id" => "00000000-mock-user-0000-000000000001",
                 "type" => "person",
                 "person" => %{"email" => "klara.beispiel@beispiel-team-demo.example"}
               }
             ]
           }}
        end)

      assert {:ok,
              %{"users" => [%{"id" => "00000000-mock-user-0000-000000000001"}]}} =
               Dispatcher.call("notion.user.list",
                               %{"limit" => 25},
                               %{user_id: admin_id})
    end

    test "write function (page.archive) in-task carries injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "notion", "page.archive", args, _creds ->
          assert is_binary(args["__idempotency_key"]),
                 "writes must carry idempotency_key injected by Dispatcher"
          assert args["page_id"] == "00000000-mock-page-0000-000000000001"

          {:ok, %{"page_id" => "00000000-mock-page-0000-000000000001"}}
        end)

      ctx = %{user_id: admin_id, task_id: "t-archive-page", step_seq: 0}

      assert {:ok, %{"page_id" => "00000000-mock-page-0000-000000000001"}} =
               Dispatcher.call("notion.page.archive",
                               %{"page_id" => "00000000-mock-page-0000-000000000001"},
                               ctx)
    end
  end
end
