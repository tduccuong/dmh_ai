# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowsTest do
  @moduledoc """
  Integration tests for the Layer W workflow primitive.

  Covers:
    * `upsert_workflow` tool — first save lands at v0; repeat lands at v+1;
      requires a non-empty `description`.
    * Slug derivation from display_name.
    * Shape validation rejects malformed IR (missing trigger / no nodes).
    * Deep validation rejects unknown function, missing required args,
      unknown args, and unbound Mustache references.
    * `arm_workflow` arms current_version (no version arg);
      `disarm_workflow` clears it; on subsequent upsert, the armed
      snapshot auto-bumps in lockstep so the trigger fires the
      latest shape.
    * `invoke_workflow` always uses current_version (no version arg).
    * `GET /workflows/:slug/:version` returns the IR JSON.
    * `GET /workflows?q=<prefix>` returns the picker rows with
      description + trigger_inputs.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Workflows}
  alias DmhAi.Tools.{UpsertWorkflow, ArmWorkflow, DisarmWorkflow, InvokeWorkflow}
  alias DmhAi.Handlers.Workflows, as: WorkflowsHandler
  alias DmhAi.Handlers.Runs, as: RunsHandler
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id "default"

  setup do
    user_id = T.uid()
    session_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "wf-#{user_id}@test.local", "Test", "x:y", "user",
       @org_id, "member", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO sessions (id, name, model, messages, mode, user_id, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [session_id, "wf-test", "test:model", "[]", "assistant", user_id,
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    :ok = T.grant_all_scopes(user_id)

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflows WHERE org_id=?", [@org_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, user_id: user_id, session_id: session_id, ctx: %{user_id: user_id, session_id: session_id, org_id: @org_id}}
  end

  describe "upsert_workflow — basic" do
    test "first save lands at v0; same name re-saved bumps to v1", %{ctx: ctx} do
      ir = minimal_ir()

      assert {:ok, %{"version" => 0, "name" => "workflow_test_wf", "url" => "/workflows/workflow_test_wf/0"}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Test WF",
                 "name"         => "workflow_test_wf",
                 "description"  => "A minimal manual workflow that emits an `ok` flag for tests.",
                 "ir"           => ir,
                 "change_note"  => "initial draft"
               }, ctx)

      assert {:ok, %{"version" => 1, "name" => "workflow_test_wf", "url" => "/workflows/workflow_test_wf/1"}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Test WF",
                 "name"         => "workflow_test_wf",
                 "description"  => "A minimal manual workflow that emits an `ok` flag for tests.",
                 "ir"           => ir,
                 "change_note"  => "second save"
               }, ctx)
    end

    test "slug derived from display_name when name omitted", %{ctx: ctx} do
      assert {:ok, %{"name" => "workflow_daily_inbox_digest"}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Daily Inbox Digest!",
                 "description"  => "Summarises unread inbox messages on demand.",
                 "ir"           => minimal_ir(),
                 "change_note"  => "initial"
               }, ctx)
    end

    test "description is required (missing / too short / too long rejected)", %{ctx: ctx} do
      ir = minimal_ir()

      # Missing entirely → tool surfaces the schema-level requirement.
      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "No Desc",
                 "ir"           => ir,
                 "change_note"  => "initial"
               }, ctx)
      assert msg =~ "description required"

      # Too short.
      assert {:error, msg2} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Short Desc",
                 "description"  => "tiny",
                 "ir"           => ir,
                 "change_note"  => "initial"
               }, ctx)
      assert msg2 =~ "too short"

      # Too long (>280 chars).
      long = String.duplicate("a", 281)
      assert {:error, msg3} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Long Desc",
                 "description"  => long,
                 "ir"           => ir,
                 "change_note"  => "initial"
               }, ctx)
      assert msg3 =~ "too long"
    end
  end

  describe "upsert_workflow — shape validation rejects malformed IR" do
    test "missing trigger node", %{ctx: ctx} do
      ir = %{"nodes" => [%{"id" => 1, "kind" => "output", "label" => "ok", "emit" => %{}}]}

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "no trigger node"
    end

    test "no nodes", %{ctx: ctx} do
      ir = %{"nodes" => []}

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "at least one node"
    end

    test "duplicate node ids", %{ctx: ctx} do
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "output", "label" => "a", "emit" => %{}},
        %{"id" => 1, "kind" => "output", "label" => "b", "emit" => %{}}
      ])

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "duplicate node ids"
    end

    test "two trigger nodes rejected", %{ctx: ctx} do
      ir = %{"nodes" => [
        %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
          "inputs" => [], "next" => 1},
        %{"id" => 1, "kind" => "trigger", "trigger_kind" => "manual",
          "inputs" => [], "next" => 2},
        %{"id" => 2, "kind" => "output", "emit" => %{"x" => 1}}
      ]}

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "2 trigger nodes"
    end

    test "output node with function rejected", %{ctx: ctx} do
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "output", "label" => "bad",
          "function" => "builtin.emit", "args" => %{"x" => 1},
          "emit" => %{"x" => 1}}
      ])

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "Output nodes are terminal"
    end

    test "output node missing emit rejected", %{ctx: ctx} do
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "output", "label" => "no emit"}
      ])

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "emit"
    end
  end

  describe "upsert_workflow — deep validation against connector catalog" do
    test "unknown function rejected", %{ctx: ctx} do
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "step", "function" => "hubspot.does_not_exist", "args" => %{}, "label" => "fake"}
      ])

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "unknown function"
      assert msg =~ "hubspot.does_not_exist"
    end

    test "real connector function with missing required args rejected", %{ctx: ctx} do
      # hubspot.contact.find requires `query` per the HubSpot manifest.
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find", "args" => %{}, "label" => "find"}
      ])

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "missing required args"
      assert msg =~ "query"
    end

    test "unknown args (not in the function's manifest) rejected", %{ctx: ctx} do
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find",
           "args" => %{"query" => "alice", "nonsense" => "x"}, "label" => "find"}
      ])

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "not in the function manifest"
      assert msg =~ "nonsense"
    end

    test "synthetic functions (llm.compose, builtin.compute) pass through", %{ctx: ctx} do
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "step", "function" => "llm.compose",      "args" => %{"template" => "x"}, "label" => "compose"},
        %{"id" => 2, "kind" => "step", "function" => "builtin.compute",  "args" => %{"formula" => "1+1"}, "label" => "math"}
      ])

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Synth WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
    end

    test "unbound `{{T.x}}` reference (no matching trigger input) rejected", %{ctx: ctx} do
      ir = ir_with_trigger(
        [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find",
             "args" => %{"query" => "{{T.nonexistent}}"}, "label" => "find"}
        ],
        [%{"name" => "deal.id", "type" => "string"}]
      )

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "T.nonexistent"
    end

    test "node-to-node `{{1.field}}` reference resolves when emits declares it", %{ctx: ctx} do
      ir = ir_with_trigger([
        %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find",
           "args"  => %{"query" => "alice"}, "emits" => %{"contact_id" => "$.contacts[0].id"},
           "label" => "find"},
        %{"id" => 2, "kind" => "step", "function" => "hubspot.deal.create",
           "args"  => %{"contact_id" => "{{1.contact_id}}", "amount" => 1000},
           "label" => "create deal"}
      ])

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "OK WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
    end

    test "implicit emit: ref against a manifest-declared `returns:` key needs no `emits` map",
         %{ctx: ctx} do
      # `hubspot.deal.create` declares `returns: %{deal_id: :string}`. A
      # downstream node may reference `{{1.deal_id}}` directly — no
      # `emits` field required on node 1.
      ir = ir_with_trigger(
        [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.deal.create",
             "args"  => %{"contact_id" => "{{T.contact_id}}", "amount" => 1000},
             "label" => "create deal"},
          %{"id" => 2, "kind" => "output", "label" => "Echo deal id",
             "emit" => %{"deal_id" => "{{1.deal_id}}"}}
        ],
        [%{"name" => "contact_id", "type" => "string"}]
      )

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Implicit emit WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
    end

    test "implicit emit doesn't permit unknown keys — `{{N.<typo>}}` still rejected",
         %{ctx: ctx} do
      ir = ir_with_trigger(
        [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.deal.create",
             "args"  => %{"contact_id" => "{{T.contact_id}}", "amount" => 1000},
             "label" => "create deal"},
          %{"id" => 2, "kind" => "output", "label" => "Wrong key",
             "emit" => %{"oops" => "{{1.deal_typo}}"}}
        ],
        [%{"name" => "contact_id", "type" => "string"}]
      )

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad implicit WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)

      assert msg =~ "doesn't declare emit"
      assert msg =~ "deal_typo"
      assert msg =~ "manifest `returns:`"
    end
  end

  describe "arm + disarm + invoke" do
    test "arm pins to current_version; upsert auto-bumps; disarm clears",
         %{ctx: ctx} do
      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Armable WF",
          "description"  => "Test workflow placeholder description used by integration tests.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      # Not yet armed → invoke targets current_version. A manual
      # invoke is the caller explicitly authorising one run;
      # arming is orthogonal, only required for autonomous
      # triggers. See arch_wiki/dmh_ai/sme/layer-W.md §Running a
      # saved workflow.
      assert {:ok, %{"version" => 0, "task_id" => _}} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)

      wf_before_arm = Workflows.get_workflow(@org_id, slug)
      assert wf_before_arm.active_version == nil,
             "manual invoke must NOT auto-arm — arming is for autonomous triggers"

      # Arm — no version arg; always pins to current_version.
      assert {:ok, %{"armed_version" => 0, "current_version" => 0}} =
               ArmWorkflow.execute(%{"name" => slug}, ctx)

      wf = Workflows.get_workflow(@org_id, slug)
      assert wf.active_version == 0

      # Upsert a new version while armed → active_version
      # auto-bumps in lockstep so the autonomous trigger fires
      # the latest shape.
      {:ok, %{"version" => 1}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Armable WF",
          "name"         => slug,
          "description"  => "Updated test workflow description.",
          "ir"           => minimal_ir(),
          "change_note"  => "refinement"
        }, ctx)

      assert Workflows.get_workflow(@org_id, slug).active_version == 1,
             "upsert while armed must auto-bump active_version to the new latest"

      # Invoke after the upsert always targets the new current_version.
      assert {:ok, %{"version" => 1}} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)

      # Disarm → active_version = nil. Invoke still works (falls
      # through to current_version).
      assert {:ok, %{"armed" => false}} =
               DisarmWorkflow.execute(%{"name" => slug}, ctx)

      assert Workflows.get_workflow(@org_id, slug).active_version == nil

      assert {:ok, %{"version" => 1}} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)
    end

    test "arm with non-existent workflow returns specific error", %{ctx: ctx} do
      assert {:error, msg} =
               ArmWorkflow.execute(%{"name" => "ghost"}, ctx)
      assert msg =~ "no workflow named"
    end
  end

  describe "GET /workflows/:slug/:version handler" do
    test "returns workflow + version JSON", %{ctx: ctx, user_id: user_id} do
      {:ok, %{"name" => slug, "version" => 0}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Handler Test",
          "description"  => "Test workflow placeholder description used by integration tests.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      conn = Plug.Test.conn(:get, "/workflows/#{slug}/0")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = WorkflowsHandler.show(conn, user, slug, "0")

      assert res.status == 200
      body = Jason.decode!(res.resp_body)
      assert body["workflow"]["id"]               == slug
      assert body["workflow"]["current_version"]  == 0
      assert body["version"]["version"]           == 0
      assert body["version"]["change_note"]       == "initial"
      assert is_map(body["version"]["ir"])
      assert is_list(body["version"]["ir"]["nodes"])
    end

    test "returns 404 for unknown slug", %{ctx: _ctx, user_id: user_id} do
      conn = Plug.Test.conn(:get, "/workflows/ghost/0")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = WorkflowsHandler.show(conn, user, "ghost", "0")

      assert res.status == 404
      assert Jason.decode!(res.resp_body)["error"] == "workflow_not_found"
    end

    test "returns 404 for version that doesn't exist", %{ctx: ctx, user_id: user_id} do
      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Version Test",
          "description"  => "Test workflow placeholder description used by integration tests.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      conn = Plug.Test.conn(:get, "/workflows/#{slug}/99")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = WorkflowsHandler.show(conn, user, slug, "99")

      assert res.status == 404
      assert Jason.decode!(res.resp_body)["error"] == "version_not_found"
    end

    test "returns 400 for malformed version", %{user_id: user_id} do
      conn = Plug.Test.conn(:get, "/workflows/x/abc")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = WorkflowsHandler.show(conn, user, "x", "abc")

      assert res.status == 400
    end
  end

  describe "GET /workflows[?q=<prefix>] picker endpoint" do
    test "list path returns description on each workflow row",
         %{ctx: ctx, user_id: user_id} do
      {:ok, _} =
        UpsertWorkflow.execute(%{
          "display_name" => "Daily Inbox Digest",
          "description"  => "Summarises unread inbox messages on demand.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      conn = Plug.Test.conn(:get, "/workflows")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = WorkflowsHandler.list(conn, user)

      assert res.status == 200
      body = Jason.decode!(res.resp_body)
      [row | _] = body["workflows"]
      assert row["description"] =~ "Summarises unread"
      assert row["current_version"] == 0
    end

    test "?q=<prefix> matches display_name OR description, case-insensitive",
         %{ctx: ctx, user_id: user_id} do
      {:ok, _} =
        UpsertWorkflow.execute(%{
          "display_name" => "Daily Inbox Digest",
          "description"  => "Summarises unread inbox messages on demand.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      {:ok, _} =
        UpsertWorkflow.execute(%{
          "display_name" => "Lead Scoring Refresh",
          "description"  => "Recomputes lead scores from recent CRM activity.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      user = %{id: user_id, role: "user", org_id: @org_id}

      # Matches display_name.
      conn1 = Plug.Test.conn(:get, "/workflows?q=Inbox")
      conn1 = %{conn1 | remote_ip: {127,0,0,1}}
      res1 = WorkflowsHandler.list(conn1, user)
      body1 = Jason.decode!(res1.resp_body)
      assert length(body1["workflows"]) == 1
      assert hd(body1["workflows"])["display_name"] == "Daily Inbox Digest"

      # Matches description text only.
      conn2 = Plug.Test.conn(:get, "/workflows?q=score")
      conn2 = %{conn2 | remote_ip: {127,0,0,1}}
      res2 = WorkflowsHandler.list(conn2, user)
      body2 = Jason.decode!(res2.resp_body)
      assert length(body2["workflows"]) == 1
      assert hd(body2["workflows"])["display_name"] == "Lead Scoring Refresh"

      # Picker row carries trigger_inputs for downstream rewrite use.
      assert is_list(hd(body2["workflows"])["trigger_inputs"])
    end

    test "empty q returns all workflows", %{ctx: ctx, user_id: user_id} do
      {:ok, _} =
        UpsertWorkflow.execute(%{
          "display_name" => "One",
          "description"  => "First workflow description for the picker test.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      {:ok, _} =
        UpsertWorkflow.execute(%{
          "display_name" => "Two",
          "description"  => "Second workflow description for the picker test.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      conn = Plug.Test.conn(:get, "/workflows?q=")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = WorkflowsHandler.list(conn, user)

      body = Jason.decode!(res.resp_body)
      assert length(body["workflows"]) == 2
    end
  end

  describe "Commands.Parser — only /index and /memo" do
    test "/rwf is no longer a command — passes through as plain text" do
      assert :not_a_command = DmhAi.Commands.Parser.parse("/rwf")
      assert :not_a_command = DmhAi.Commands.Parser.parse("/run_workflow")
    end

    test "/bwf is no longer a command — natural-language path takes over" do
      assert :not_a_command = DmhAi.Commands.Parser.parse("/bwf scan email")
      assert :not_a_command = DmhAi.Commands.Parser.parse("/build_workflow X")
    end

    test "&<slug> tokens are NOT parsed at the command layer" do
      assert :not_a_command = DmhAi.Commands.Parser.parse("&daily_inbox summarise unread")
      assert :not_a_command = DmhAi.Commands.Parser.parse("run &daily_inbox now")
    end

    test "/index and /memo still work" do
      assert {:index, "https://example.com"} =
               DmhAi.Commands.Parser.parse("/index https://example.com")
      assert {:memo, "remember to test"} =
               DmhAi.Commands.Parser.parse("/memo remember to test")
    end
  end

  describe "invoke_workflow — required-input validation + return shape" do
    test "missing required trigger inputs are rejected with a structured envelope",
         %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [
              %{"name" => "score", "type" => "number"},
              %{"name" => "grader_email", "type" => "string"}
            ],
            "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"received" => "{{T.score}}"}}
        ]
      }

      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Validated WF",
          "description"  => "A workflow used to test required-input validation.",
          "ir"           => ir,
          "change_note"  => "initial"
        }, ctx)

      assert {:error, msg} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)
      assert msg =~ "missing required trigger inputs"
      assert msg =~ "score"
      assert msg =~ "grader_email"
      # Includes schema + instructions for the model to relay.
      assert msg =~ "Declared schema"
      assert msg =~ "Push back to the user"
    end

    test "partial inputs flag only the missing field", %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [
              %{"name" => "score", "type" => "number"},
              %{"name" => "grader_email", "type" => "string"}
            ],
            "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"received" => "{{T.score}}"}}
        ]
      }

      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Partial WF",
          "description"  => "A workflow used to test partial-input validation.",
          "ir"           => ir,
          "change_note"  => "initial"
        }, ctx)

      assert {:error, msg} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{"score" => 85}}, ctx)
      assert msg =~ "missing required trigger inputs"
      assert msg =~ "grader_email"
      refute msg =~ "score,"
    end

    test "all inputs supplied → invocation proceeds with new return shape",
         %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [%{"name" => "topic", "type" => "string"}],
            "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Echo",
            "emit" => %{"echoed" => "{{T.topic}}"}}
        ]
      }

      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Echo WF",
          "description"  => "A workflow that echoes the supplied topic.",
          "ir"           => ir,
          "change_note"  => "initial"
        }, ctx)

      assert {:ok, result} =
               InvokeWorkflow.execute(
                 %{"name" => slug, "inputs" => %{"topic" => "Q1 OKRs"}}, ctx)

      # Return fields the prompt instructs the model to surface.
      assert result["executor_status"] == "completed"
      assert result["run_url"]     =~ ~r{^/runs/[a-f0-9]+$}
      assert result["workflow_url"] == "/workflows/#{slug}/0"
      assert is_map(result["emits"])
    end

    test "nested dotted-name inputs resolve via map walk", %{ctx: ctx} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [%{"name" => "deal.id", "type" => "string"}],
            "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"echoed" => "{{T.deal.id}}"}}
        ]
      }

      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Nested WF",
          "description"  => "A workflow used to test nested dotted-name input resolution.",
          "ir"           => ir,
          "change_note"  => "initial"
        }, ctx)

      # Nested form satisfies the dotted requirement.
      assert {:ok, _} =
               InvokeWorkflow.execute(
                 %{"name" => slug, "inputs" => %{"deal" => %{"id" => "12345"}}}, ctx)

      # Flat dotted-key form also satisfies it.
      assert {:ok, _} =
               InvokeWorkflow.execute(
                 %{"name" => slug, "inputs" => %{"deal.id" => "12345"}}, ctx)
    end
  end

  describe "GET /runs/:run_id handler" do
    test "returns run state + outputs joined to the workflow IR",
         %{ctx: ctx, user_id: user_id} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [%{"name" => "topic", "type" => "string"}],
            "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Echo result",
            "emit" => %{"echoed" => "{{T.topic}}"}}
        ]
      }

      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Echo WF",
          "description"  => "A workflow used to test the run viewer endpoint.",
          "ir"           => ir,
          "change_note"  => "initial"
        }, ctx)

      assert {:ok, invoke_result} =
               InvokeWorkflow.execute(
                 %{"name" => slug, "inputs" => %{"topic" => "Q4 OKRs"}}, ctx)

      run_id = invoke_result["run_id"]

      conn = Plug.Test.conn(:get, "/runs/#{run_id}")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = RunsHandler.show(conn, user, run_id)

      assert res.status == 200
      body = Jason.decode!(res.resp_body)

      assert body["run"]["id"]          == run_id
      assert body["run"]["status"]       == "completed"
      assert body["run"]["workflow_id"]  == slug
      assert body["workflow"]["display_name"] == "Echo WF"

      # `outputs` joins output nodes to their resolved emits — the
      # primary "what did this run produce" surface.
      assert is_list(body["outputs"])
      [output | _] = body["outputs"]
      assert output["label"] == "Echo result"
      assert output["resolved"]["echoed"] == "Q4 OKRs"

      # all_emits gives the debug view across every node.
      assert is_list(body["all_emits"])
    end

    test "returns 404 for unknown run", %{user_id: user_id} do
      conn = Plug.Test.conn(:get, "/runs/ghost")
      conn = %{conn | remote_ip: {127,0,0,1}}
      user = %{id: user_id, role: "user", org_id: @org_id}
      res  = RunsHandler.show(conn, user, "ghost")

      assert res.status == 404
      assert Jason.decode!(res.resp_body)["error"] == "run_not_found"
    end

    test "returns 403 for cross-org read", %{ctx: ctx} do
      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Cross WF",
          "description"  => "A workflow used to test cross-org run viewer rejection.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      {:ok, invoke_result} =
        InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)

      run_id = invoke_result["run_id"]

      conn = Plug.Test.conn(:get, "/runs/#{run_id}")
      conn = %{conn | remote_ip: {127,0,0,1}}
      foreign_user = %{id: "other_user", role: "user", org_id: "other_org"}
      res = RunsHandler.show(conn, foreign_user, run_id)

      assert res.status == 403
      assert Jason.decode!(res.resp_body)["error"] == "forbidden"
    end
  end

  describe "Tools.ReadWorkflow" do
    test "reads current_version IR + metadata", %{ctx: ctx} do
      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Readable WF",
          "description"  => "A workflow used to verify read_workflow returns the latest IR.",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      assert {:ok, result} =
               DmhAi.Tools.ReadWorkflow.execute(%{"name" => slug}, ctx)

      assert result["name"]            == slug
      assert result["display_name"]    == "Readable WF"
      assert result["description"]     =~ "verify read_workflow"
      assert result["current_version"] == 0
      assert is_map(result["ir"])
      assert is_list(result["ir"]["nodes"])
      assert result["url"]             == "/workflows/#{slug}/0"
    end

    test "returns error for unknown slug", %{ctx: ctx} do
      assert {:error, msg} =
               DmhAi.Tools.ReadWorkflow.execute(%{"name" => "ghost"}, ctx)
      assert msg =~ "no workflow named"
    end

    test "after refinement, returns the LATEST version's IR + description",
         %{ctx: ctx} do
      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Edited WF",
          "description"  => "First description for the edit test.",
          "ir"           => minimal_ir(),
          "change_note"  => "v0"
        }, ctx)

      {:ok, %{"version" => 1}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Edited WF",
          "name"         => slug,
          "description"  => "Updated description after refinement.",
          "ir"           => minimal_ir(),
          "change_note"  => "v1"
        }, ctx)

      assert {:ok, result} =
               DmhAi.Tools.ReadWorkflow.execute(%{"name" => slug}, ctx)
      assert result["current_version"] == 1
      assert result["description"]     == "Updated description after refinement."
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp minimal_ir do
    # Output-only IR (trigger node + output node) — the smallest valid
    # workflow. Reach for a real connector function in a richer test.
    %{
      "nodes" => [
        %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
          "label" => "manual", "inputs" => [], "next" => 1},
        %{"id" => 1, "kind" => "output", "label" => "Done",
          "emit" => %{"ok" => true}}
      ],
      "outputs" => [%{"name" => "ok", "source" => "{{1.ok}}"}]
    }
  end

  # Helper for the validation tests: wraps a node list with a manual
  # trigger so the IR is well-formed for everything BUT the specific
  # shape error each test is probing.
  defp ir_with_trigger(nodes, inputs \\ []) when is_list(nodes) and is_list(inputs) do
    trigger = %{
      "id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
      "label" => "manual", "inputs" => inputs, "next" => 1
    }
    %{"nodes" => [trigger | nodes]}
  end
end
