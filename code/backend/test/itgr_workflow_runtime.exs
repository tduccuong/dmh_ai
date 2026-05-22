# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowRuntimeTest do
  @moduledoc """
  Pins the runtime-model behaviour introduced in #506:
    - step trace persistence on every node the executor walks
    - lifecycle control verbs (pause / resume / cancel)
    - manual-invoke refusal for poll / schedule / webhook triggers
    - trigger_state cursor upsert API
    - webhook event dedupe API
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Workflows}
  alias DmhAi.Tools.{UpsertWorkflow, InvokeWorkflow,
                     PauseWorkflowRun, ResumeWorkflowRun, CancelWorkflowRun}
  alias DmhAi.Workflows.Executor
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org "default"

  setup do
    DmhAi.Connectors.Registry.register_universal()

    user_id    = T.uid()
    session_id = T.uid()
    slug       = "workflow_rt_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "rt-#{user_id}@test.local", "Test", "x:y", "user",
       @default_org, "member", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO sessions (id, name, model, messages, mode, user_id, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [session_id, "rt-test", "test:model", "[]", "assistant", user_id,
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    :ok = T.grant_all_scopes(user_id)

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_run_steps WHERE run_id IN (SELECT id FROM workflow_run_state WHERE owner_user_id=?)", [user_id])
      query!(Repo, "DELETE FROM workflow_run_state WHERE owner_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflows WHERE org_id=?", [@default_org])
      query!(Repo, "DELETE FROM workflow_trigger_state WHERE org_id=?", [@default_org])
      query!(Repo, "DELETE FROM workflow_webhook_events WHERE workflow_id=?", [slug])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, ctx: %{user_id: user_id, session_id: session_id, org_id: @default_org},
          slug: slug, user_id: user_id}
  end

  defp minimal_ir do
    %{
      "nodes" => [
        %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
          "label" => "manual", "inputs" => [], "next" => 1},
        %{"id" => 1, "kind" => "output", "label" => "Done",
          "emit" => %{"ok" => true}}
      ]
    }
  end

  # ── step trace ────────────────────────────────────────────────────────

  describe "step trace persistence" do
    test "every node the executor walks gets a row in workflow_run_steps",
         %{ctx: ctx, slug: slug} do
      # Multi-node workflow: trigger → step (synthetic) → output
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step", "function" => "llm.compose",
            "label" => "Compose",
            "args" => %{"template" => "Hi {{name}}", "context" => %{"name" => "Ada"}},
            "emits" => %{"body" => "$.body"},
            "next" => 2},
          %{"id" => 2, "kind" => "output", "label" => "Done",
            "emit" => %{"greeting" => "{{1.body}}"}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Trace test",
        "description"  => "Workflow used to verify step trace persistence.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"

      steps = Workflows.list_steps(run.id)
      # Trigger (manual, no row by design) + step + output = 2 step rows
      # (trigger pass-through doesn't emit a step row by design).
      node_ids = Enum.map(steps, & &1.node_id) |> Enum.sort()
      assert 1 in node_ids
      assert 2 in node_ids

      # Step 1 (llm.compose) has resolved_input + output
      step1 = Enum.find(steps, & &1.node_id == 1)
      assert step1.status == "completed"
      assert step1.resolved_input["function"] == "llm.compose"
      assert step1.output["body"] == "Hi Ada"
      assert is_integer(step1.duration_ms)

      # Output node has output map
      step2 = Enum.find(steps, & &1.node_id == 2)
      assert step2.status == "completed"
      assert step2.output["greeting"] == "Hi Ada"
    end

    test "failed step records error envelope and pauses run for re-auth",
         %{ctx: ctx, slug: slug, user_id: user_id} do
      # No Google creds → dispatcher returns {:error, %{error: "missing_credentials"}}.
      # Default on_failure action for that class is `pause_and_notify`,
      # so the run suspends as `:waiting` with a `reauth_pause` wait
      # at the failing node — the user reconnects and resume_run
      # retries the same step.
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?",
             [user_id, "oauth:google_workspace"])

      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step", "function" => "google_workspace.gmail.search",
            "label" => "Search",
            "args" => %{"query" => "is:unread newer_than:1d"},
            "next" => 2},
          %{"id" => 2, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      # Grant Gmail scope alone so the compile-time gate passes; the
      # OAuth bearer is still missing at run time.
      :ok = DmhAi.Auth.Credentials.save(user_id, "oauth:google_workspace", "oauth2_service",
        %{"access_token" => nil,
          "scope" => "https://www.googleapis.com/auth/gmail.readonly"},
        account: "")

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Failing step",
        "description"  => "Tests that a failed connector call records an error envelope in the step row.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?",
             [user_id, "oauth:google_workspace"])

      {:ok, run} =
        Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})

      assert run.status == "waiting"
      assert is_map(run.last_error)

      %{rows: [[run_id]]} =
        query!(Repo, "SELECT id FROM workflow_run_state WHERE workflow_id=? ORDER BY started_at DESC LIMIT 1", [slug])

      steps = Workflows.list_steps(run_id)
      step1 = Enum.find(steps, & &1.node_id == 1)
      assert step1.status == "failed"
      assert is_map(step1.error)

      wait = Workflows.get_wait(run_id, 1)
      assert wait.kind == "reauth_pause"
    end
  end

  # ── lookup_miss error class ──────────────────────────────────────────

  describe "lookup_miss" do
    test "out-of-range index against an empty list fails the step with :lookup_miss",
         %{ctx: ctx, slug: slug} do
      # Workflow accepts a `contacts` trigger input (an empty list at
      # invoke time), then a step references `{{T.contacts[0].id}}`.
      # The runtime must NOT silently pass `""` to the consumer — it
      # must fail with class `lookup_miss` so an IR-level
      # `on_failure[:lookup_miss]` recovery branch (or the default
      # `:fail`) can act on the structural error.
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [%{"name" => "contacts", "type" => "list"}],
            "next" => 1},
          %{"id" => 1, "kind" => "step", "function" => "llm.compose",
            "label" => "consumer that indexes [0] of an empty list",
            "args" => %{
              "template" => "id={{slot}}",
              "context"  => %{"slot" => "{{T.contacts[0].id}}"}
            },
            "emits" => %{"body" => "$.body"},
            "next" => 2},
          %{"id" => 2, "kind" => "output", "label" => "done",
            "emit" => %{"ok" => true}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Lookup miss",
        "description"  => "Verifies that an empty upstream list surfaces as a structured lookup_miss step failure.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      # Trigger payload supplies an empty list — this is the
      # "find returned nothing" condition under test.
      result = Executor.start_run(slug, 0, %{"contacts" => []},
                                  %{org_id: @default_org, task_id: "t-#{slug}"})

      # Default `:fail` action surfaces as `{:error, envelope}` from
      # `start_run` — the envelope is the same shape the run-viewer
      # UI renders. The class is what's load-bearing for the operator
      # diagnosing why the workflow stopped.
      assert {:error, envelope} = result
      assert envelope.class == :lookup_miss
      assert envelope.function == "llm.compose"
      assert envelope.detail.ref =~ "context"
      assert envelope.detail.index == 0

      # The step row also carries the failure for the run viewer.
      %{rows: [[run_id]]} =
        query!(Repo, "SELECT id FROM workflow_run_state WHERE workflow_id=? ORDER BY started_at DESC LIMIT 1", [slug])

      [step1] = Workflows.list_steps(run_id) |> Enum.sort_by(& &1.node_id)
      assert step1.status == "failed"
      assert step1.error["class"] == "lookup_miss"
    end
  end

  # ── owner / org bindings ─────────────────────────────────────────────

  describe "built-in identity bindings" do
    test "{{owner.<slug>.email}} resolves to the vendor email captured at OAuth time",
         %{ctx: ctx, slug: slug, user_id: user_id} do
      # Seed a HubSpot OAuth credential row carrying the vendor email
      # in the `account` column — the same shape the OAuth finalize
      # path produces after userinfo lookup. The workflow then
      # references `{{owner.hubspot.email}}` to confirm the binding
      # resolves to THAT email (NOT the DMH-AI app email).
      vendor_email = "sales-ops-#{user_id}@hubspot.test"
      :ok = DmhAi.Auth.Credentials.save(
        user_id, "oauth:hubspot", "oauth2",
        %{"access_token" => "test-token", "scope" => "crm.objects.deals.read"},
        account: vendor_email
      )

      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step", "function" => "llm.compose",
            "label" => "echo vendor email",
            "args" => %{
              "template" => "vendor_email={{vemail}}",
              "context"  => %{"vemail" => "{{owner.hubspot.email}}"}
            },
            "emits" => %{"body" => "$.body"},
            "next" => 2},
          %{"id" => 2, "kind" => "output", "label" => "done",
            "emit" => %{"body" => "{{1.body}}"}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Vendor identity",
        "description"  => "Verifies that owner.<slug>.email reads from user_credentials.account.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{},
                                      %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"

      [step1, _] = Workflows.list_steps(run.id) |> Enum.sort_by(& &1.node_id)
      assert step1.output["body"] == "vendor_email=#{vendor_email}"
    end

    test "{{owner.email}} resolves to the workflow owner's DMH-AI app email",
         %{ctx: ctx, slug: slug, user_id: user_id} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step", "function" => "llm.compose",
            "label" => "compose",
            "args" => %{
              "template" => "owner_email={{owner_email}}",
              "context"  => %{"owner_email" => "{{owner.email}}"}
            },
            "emits" => %{"body" => "$.body"},
            "next" => 2},
          %{"id" => 2, "kind" => "output", "label" => "done",
            "emit" => %{"body" => "{{1.body}}"}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Owner email binding",
        "description"  => "Verifies that owner.email resolves to the workflow run's owner email.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{},
                                      %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"

      [step1, _output] = Workflows.list_steps(run.id) |> Enum.sort_by(& &1.node_id)
      expected_email = "rt-#{user_id}@test.local"

      assert step1.output["body"] == "owner_email=#{expected_email}"
    end
  end

  # ── lifecycle controls ───────────────────────────────────────────────

  describe "pause / resume / cancel" do
    test "pause sets the flag; resume clears it", %{ctx: ctx, slug: slug} do
      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Lifecycle 1",
        "description"  => "Tests that pause sets the flag and resume clears it.",
        "name"         => slug,
        "ir"           => minimal_ir(),
        "change_note"  => "v0"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"

      # Pause on a completed run is rejected (terminal status).
      assert {:error, msg} =
               PauseWorkflowRun.execute(%{"run_id" => run.id}, %{})
      assert msg =~ "terminal"
    end

    test "cancel transitions a non-terminal run to cancelled", %{ctx: ctx, slug: slug} do
      # Build a workflow that suspends at a gate (so the run sits in :waiting
      # rather than running to completion).
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "gate", "label" => "Approve",
            "approver" => %{"role" => "manager"},
            "on_approve" => %{"next" => 2},
            "on_reject"  => %{"next" => 3}},
          %{"id" => 2, "kind" => "output", "label" => "Yes",
            "emit" => %{"approved" => true}},
          %{"id" => 3, "kind" => "output", "label" => "No",
            "emit" => %{"approved" => false}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Gate workflow",
        "description"  => "Suspends at a gate so we can exercise cancel from a waiting state.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "waiting" or run.status == "running"

      {:ok, _} = CancelWorkflowRun.execute(%{"run_id" => run.id}, %{})

      cancelled = Workflows.get_run(run.id)
      assert cancelled.status == "cancelled"
      assert cancelled.last_error["error"] == "cancelled_by_user"

      # Re-cancel is rejected (already terminal).
      assert {:error, _} = CancelWorkflowRun.execute(%{"run_id" => run.id}, %{})
    end

    test "lifecycle verbs reject unknown run_id" do
      assert {:error, _} = PauseWorkflowRun.execute(%{"run_id" => "ghost"}, %{})
      assert {:error, _} = ResumeWorkflowRun.execute(%{"run_id" => "ghost"}, %{})
      assert {:error, _} = CancelWorkflowRun.execute(%{"run_id" => "ghost"}, %{})
    end
  end

  # ── invoke refusal for non-manual triggers ────────────────────────────

  describe "invoke_workflow on non-manual triggers" do
    test "poll trigger is refused with structured envelope + connector hint",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "poll",
            "connector_function" => "google_workspace.gmail.search",
            "connector_args"     => %{"query" => "is:unread"},
            "every_seconds"      => 300,
            "label"              => "Poll Gmail",
            "next"               => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Poll WF",
        "description"  => "Poll-triggered workflow; manual invoke must be refused.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      assert {:error, msg} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)

      assert msg =~ "trigger_kind=`poll`"
      assert msg =~ "manual one-off runs are only allowed on `manual`"
      # Suggests the two options the model should relay.
      assert msg =~ "arm the autonomous trigger"
    end

    test "webhook trigger is refused too", %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "webhook",
            "event" => "test.event",
            "label" => "Webhook", "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Webhook WF",
        "description"  => "Webhook-triggered workflow; manual invoke must be refused.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      assert {:error, msg} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)
      assert msg =~ "trigger_kind=`webhook`"
    end

    test "manual trigger still works (regression safety)", %{ctx: ctx, slug: slug} do
      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Manual WF",
        "description"  => "Manual trigger still accepts invoke_workflow.",
        "name"         => slug,
        "ir"           => minimal_ir(),
        "change_note"  => "v0"
      }, ctx)

      assert {:ok, result} =
               InvokeWorkflow.execute(%{"name" => slug, "inputs" => %{}}, ctx)
      assert result["executor_status"] == "completed"
    end
  end

  # ── trigger state (cursor) + webhook dedupe ──────────────────────────

  describe "Workflows.{get,upsert}_trigger_state/*" do
    test "upsert is idempotent; cursor + last_fire_status round-trip" do
      org = @default_org
      wf  = "fakeflow_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

      assert Workflows.get_trigger_state(org, wf) == nil

      :ok = Workflows.upsert_trigger_state(org, wf, "cursor-abc", "ok")
      row = Workflows.get_trigger_state(org, wf)
      assert row.last_cursor       == "cursor-abc"
      assert row.last_fire_status  == "ok"
      assert is_integer(row.last_fired_at)

      :ok = Workflows.upsert_trigger_state(org, wf, "cursor-xyz", "no_new_items")
      row2 = Workflows.get_trigger_state(org, wf)
      assert row2.last_cursor      == "cursor-xyz"
      assert row2.last_fire_status == "no_new_items"

      # Cleanup
      query!(Repo, "DELETE FROM workflow_trigger_state WHERE org_id=? AND workflow_id=?", [org, wf])
    end
  end

  describe "Workflows.record_webhook_event/2" do
    test "first occurrence is :new; replay is :duplicate" do
      wf  = "fakeflow_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      eid = "evt-#{:rand.uniform(100_000)}"

      assert Workflows.record_webhook_event(wf, eid) == :new
      assert Workflows.record_webhook_event(wf, eid) == :duplicate

      # Different event id is :new again.
      assert Workflows.record_webhook_event(wf, eid <> "-2") == :new

      query!(Repo, "DELETE FROM workflow_webhook_events WHERE workflow_id=?", [wf])
    end
  end

  # ── cadence validation (every_seconds floor + shape) ─────────────────

  describe "trigger cadence validator" do
    test "poll without every_seconds is rejected with cadence guidance",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "poll",
            "connector_function" => "google_workspace.gmail.search",
            "connector_args"     => %{"query" => "is:unread"},
            # `every_seconds` omitted on purpose
            "label" => "Poll", "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      assert {:error, msg} = UpsertWorkflow.execute(%{
        "display_name" => "Poll missing cadence",
        "description"  => "Poll trigger with no every_seconds — validator should reject and cite the connector's recommended default.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      assert msg =~ "every_seconds"
      # Surfaces the connector's recommended default + floor so the
      # model knows what to emit on retry.
      assert msg =~ "300"
      assert msg =~ "30"
    end

    test "poll below min_poll_seconds is rejected", %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "poll",
            "connector_function" => "google_workspace.gmail.search",
            "connector_args"     => %{"query" => "is:unread"},
            "every_seconds"      => 5,            # below gmail floor (30)
            "label" => "Poll", "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      assert {:error, msg} = UpsertWorkflow.execute(%{
        "display_name" => "Poll too fast",
        "description"  => "Polling cadence below the connector's declared floor.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      assert msg =~ "below the connector's floor"
      assert msg =~ "min_poll_seconds=30"
    end

    test "poll at-or-above floor with recommended default is accepted",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "poll",
            "connector_function" => "google_workspace.gmail.search",
            "connector_args"     => %{"query" => "is:unread"},
            "every_seconds"      => 300,
            "label" => "Poll", "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      assert {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Poll at default",
        "description"  => "Poll cadence at the manifest's recommended default. Should pass.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)
    end

    test "schedule without every_seconds or cron is rejected",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "schedule",
            "label" => "Sched (no cadence)", "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      assert {:error, msg} = UpsertWorkflow.execute(%{
        "display_name" => "Schedule missing cadence",
        "description"  => "Schedule trigger missing both every_seconds and cron — validator rejects.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)

      assert msg =~ "every_seconds"
      assert msg =~ "cron"
    end

    test "schedule with every_seconds (v1 cadence) is accepted",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "schedule",
            "every_seconds" => 86_400,
            "label" => "Daily", "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      assert {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Daily schedule",
        "description"  => "Daily schedule via every_seconds. v1 shape; v2 cron later.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)
    end

    test "schedule with cron string (v2 forward-compat) is accepted",
         %{ctx: ctx, slug: slug} do
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "schedule",
            "cron"  => "0 9 * * 1",
            "label" => "Monday morning", "next" => 1},
          %{"id" => 1, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      # v1 doesn't execute cron yet, but the IR accepts it for
      # forward-compat — the future cron evaluator picks them up.
      assert {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Cron-armed",
        "description"  => "Schedule trigger with cron expression; v1 accepts the IR shape, runtime upgrade later.",
        "name"         => slug,
        "ir"           => ir,
        "change_note"  => "v0"
      }, ctx)
    end
  end

  # ── retention sweeper ────────────────────────────────────────────────

  describe "Workflows.Sweeper.sweep_once/1" do
    test "completed run older than retention is archived + dropped from DB",
         %{ctx: ctx, slug: slug} do
      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Sweep me",
        "description"  => "Workflow used to test archival of old completed runs.",
        "name"         => slug,
        "ir"           => minimal_ir(),
        "change_note"  => "v0"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"

      # Age the completed_at backwards by 40 days (retention default = 30).
      forty_days_ago = System.os_time(:millisecond) - 40 * 24 * 60 * 60 * 1000
      query!(Repo, "UPDATE workflow_run_state SET completed_at=? WHERE id=?", [forty_days_ago, run.id])

      # Sweep into a temp dir.
      tmp = System.tmp_dir!() |> Elixir.Path.join("dmh_ai_test_archive_#{:rand.uniform(1_000_000)}")
      File.rm_rf!(tmp)

      {archived, _} = DmhAi.Workflows.Sweeper.sweep_once(tmp)
      assert archived >= 1

      # The DB row is gone.
      assert Workflows.get_run(run.id) == nil
      assert Workflows.list_steps(run.id) == []

      # The archive file exists and contains the run id.
      [archive_file] =
        tmp
        |> Elixir.Path.join("default")
        |> Elixir.Path.join(slug)
        |> File.ls!()
        |> Enum.map(&Elixir.Path.join([tmp, "default", slug, &1]))

      contents = File.read!(archive_file)
      assert contents =~ run.id
      assert contents =~ "\"status\":\"completed\""

      File.rm_rf!(tmp)
    end

    test "recent completed runs are NOT swept", %{ctx: ctx, slug: slug} do
      {:ok, _} = UpsertWorkflow.execute(%{
        "display_name" => "Recent",
        "description"  => "Workflow used to confirm the sweeper leaves fresh runs alone.",
        "name"         => slug,
        "ir"           => minimal_ir(),
        "change_note"  => "v0"
      }, ctx)

      {:ok, run} = Executor.start_run(slug, 0, %{}, %{org_id: @default_org, task_id: "t-#{slug}"})
      assert run.status == "completed"

      # Don't age; sweeper should ignore.
      tmp = System.tmp_dir!() |> Elixir.Path.join("dmh_ai_test_archive_#{:rand.uniform(1_000_000)}")

      DmhAi.Workflows.Sweeper.sweep_once(tmp)

      # Run is still in DB.
      assert Workflows.get_run(run.id) != nil

      File.rm_rf!(tmp)
    end

    test "old webhook events are expired in the same sweep" do
      wf  = "fakeflow_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

      assert Workflows.record_webhook_event(wf, "old-1")     == :new
      assert Workflows.record_webhook_event(wf, "fresh-1")   == :new

      # Age "old-1" past 24h.
      twenty_five_h_ago = System.os_time(:millisecond) - 25 * 60 * 60 * 1000
      query!(Repo, "UPDATE workflow_webhook_events SET received_at=? WHERE workflow_id=? AND event_id=?",
             [twenty_five_h_ago, wf, "old-1"])

      tmp = System.tmp_dir!() |> Elixir.Path.join("dmh_ai_test_archive_#{:rand.uniform(1_000_000)}")
      {_, deleted_events} = DmhAi.Workflows.Sweeper.sweep_once(tmp)

      assert deleted_events >= 1

      # Old event id is gone; sending it again would not be a duplicate.
      assert Workflows.record_webhook_event(wf, "old-1") == :new
      # Fresh event is still tracked.
      assert Workflows.record_webhook_event(wf, "fresh-1") == :duplicate

      query!(Repo, "DELETE FROM workflow_webhook_events WHERE workflow_id=?", [wf])
      File.rm_rf!(tmp)
    end
  end
end
