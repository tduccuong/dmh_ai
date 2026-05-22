# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowCompileGatesTest do
  @moduledoc """
  Pins the compile-time scope gate on `upsert_workflow`:

    * **Pass 4 — scope gate** (L3 in arch_wiki/dmh_ai/sme/layer-W.md):
      reject the save when the workflow's required OAuth scopes
      aren't already granted on the owner's credentials.

  Fires BEFORE persist so a broken IR never reaches
  `workflow_versions`. (The previous "Pass 5 — placeholder
  soundness" heuristic is gone — provenance annotations on the
  manifest now carry every constraint the validator needs; a
  catch-all literal-shape regex was both false-positive-prone
  and a clash with `:literal_default` defaults like `amount: 0`.)
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Auth.Credentials}
  alias DmhAi.Tools.UpsertWorkflow
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id "default"

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "gate-#{user_id}@test.local", "Test", "x:y", "user",
       @org_id, "member", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO sessions (id, name, model, messages, mode, user_id, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [session_id, "gate-test", "test:model", "[]", "assistant", user_id,
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflows WHERE org_id=?", [@org_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, user_id: user_id,
          ctx: %{user_id: user_id, session_id: session_id, org_id: @org_id}}
  end

  # Compose a minimal valid `hubspot.deal.create` workflow: trigger
  # supplies the contact's email, an upstream `hubspot.contact.find`
  # step resolves it to the contact id, then deal.create binds the
  # found id. `args_override` lets a test customise `deal.create`
  # args (amount, name, …) while keeping the lookup chain intact.
  defp ir_with_step(args_override) do
    deal_args = Map.merge(%{
      "amount"     => 1500,
      "contact_id" => "{{1.contacts[0].id}}"
    }, args_override)

    %{
      "nodes" => [
        %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
          "label" => "manual",
          "inputs" => [%{"name" => "contact_email", "type" => "string"}],
          "next" => 1},
        %{"id" => 1, "kind" => "step",
          "function" => "hubspot.contact.find",
          "args"     => %{"query" => "{{T.contact_email}}"},
          "label"    => "find",
          "next"     => 2},
        %{"id" => 2, "kind" => "step",
          "function" => "hubspot.deal.create",
          "args"     => deal_args,
          "label"    => "create"},
        %{"id" => 3, "kind" => "output", "label" => "done",
          "emit" => %{"ok" => true}}
      ]
    }
  end

  describe "Pass 4 — scope gate" do
    test "rejects when the owner has no creds on the required slug", %{ctx: ctx} do
      # No T.grant_all_scopes/1 call → no creds → gate fires.
      ir = ir_with_step(%{})

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Scope test WF",
                 "description"  => "A workflow used to test the compile-time scope gate.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "OAuth scopes"
      assert msg =~ "hubspot"
      assert msg =~ "crm.objects.deals.write"
      assert msg =~ "Reconnect"
    end

    test "passes when all required scopes are granted", %{ctx: ctx, user_id: user_id} do
      :ok = T.grant_all_scopes(user_id)

      ir = ir_with_step(%{})

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Scope happy WF",
                 "description"  => "A workflow used to test the compile-time scope gate happy path.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)
    end

    test "still gates when partial scopes are granted (missing one rejects)",
         %{ctx: ctx, user_id: user_id} do
      # Grant only one of the deal-create scopes — the gate must
      # still fire on the other required scope.
      :ok = Credentials.save(user_id, "oauth:hubspot", "oauth2",
                             %{"access_token" => "t",
                               "scope" => "crm.objects.deals.read"},
                             account: "")

      ir = ir_with_step(%{})

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Partial scope WF",
                 "description"  => "A workflow used to test partial scope coverage.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "crm.objects.deals.write"
    end
  end

  describe "lookup provenance" do
    setup %{user_id: user_id} do
      :ok = T.grant_all_scopes(user_id)
      :ok
    end

    test "rejects a literal id on a :lookup arg", %{ctx: ctx} do
      # `hubspot.deal.create.contact_id` is `:lookup` from
      # `hubspot.contact.find`. A literal id can't satisfy that.
      ir = ir_with_step(%{"contact_id" => "12345"})

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad contact_id WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "violates its declared provenance"
      assert msg =~ "contact_id"
      assert msg =~ "hubspot.contact.find"
    end

    test "rejects a trigger-input shortcut on a :lookup arg", %{ctx: ctx} do
      # The pre-tightening validator accepted `{{T.<x>}}` as a
      # shortcut for `:lookup` — that let the model skip the
      # upstream find step entirely and ask the user for the
      # vendor-internal id. Now forbidden.
      ir = %{
        "nodes" => [
          %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
            "label" => "manual",
            "inputs" => [%{"name" => "contact_id", "type" => "string"}],
            "next" => 1},
          %{"id" => 1, "kind" => "step",
            "function" => "hubspot.deal.create",
            "args"     => %{"contact_id" => "{{T.contact_id}}", "amount" => 1500},
            "label"    => "create"},
          %{"id" => 2, "kind" => "output", "label" => "done",
            "emit" => %{"ok" => true}}
        ]
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Shortcut WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "violates its declared provenance"
      assert msg =~ "user typically doesn't know vendor-internal ids"
    end

    test "passes when :lookup args bind to an upstream emit", %{ctx: ctx} do
      ir = ir_with_step(%{})

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Lookup happy WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)
    end
  end

  describe "removed bindings" do
    setup %{user_id: user_id} do
      :ok = T.grant_all_scopes(user_id)
      :ok
    end

    test "rejects `{{org.me.<x>}}` with a remediation hint", %{ctx: ctx} do
      # `{{org.me.email}}` was an alias that resolved to the owner's
      # DMH-AI app email. The alias was removed in favour of the
      # canonical `{{owner.email}}` (DMH-AI app) /
      # `{{owner.<slug>.email}}` (vendor identity). The validator must
      # reject the legacy form so model-authored IRs that still carry
      # it get migrated explicitly rather than silently resolving to "".
      ir = ir_with_step(%{})
      # Inject a legacy ref into hubspot.contact.find's query.
      ir = %{ir |
        "nodes" =>
          ir["nodes"]
          |> Enum.map(fn
            %{"function" => "hubspot.contact.find"} = n ->
              put_in(n, ["args", "query"], "{{org.me.email}}")
            other -> other
          end)
      }

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Legacy ref WF",
                 "description"  => "Verifies the validator rejects `{{org.me.<x>}}` refs.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "`{{org.me."
      assert msg =~ "{{owner."
    end
  end
end
