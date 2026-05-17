# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowsTest do
  @moduledoc """
  Integration tests for the Layer W workflow primitive.

  Covers:
    * `upsert_workflow` tool — first save lands at v0; repeat lands at v+1.
    * Slug derivation from display_name.
    * Shape validation rejects malformed IR (missing trigger / no nodes).
    * Deep validation rejects unknown function, missing required args,
      unknown args, and unbound Mustache references.
    * `arm_workflow` flips active_version; `disarm_workflow` clears it.
    * `invoke_workflow` returns the right shape for an unarmed workflow.
    * `GET /workflows/:slug/:version` returns the IR JSON.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Workflows}
  alias DmhAi.Tools.{UpsertWorkflow, ArmWorkflow, DisarmWorkflow, InvokeWorkflow}
  alias DmhAi.Handlers.Workflows, as: WorkflowsHandler
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

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflows WHERE org_id=?", [@org_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, user_id: user_id, session_id: session_id, ctx: %{user_id: user_id, session_id: session_id, org_id: @org_id}}
  end

  describe "upsert_workflow — basic" do
    test "first save lands at v0; same name re-saved bumps to v1", %{ctx: ctx} do
      ir = minimal_ir()

      assert {:ok, %{"version" => 0, "name" => "test_wf", "url" => "/workflows/test_wf/0"}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Test WF",
                 "name"         => "test_wf",
                 "ir"           => ir,
                 "change_note"  => "initial draft"
               }, ctx)

      assert {:ok, %{"version" => 1, "name" => "test_wf", "url" => "/workflows/test_wf/1"}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Test WF",
                 "name"         => "test_wf",
                 "ir"           => ir,
                 "change_note"  => "second save"
               }, ctx)
    end

    test "slug derived from display_name when name omitted", %{ctx: ctx} do
      assert {:ok, %{"name" => "daily_inbox_digest"}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Daily Inbox Digest!",
                 "ir"           => minimal_ir(),
                 "change_note"  => "initial"
               }, ctx)
    end
  end

  describe "upsert_workflow — shape validation rejects malformed IR" do
    test "missing trigger", %{ctx: ctx} do
      ir = %{"nodes" => [%{"id" => 1, "kind" => "output", "label" => "ok"}]}

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "trigger"
    end

    test "no nodes", %{ctx: ctx} do
      ir = %{"trigger" => %{"kind" => "manual"}, "nodes" => []}

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "at least one node"
    end

    test "duplicate node ids", %{ctx: ctx} do
      ir = %{
        "trigger" => %{"kind" => "manual"},
        "nodes" => [
          %{"id" => 1, "kind" => "output", "label" => "a"},
          %{"id" => 1, "kind" => "output", "label" => "b"}
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "duplicate node ids"
    end
  end

  describe "upsert_workflow — deep validation against connector catalog" do
    test "unknown function rejected", %{ctx: ctx} do
      ir = %{
        "trigger" => %{"kind" => "manual"},
        "nodes" => [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.does_not_exist", "args" => %{}, "label" => "fake"}
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "unknown function"
      assert msg =~ "hubspot.does_not_exist"
    end

    test "real connector function with missing required args rejected", %{ctx: ctx} do
      # hubspot.contact.find requires `query` per the HubSpot manifest.
      ir = %{
        "trigger" => %{"kind" => "manual"},
        "nodes" => [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find", "args" => %{}, "label" => "find"}
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "missing required args"
      assert msg =~ "query"
    end

    test "unknown args (not in the function's manifest) rejected", %{ctx: ctx} do
      ir = %{
        "trigger" => %{"kind" => "manual"},
        "nodes" => [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find",
             "args" => %{"query" => "alice", "nonsense" => "x"}, "label" => "find"}
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "not in the function manifest"
      assert msg =~ "nonsense"
    end

    test "synthetic functions (llm.compose, builtin.compute) pass through", %{ctx: ctx} do
      ir = %{
        "trigger" => %{"kind" => "manual"},
        "nodes" => [
          %{"id" => 1, "kind" => "step", "function" => "llm.compose",      "args" => %{"template" => "x"}, "label" => "compose"},
          %{"id" => 2, "kind" => "step", "function" => "builtin.compute",  "args" => %{"formula" => "1+1"}, "label" => "math"}
        ]
      }

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Synth WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
    end

    test "unbound `{{T.x}}` reference (no matching trigger input) rejected", %{ctx: ctx} do
      ir = %{
        "trigger" => %{"kind" => "manual"},
        "inputs" => [%{"name" => "deal.id", "type" => "string"}],
        "nodes" => [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find",
             "args" => %{"query" => "{{T.nonexistent}}"}, "label" => "find"}
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
      assert msg =~ "T.nonexistent"
    end

    test "node-to-node `{{1.field}}` reference resolves when emits declares it", %{ctx: ctx} do
      ir = %{
        "trigger" => %{"kind" => "manual"},
        "nodes" => [
          %{"id" => 1, "kind" => "step", "function" => "hubspot.contact.find",
             "args"  => %{"query" => "alice"}, "emits" => %{"contact_id" => "$.contacts[0].id"},
             "label" => "find"},
          %{"id" => 2, "kind" => "step", "function" => "hubspot.deal.create",
             "args"  => %{"contact_id" => "{{1.contact_id}}", "amount" => 1000},
             "label" => "create deal"}
        ]
      }

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "OK WF",
                 "ir"           => ir,
                 "change_note"  => "test"
               }, ctx)
    end
  end

  describe "arm + disarm + invoke" do
    test "arm flips active_version; disarm clears it; invoke requires armed or explicit version",
         %{ctx: ctx} do
      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Armable WF",
          "ir"           => minimal_ir(),
          "change_note"  => "initial"
        }, ctx)

      # Not yet armed → invoke without version refuses.
      assert {:error, msg} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)
      assert msg =~ "not armed"

      # Arm v0.
      assert {:ok, %{"armed_version" => 0}} =
               ArmWorkflow.execute(%{"name" => slug, "version" => 0}, ctx)

      wf = Workflows.get_workflow(@org_id, slug)
      assert wf.active_version == 0

      # Invoke now succeeds.
      assert {:ok, %{"version" => 0, "task_id" => _}} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)

      # Disarm → active_version = nil.
      assert {:ok, %{"armed" => false}} =
               DisarmWorkflow.execute(%{"name" => slug}, ctx)

      assert Workflows.get_workflow(@org_id, slug).active_version == nil

      # Invoke can still target a specific version explicitly.
      assert {:ok, %{"version" => 0}} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}, "version" => 0}, ctx)
    end

    test "arm with non-existent workflow returns specific error", %{ctx: ctx} do
      assert {:error, msg} =
               ArmWorkflow.execute(%{"name" => "ghost", "version" => 0}, ctx)
      assert msg =~ "no workflow named"
    end
  end

  describe "GET /workflows/:slug/:version handler" do
    test "returns workflow + version JSON", %{ctx: ctx, user_id: user_id} do
      {:ok, %{"name" => slug, "version" => 0}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Handler Test",
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

  # ── helpers ──────────────────────────────────────────────────────────

  defp minimal_ir do
    %{
      "trigger" => %{"kind" => "manual"},
      "inputs"  => [],
      "nodes" => [
        %{
          "id"        => 1,
          "kind"      => "step",
          "function"  => "hubspot.contact.find",
          "args"      => %{"query" => "alice"},
          "label"     => "Find contact",
          "emits"     => %{"contact_id" => "$.contacts[0].id"}
        }
      ],
      "outputs" => [%{"name" => "contact_id", "source" => "{{1.contact_id}}"}]
    }
  end
end
