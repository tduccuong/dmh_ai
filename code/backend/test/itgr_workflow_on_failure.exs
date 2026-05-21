# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowOnFailureTest do
  @moduledoc """
  Pins the executor's per-step `on_failure:` routing — Layer 4 of the
  Runtime self-sufficiency design (see arch_wiki/dmh_ai/sme/layer-W.md).
  The runtime selects an action per error class:

    * `:fail` — default for most classes — terminates the run with
      the envelope.
    * `:pause_and_notify` — default for `:unauthorised` / `:missing_credentials`
      — suspends the run as `:waiting` so the user can reconnect and
      `resume_workflow_run` retries the SAME step.
    * `{next: <id>}` — explicit IR override; routes to a recovery node
      inline.

  The connector under test is the in-process `google_workspace.gmail.search`
  with no credentials authorized — it always returns
  `{:error, %{error: "missing_credentials", ...}}` from the dispatcher.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Workflows}
  alias DmhAi.Workflows.Executor
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id "default"

  setup do
    # Other tests (`itgr_p03_*`, `flows/F38_*`) call `Dispatcher.reset/0`
    # to swap in stub connectors and don't restore the universals on
    # teardown. Re-register here so this test's connector dispatch
    # finds `google_workspace.gmail.search` regardless of suite order.
    DmhAi.Connectors.Registry.register_universal()

    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "onfail-#{user_id}@test.local", "Test", "x:y", "user",
       @org_id, "member", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO sessions (id, name, model, messages, mode, user_id, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [session_id, "onfail-test", "test:model", "[]", "assistant", user_id,
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    # Grant scopes so the compile-time scope gate doesn't reject —
    # we want failures at RUN time (no creds → missing_credentials)
    # not save time.
    :ok = T.grant_all_scopes(user_id)

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_run_steps WHERE run_id IN (SELECT id FROM workflow_run_state WHERE owner_user_id=?)", [user_id])
      query!(Repo, "DELETE FROM workflow_run_state WHERE owner_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflows WHERE org_id=?", [@org_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, user_id: user_id, session_id: session_id,
          ctx: %{user_id: user_id, session_id: session_id, org_id: @org_id}}
  end

  defp save_ir_directly(ctx, slug, ir) do
    # Bypass `upsert_workflow`'s shape validator so we can drive the
    # executor with raw IR shapes (these tests verify run-time
    # routing, not the compile-time path).
    {:ok, _} = DmhAi.Workflows.upsert(%{
      org_id:       @org_id,
      id:           slug,
      display_name: "On-failure test #{slug}",
      description:  "On-failure routing test",
      ir:           ir,
      change_note:  "test",
      session_id:   ctx.session_id,
      user_id:      ctx.user_id
    })

    slug
  end

  describe "default routing — no on_failure declared" do
    test "missing_credentials → pause_and_notify (waiting status)",
         %{ctx: ctx, user_id: user_id} do
      slug = "wf_pause_default_#{:rand.uniform(99_999)}"
      # Clear creds so the dispatcher returns missing_credentials.
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])

      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step",
            "function" => "google_workspace.gmail.search",
            "label"    => "Search Gmail",
            "args"     => %{"query" => "is:unread"},
            "next"     => 2},
          %{"id" => 2, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      save_ir_directly(ctx, slug, ir)
      assert {:ok, run} =
               Executor.start_run(slug, 0, %{}, %{org_id: @org_id, task_id: "t-#{slug}"})

      assert run.status == "waiting",
             "default action for missing_credentials must pause (got #{run.status})"

      wait = Workflows.get_wait(run.id, 1)
      assert wait.kind == "reauth_pause",
             "expected a reauth_pause wait at node 1, got #{inspect(wait)}"
    end
  end

  describe "explicit on_failure overrides" do
    test "`fail` overrides the pause default and terminates immediately",
         %{ctx: ctx, user_id: user_id} do
      slug = "wf_fail_override_#{:rand.uniform(99_999)}"
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])

      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step",
            "function" => "google_workspace.gmail.search",
            "args" => %{"query" => "is:unread"},
            "on_failure" => %{"missing_credentials" => "fail"},
            "label" => "Search",
            "next"  => 2},
          %{"id" => 2, "kind" => "output", "label" => "Done",
            "emit" => %{"ok" => true}}
        ]
      }

      save_ir_directly(ctx, slug, ir)
      assert {:error, _} =
               Executor.start_run(slug, 0, %{}, %{org_id: @org_id, task_id: "t-#{slug}"})

      %{rows: [[run_id, status]]} =
        query!(Repo,
          "SELECT id, status FROM workflow_run_state WHERE workflow_id=? " <>
            "ORDER BY started_at DESC LIMIT 1", [slug])

      assert status == "failed", "expected failed, got #{status} (run=#{run_id})"
    end

    test "`{next: N}` routes to the recovery node inline",
         %{ctx: ctx, user_id: user_id} do
      slug = "wf_next_branch_#{:rand.uniform(99_999)}"
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])

      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual", "inputs" => [], "next" => 1},
          %{"id" => 1, "kind" => "step",
            "function" => "google_workspace.gmail.search",
            "args" => %{"query" => "is:unread"},
            "on_failure" => %{"missing_credentials" => %{"next" => 3}},
            "label" => "Try Gmail",
            "next"  => 2},
          %{"id" => 2, "kind" => "output", "label" => "Happy",
            "emit" => %{"path" => "happy"}},
          %{"id" => 3, "kind" => "output", "label" => "Recovery",
            "emit" => %{"path" => "recovery"}}
        ]
      }

      save_ir_directly(ctx, slug, ir)
      assert {:ok, run} =
               Executor.start_run(slug, 0, %{}, %{org_id: @org_id, task_id: "t-#{slug}"})

      assert run.status == "completed"
      emits = run.bindings["emits"] || run.bindings[:emits] || %{}
      assert emits["3"]["path"] == "recovery",
             "expected recovery branch to fire; emits=#{inspect(emits)}"
    end
  end
end
