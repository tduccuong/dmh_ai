# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WExecutorTest do
  @moduledoc """
  Layer W — deterministic executor integration tests.

  Coverage:

    * Output-only run completes immediately, writes
      workflow_run_state with status='completed'.
    * llm.compose synthetic step renders a templated string.
    * Branch node picks the matching `cases[]` or falls through
      to `else`.
    * Permission denial at compile time (cross-user `act_as_user_id`
      for a non-admin owner) emits the structured envelope.
    * Owner identity threads through: caller_ctx.user_id ==
      workflow.created_by for every dispatched step.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Workflows, Repo}
  alias DmhAi.Workflows.Executor
  alias DmhAi.Tools.UpsertWorkflow
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()

  setup do
    now = System.os_time(:second)
    uid = "exec_user_" <> T.uid()
    sid = "exec_sess_" <> T.uid()
    slug = Workflows.slugify("exec_test_wf_" <> T.uid())

    query!(Repo, """
    INSERT INTO users (id, email, name, password_hash, role, org_id, org_role,
                       created_at)
    VALUES (?, ?, NULL, 'x', 'user', ?, 'admin', ?)
    """, [uid, "#{uid}@test.local", @default_org, now])

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_run_state WHERE owner_user_id=?", [uid])
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [uid])
      query!(Repo, "DELETE FROM workflows WHERE created_by=?", [uid])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [uid])
      query!(Repo, "DELETE FROM users WHERE id=?", [uid])
    end)

    {:ok, ctx: %{user_id: uid, session_id: sid, org_id: @default_org}, slug: slug}
  end

  describe "output-only run" do
    test "completes immediately with the emit map", %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true, "stamp" => "fixed"}}
        ],
        "outputs" => [%{"name" => "ok", "source" => "{{1.ok}}"}]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Output-only test",
        "description"  => "Test placeholder description for the executor integration suite.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "test"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"
      emit = run.bindings["emits"]["1"]
      assert emit["ok"] == true
      assert emit["stamp"] == "fixed"
    end
  end

  describe "llm.compose synthetic step" do
    test "renders a template against the context map", %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step", "function" => "llm.compose",
            "label" => "Compose",
            "args" => %{
              "template" => "Hello {{name}}!",
              "context"  => %{"name" => "world"}
            },
            "emits" => %{"body" => "$.body"},
            "next" => 2},
          %{"id" => 2, "kind" => "output", "label" => "Done",
            "emit" => %{"text" => "{{1.body}}"}}
        ],
        "outputs" => [%{"name" => "text", "source" => "{{2.text}}"}]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Compose test",
        "description"  => "Test placeholder description for the executor integration suite.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "test"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"
      assert run.bindings["emits"]["2"]["text"] == "Hello world!"
    end
  end

  describe "branch node" do
    test "follows the matching case", %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [%{"name" => "n", "type" => "string"}],
            "next" => 1},
          %{"id" => 1, "kind" => "branch", "label" => "Switch",
            "cases" => [
              %{"when" => ~s({{T.n}} == "go"), "next" => 2}
            ],
            "else"  => %{"next" => 3}},
          %{"id" => 2, "kind" => "output", "label" => "Went",
            "emit" => %{"route" => "matched"}},
          %{"id" => 3, "kind" => "output", "label" => "Else",
            "emit" => %{"route" => "fallback"}}
        ],
        "outputs" => [%{"name" => "route", "source" => "{{2.route}}"}]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Branch test",
        "description"  => "Test placeholder description for the executor integration suite.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "test"
      }, ctx)

      {:ok, run_matched} =
        Executor.start_run(slug, 0, %{"n" => "go"}, %{org_id: @default_org, task_id: "t-m"})
      assert run_matched.status == "completed"
      assert run_matched.bindings["emits"]["2"]["route"] == "matched"

      {:ok, run_fallback} =
        Executor.start_run(slug, 0, %{"n" => "stop"}, %{org_id: @default_org, task_id: "t-f"})
      assert run_fallback.status == "completed"
      assert run_fallback.bindings["emits"]["3"]["route"] == "fallback"
    end
  end

  describe "owner identity threading" do
    test "workflow.created_by is the immutable owner",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes"   => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done", "emit" => %{"done" => true}}
        ],
        "outputs" => []
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Owner test",
        "description"  => "Test placeholder description for the executor integration suite.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      wf = Workflows.get_workflow(@default_org, slug)
      assert wf.created_by == ctx.user_id

      # A different user edits — owner stays the original.
      other = "exec_editor_" <> T.uid()
      query!(Repo, """
      INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at)
      VALUES (?, ?, NULL, 'x', 'user', ?, 'admin', ?)
      """, [other, "#{other}@test.local", @default_org, System.os_time(:second)])

      on_exit(fn -> query!(Repo, "DELETE FROM users WHERE id=?", [other]) end)

      other_ctx = %{ctx | user_id: other}
      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Owner test (edited by other)",
        "description"  => "Test placeholder description for the executor integration suite.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v1 by other"
      }, other_ctx)

      wf_after = Workflows.get_workflow(@default_org, slug)
      assert wf_after.created_by == ctx.user_id, "owner is immutable across edits"

      # The v1 row records the editor.
      v1 = Workflows.get_version(@default_org, slug, 1)
      assert v1.compiled_by_user_id == other
    end
  end

  describe "permission denial at compile time" do
    test "non-admin owner can't act_as another user's creds", %{ctx: ctx, slug: slug} do
      # Demote the test user to member; admin bypass would otherwise
      # silently let everything through.
      query!(Repo, "UPDATE users SET org_role='member', role='user' WHERE id=?",
             [ctx.user_id])

      other = "exec_other_" <> T.uid()
      query!(Repo, """
      INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at)
      VALUES (?, ?, NULL, 'x', 'user', ?, 'member', ?)
      """, [other, "#{other}@test.local", @default_org, System.os_time(:second)])

      on_exit(fn -> query!(Repo, "DELETE FROM users WHERE id=?", [other]) end)

      DmhAi.Tools.Dispatcher.register(DmhAi.Connectors.GoogleWorkspace)

      ir = %{
        "nodes"   => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step",
            "function" => "google_workspace.gmail.search",
            "act_as_user_id" => other,
            "args" => %{"query" => "is:unread newer_than:1d"},
            "label" => "Search GMail",
            "emits" => %{"messages" => "$.messages"},
            "next" => 2},
          %{"id" => 2, "kind" => "output", "label" => "Done",
            "emit" => %{"v" => "{{1.messages}}"}}
        ],
        "outputs" => []
      }

      assert {:error, msg} = UpsertWorkflow.execute(%{
        "display_name" => "Cross-user GW search",
        "description"  => "Test placeholder description for the executor integration suite.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "test"
      }, ctx)

      assert msg =~ "permission_denied"
      assert msg =~ "act_as_creds"
      # And NOT saved.
      assert Workflows.get_workflow(@default_org, slug) == nil
    end
  end

  describe "non-manual triggers (poll / webhook)" do
    test "manual trigger still passes through to next without firing anything",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Manual passthrough",
        "description"  => "Manual trigger passes through unchanged for backwards compat.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "test"
      }, ctx)

      {:ok, run} =
        Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})

      assert run.status == "completed"
      # Node 0 is the trigger — manual triggers DON'T leave emits, only
      # `bindings.trigger`. Output node ran fine.
      assert run.bindings["emits"]["1"]["ok"] == true
      refute Map.has_key?(run.bindings["emits"], "0")
    end

    test "webhook trigger binds invoke_workflow's inputs as node 0 emits",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "webhook",
            "event" => "test.event",
            "label" => "Webhook fire",
            "emits" => %{"deal_id" => "$.deal_id", "amount" => "$.amount"},
            "next"  => 1},
          %{"id" => 1, "kind" => "output", "label" => "Echo",
            "emit" => %{"got_deal" => "{{0.deal_id}}", "got_amount" => "{{0.amount}}"}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Webhook test",
        "description"  => "Webhook trigger binds the synthetic event payload as node 0 emits.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "test"
      }, ctx)

      # invoke_workflow's `inputs` carries the synthetic event payload.
      payload = %{"deal_id" => "DEAL-42", "amount" => 9000}

      {:ok, run} =
        Executor.start_run(slug, 0, payload, %{org_id: @default_org, task_id: "t-#{slug}"})

      assert run.status == "completed"
      assert run.bindings["emits"]["0"]["deal_id"] == "DEAL-42"
      assert run.bindings["emits"]["0"]["amount"]  == 9000
      # Bare refs in output `emit` preserve typed values (string stays
      # string, integer stays integer).
      assert run.bindings["emits"]["1"]["got_deal"]   == "DEAL-42"
      assert run.bindings["emits"]["1"]["got_amount"] == 9000
    end

    test "poll trigger missing connector_function is rejected at upsert time",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "poll",
            # `connector_function` deliberately omitted — validator must
            # reject up front, not let it slip through to run time.
            "every_seconds" => 300,
            "label" => "Poll (misconfigured)",
            "next"  => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      assert {:error, msg} = UpsertWorkflow.execute(%{
        "display_name" => "Poll missing connector_function",
        "description"  => "Poll trigger without a connector_function — should fail validation.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "test"
      }, ctx)

      assert msg =~ "must declare `connector_function`"
    end
  end
end
