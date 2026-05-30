# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03AtlassianTest do
  @moduledoc """
  Integration tests for the Atlassian connector (Universal Region,
  Case B) covering Jira + Confluence under a single slug. Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific error remap: Jira's `errorMessages` array carrying
      `"Issue Does Not Exist"` maps to canonical `:not_found`; HTTP
      tuples map to the standard 4xx classes.
    * `jql_quote/1` (exercised via the MCP handler's `request_body/2`
      builder for `issue.find`) safely escapes a backslash + single
      quote in the project key value — no SOQL/JQL-injection vector.
    * The connector resolves via dispatcher namespace `atlassian.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Atlassian
  alias DmhAi.Connectors.Atlassian.MCPHandler
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Atlassian)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "atl-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(Atlassian.manifest())
    end

    test "declares 17 functions at the Primitive 0.3 surface" do
      functions = Atlassian.manifest().functions

      # Original 9
      assert Map.has_key?(functions, "issue.find")
      assert Map.has_key?(functions, "issue.create")
      assert Map.has_key?(functions, "issue.update")
      assert Map.has_key?(functions, "issue.transition")
      assert Map.has_key?(functions, "issue.comment")
      assert Map.has_key?(functions, "project.find")
      assert Map.has_key?(functions, "page.find")
      assert Map.has_key?(functions, "page.create")
      assert Map.has_key?(functions, "page.update")

      # +8 from the Atlassian expansion
      assert Map.has_key?(functions, "issue.delete")
      assert Map.has_key?(functions, "issue.add_attachment")
      assert Map.has_key?(functions, "sprint.find")
      assert Map.has_key?(functions, "issue.move_to_sprint")
      assert Map.has_key?(functions, "board.find")
      assert Map.has_key?(functions, "user.find_by_email")
      assert Map.has_key?(functions, "page.delete")
      assert Map.has_key?(functions, "space.find")

      assert map_size(functions) == 17
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Atlassian.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "read functions are callable from free chat" do
      reads = Atlassian.manifest().functions |> Enum.filter(fn {_, v} -> v.permission == :read end)

      assert reads != []

      Enum.each(reads, fn {name, v} ->
        assert :chat in v.callable_from,
               "read function #{name} should be callable_from chat; got #{inspect(v.callable_from)}"
      end)
    end

    test "every function declares at least one OAuth scope" do
      Atlassian.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert is_list(v.scopes) and v.scopes != [],
               "function #{name} must declare a non-empty scopes list; got #{inspect(v.scopes)}"
      end)
    end

    test "region tag is `universal`" do
      assert Atlassian.manifest().region == "universal"
    end

    test "identity_lookup pivots Jira user search to accountId" do
      assert %{function: "atlassian.user.find_by_email",
               by_arg: :email,
               emit_field: "accountId"} = Atlassian.identity_lookup()
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "atlassian" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Atlassian" do
      assert Atlassian in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "error remap" do
    test "Jira error body with 'Issue Does Not Exist' message maps to :not_found" do
      assert :not_found =
               Atlassian.remap_error(%{
                 "errorMessages" => ["Issue Does Not Exist"],
                 "errors" => %{}
               })
    end

    test "Jira error body with an unrelated message falls through to :passthrough" do
      assert :passthrough =
               Atlassian.remap_error(%{
                 "errorMessages" => ["Field 'foo' cannot be set"],
                 "errors" => %{}
               })
    end

    test "auth / not-found / conflict / rate-limit statuses map to canonical classes" do
      assert :unauthorised = Atlassian.remap_error({:http, 401, "x"})
      assert :unauthorised = Atlassian.remap_error({:http, 403, "x"})
      assert :not_found    = Atlassian.remap_error({:http, 404, "x"})
      assert :duplicate    = Atlassian.remap_error({:http, 409, "x"})
      assert :rate_limited = Atlassian.remap_error({:http, 429, "x"})
    end

    test "unrelated errors fall through to :passthrough" do
      assert :passthrough = Atlassian.remap_error({:http, 500, "boom"})
      assert :passthrough = Atlassian.remap_error("nope")
    end
  end

  describe "JQL escape" do
    # The handler's `issue_find_request/2` builds the JQL server-side
    # and runs every interpolated value through `jql_quote/1`. The
    # injection vector to defuse is a value containing a single quote
    # or a backslash — `jql_quote/1` doubles the backslash first, then
    # escapes the quote, so the resulting JQL literal can't break out
    # of its `'...'` wrapper.
    test "an embedded backslash + single quote in the project key are escaped before JQL" do
      spec = MCPHandler.functions()["issue.find"]
      assert is_function(spec.request, 2)

      # The malicious-shaped value: a backslash followed by an unescaped
      # single quote. A naive interpolator would emit
      #   project = 'MOCK\' OR 1=1 -- '
      # which lets the trailing `OR 1=1 --` escape the literal. The
      # quoter must produce a literal whose closing `'` belongs to the
      # quoter, not the attacker.
      args = %{
        "project_key" => "MOCK\\' OR 1=1 -- ",
        "limit"       => 5
      }

      opts = spec.request.(args, %{})
      params = Keyword.fetch!(opts, :params)
      jql = Map.fetch!(params, "jql")

      # Backslashes are doubled and the embedded `'` is `\'` — the JQL
      # is still wrapped in a single pair of single quotes that the
      # connector controls.
      assert String.starts_with?(jql, "project = '")
      assert String.ends_with?(jql, "'")

      # The escape produced doubled backslashes + a backslash-quote —
      # the literal contains the attacker's bytes verbatim, escaped.
      # The attacker's apostrophe is `\'` (backslash + quote), not a
      # raw `'`, so it can't terminate the JQL string literal.
      assert jql =~ "\\\\"
      assert jql =~ "\\'"

      # Strip the leading `project = '` and trailing `'` — the
      # remaining string is the escaped payload; it MUST NOT contain
      # an unescaped (= not preceded by a backslash) single quote,
      # which is what would let the attacker break out of the literal.
      payload = jql |> String.replace_prefix("project = '", "") |> String.replace_suffix("'", "")
      refute Regex.match?(~r/(?<!\\)'/, payload),
             "escaped payload still contains an unescaped quote: #{inspect(payload)}"
    end

    test "issue.find with both project_key and status produces a conjunctive WHERE" do
      spec = MCPHandler.functions()["issue.find"]
      args = %{"project_key" => "PROJ", "status" => "In Progress", "limit" => 10}

      opts = spec.request.(args, %{})
      params = Keyword.fetch!(opts, :params)
      jql = Map.fetch!(params, "jql")

      assert jql == "project = 'PROJ' AND status = 'In Progress'"
      assert params["maxResults"] == 10
    end
  end

  describe "dispatcher → Atlassian end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:atlassian", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-atlassian-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (project.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "atlassian", "project.find", args, _creds ->
        assert args["limit"] == 5
        {:ok, %{"projects" => [%{"id" => "10000", "key" => "MOCKPROJ", "name" => "Beispiel Mock-Projekt"}]}}
      end)

      assert {:ok, %{"projects" => [%{"key" => "MOCKPROJ"}]}} =
               Dispatcher.call("atlassian.project.find",
                               %{"limit" => 5},
                               %{user_id: admin_id})
    end

    test "write function (issue.create) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("atlassian.issue.create",
                               %{"project_key" => "MOCKPROJ",
                                 "summary"     => "Beispiel-Vorgang",
                                 "issue_type"  => "Task"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "atlassian", "issue.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"issue_id" => "10042", "key" => "MOCKPROJ-42"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-issue", step_seq: 0}

      assert {:ok, %{"issue_id" => "10042", "key" => "MOCKPROJ-42"}} =
               Dispatcher.call("atlassian.issue.create",
                               %{"project_key" => "MOCKPROJ",
                                 "summary"     => "Beispiel-Vorgang",
                                 "issue_type"  => "Task"},
                               ctx)
    end

    test "a Jira not-found body surfaces as canonical :not_found envelope",
         %{admin_id: admin_id} do
      # The MCPHandler surfaces Jira's 404 body as `{:error, body}`; the
      # dispatcher pipes that body through `Atlassian.remap_error/1`,
      # which keys off the `errorMessages` array and maps it to the
      # canonical `:not_found` class.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "atlassian", "issue.comment", _args, _creds ->
        {:error, %{"errorMessages" => ["Issue Does Not Exist"], "errors" => %{}}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-not-found", step_seq: 0}

      assert {:error, %{error: "not_found"}} =
               Dispatcher.call("atlassian.issue.comment",
                               %{"issue_key" => "MOCKPROJ-1", "body" => "Hallo"},
                               ctx)
    end

    test "read function (board.find) from free chat returns the inner boards list",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "atlassian", "board.find", args, _creds ->
          assert args["limit"] == 25

          {:ok,
           %{"boards" => [%{"id" => "MOCKBOARD1",
                            "name" => "Beispiel Mock-Board",
                            "type" => "scrum"}]}}
        end)

      assert {:ok, %{"boards" => [%{"id" => "MOCKBOARD1"}]}} =
               Dispatcher.call("atlassian.board.find",
                               %{"limit" => 25},
                               %{user_id: admin_id})
    end

    test "write function (issue.delete) in-task carries injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "atlassian", "issue.delete", args, _creds ->
          assert is_binary(args["__idempotency_key"]),
                 "writes must carry idempotency_key injected by Dispatcher"
          assert args["issue_key"] == "MOCKPROJ-1"

          {:ok, %{"ok" => true}}
        end)

      ctx = %{user_id: admin_id, task_id: "t-delete-issue", step_seq: 0}

      assert {:ok, %{"ok" => true}} =
               Dispatcher.call("atlassian.issue.delete",
                               %{"issue_key" => "MOCKPROJ-1"},
                               ctx)
    end
  end
end
