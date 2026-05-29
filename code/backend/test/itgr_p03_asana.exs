# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03AsanaTest do
  @moduledoc """
  Integration tests for the Asana connector (Universal Region,
  Case B). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific quirks: every Asana request/response is wrapped in
      a top-level `"data"` key, so the MCPHandler `response` parsers
      unwrap `body["data"]` before mapping to the canonical returns.
    * Error remap: Asana answers normal HTTP status codes with a body
      `%{"errors" => [%{"message" => ...}, ...]}`; the body maps to
      `:passthrough` and the HTTP status drives the canonical class.
    * The connector resolves via dispatcher namespace `asana.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Asana
  alias DmhAi.Connectors.Asana.MCPHandler
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Asana)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "as-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(Asana.manifest())
    end

    test "declares 8 functions at the Primitive 0.3 surface" do
      functions = Asana.manifest().functions

      assert Map.has_key?(functions, "project.find")
      assert Map.has_key?(functions, "project.create")
      assert Map.has_key?(functions, "task.find")
      assert Map.has_key?(functions, "task.create")
      assert Map.has_key?(functions, "task.update")
      assert Map.has_key?(functions, "task.complete")
      assert Map.has_key?(functions, "story.create")
      assert Map.has_key?(functions, "user.find")

      assert map_size(functions) == 8
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Asana.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "read functions are callable from free chat" do
      reads = Asana.manifest().functions |> Enum.filter(fn {_, v} -> v.permission == :read end)

      assert reads != []

      Enum.each(reads, fn {name, v} ->
        assert :chat in v.callable_from,
               "read function #{name} should be callable_from chat; got #{inspect(v.callable_from)}"
      end)
    end

    test "every function declares at least one OAuth scope" do
      Asana.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert is_list(v.scopes) and v.scopes != [],
               "function #{name} must declare a non-empty scopes list; got #{inspect(v.scopes)}"
      end)
    end

    test "Asana's coarse scope model declares `default` on every function" do
      Asana.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert v.scopes == ["default"],
               "function #{name} should declare the coarse `default` scope; got #{inspect(v.scopes)}"
      end)
    end

    test "region tag is `universal`" do
      assert Asana.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "asana" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Asana" do
      assert Asana in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "the `\"data\"` envelope (MCPHandler response unwrap)" do
    # Asana wraps every response in a top-level `"data"` key. A list
    # read returns the inner collection, not the wrapper.
    test "a list read unwraps `data` to the inner list" do
      response = MCPHandler.functions()["project.find"].response

      vendor_body = %{"data" => [%{"gid" => "1200MOCKPROJ01", "name" => "Demo"}]}

      assert {:ok, %{"projects" => [%{"gid" => "1200MOCKPROJ01"}]}} =
               response.(200, vendor_body)
    end

    # A single-resource read returns the inner object, not the wrapper.
    test "a single-object read unwraps `data` to the inner map" do
      response = MCPHandler.functions()["user.find"].response

      vendor_body = %{"data" => %{"gid" => "1200MOCKUSER01", "email" => "a@b.example"}}

      assert {:ok, %{"user" => %{"gid" => "1200MOCKUSER01", "email" => "a@b.example"}}} =
               response.(200, vendor_body)
    end

    # A write echoes the created object's gid from inside the envelope.
    test "a write read unwraps `data` to map the inner gid" do
      response = MCPHandler.functions()["task.create"].response

      vendor_body = %{"data" => %{"gid" => "1200MOCKTASK99", "name" => "Demo"}}

      assert {:ok, %{"task_id" => "1200MOCKTASK99"}} = response.(200, vendor_body)
    end

    # The request builders wrap the payload under `"data"` too.
    test "a write request wraps its fields under the `data` key" do
      request = MCPHandler.functions()["project.create"].request

      assert [json: %{"data" => %{"name" => "Demo", "workspace" => "1200MOCKWS001"}}] =
               request.(%{"name" => "Demo", "workspace_id" => "1200MOCKWS001"}, %{})
    end

    # task.complete sends the fixed `completed: true` body under `data`.
    test "task.complete sends `completed: true` under the `data` key" do
      request = MCPHandler.functions()["task.complete"].request

      assert [json: %{"data" => %{"completed" => true}}] =
               request.(%{"task_id" => "1200MOCKTASK01"}, %{})
    end
  end

  describe "path-param ids (whitelisted via safe_path_id/1)" do
    test "user.find defaults the path segment to `me` when no user_id" do
      url = MCPHandler.functions()["user.find"].url
      assert url.(%{}) == "https://app.asana.com/api/1.0/users/me"
    end

    test "task.find interpolates a whitelisted project gid" do
      url = MCPHandler.functions()["task.find"].url
      assert url.(%{"project_id" => "1200MOCKPROJ01"}) ==
               "https://app.asana.com/api/1.0/projects/1200MOCKPROJ01/tasks"
    end

    test "an id with path-injection characters raises rather than building a URL" do
      url = MCPHandler.functions()["task.update"].url

      assert_raise ArgumentError, fn ->
        url.(%{"task_id" => "1/../../secret?x=1"})
      end
    end
  end

  describe "error remap (Asana errors body — normal HTTP status)" do
    test "an `errors` body maps to :passthrough (HTTP status drives class)" do
      assert :passthrough =
               Asana.remap_error(%{"errors" => [%{"message" => "Not Found"}]})
    end

    test "HTTP-status tuples classify" do
      assert :unauthorised = Asana.remap_error({:http, 401, "x"})
      assert :unauthorised = Asana.remap_error({:http, 403, "x"})
      assert :not_found    = Asana.remap_error({:http, 404, "x"})
      assert :rate_limited = Asana.remap_error({:http, 429, "x"})
      assert :passthrough  = Asana.remap_error({:http, 500, "boom"})
    end
  end

  describe "dispatcher → Asana end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:asana", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-asana-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (project.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "asana", "project.find", args, _creds ->
        assert args["limit"] == 5
        # The Caller hands the connector the already-mapped shape; the
        # MCPHandler's `"data"` unwrap happens on the real-transport
        # path, so the stub returns the post-unwrap canonical shape.
        {:ok, %{"projects" => [%{"gid" => "1200MOCKPROJ01", "name" => "Beispiel-Projekt Demo"}]}}
      end)

      assert {:ok, %{"projects" => [%{"gid" => "1200MOCKPROJ01"}]}} =
               Dispatcher.call("asana.project.find",
                               %{"limit" => 5},
                               %{user_id: admin_id})
    end

    test "write function (task.create) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("asana.task.create",
                               %{"name" => "Demo"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "asana", "task.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"task_id" => "1200MOCKTASK01"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-task", step_seq: 0}

      assert {:ok, %{"task_id" => "1200MOCKTASK01"}} =
               Dispatcher.call("asana.task.create",
                               %{"name" => "Demo"},
                               ctx)
    end

    test "a not-found HTTP status surfaces as canonical :not_found envelope",
         %{admin_id: admin_id} do
      # The MCPHandler surfaces Asana's 4xx `{"errors": [...]}` body as
      # `{:error, {:http, 404, body}}`; the dispatcher pipes that through
      # `Asana.remap_error/1`, which (the body being :passthrough) maps
      # the HTTP status to the canonical `:not_found` class.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "asana", "task.update", _args, _creds ->
        {:error, {:http, 404, %{"errors" => [%{"message" => "Not Found"}]}}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-nf", step_seq: 0}

      assert {:error, %{error: "not_found"}} =
               Dispatcher.call("asana.task.update",
                               %{"task_id" => "1200MOCKTASK01", "patch" => %{"name" => "x"}},
                               ctx)
    end

    test "an auth-failure HTTP status surfaces as canonical :unauthorised envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "asana", "task.create", _args, _creds ->
        {:error, {:http, 401, %{"errors" => [%{"message" => "Not Authorized"}]}}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-auth", step_seq: 0}

      assert {:error, %{error: "unauthorised"}} =
               Dispatcher.call("asana.task.create",
                               %{"name" => "Demo"},
                               ctx)
    end
  end
end
