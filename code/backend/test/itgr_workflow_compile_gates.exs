# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.WorkflowCompileGatesTest do
  @moduledoc """
  Pins the two new compile-time gates on `upsert_workflow`:

    * **Pass 4 — scope gate** (L3 in arch_wiki/dmh_ai/sme/layer-W.md):
      reject the save when the workflow's required OAuth scopes
      aren't already granted on the owner's credentials.

    * **Pass 5 — placeholder soundness** (L5): reject literal args
      that look like sentinels (`""`, `"1"`, `"x"`, `"unknown"`,
      `0` on quantity-named args, …) on required arg positions.

  Both fire BEFORE persist so a broken IR never reaches
  `workflow_versions`.
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

  defp ir_with_step(args) do
    %{
      "nodes" => [
        %{"id" => 0, "kind" => "trigger", "trigger_kind" => "manual",
          "label" => "manual",
          "inputs" => [%{"name" => "alt", "type" => "string"}],
          "next" => 1},
        %{"id" => 1, "kind" => "step",
          "function" => "hubspot.deal.create",
          "args"     => args,
          "label"    => "create"},
        %{"id" => 2, "kind" => "output", "label" => "done",
          "emit" => %{"ok" => true}}
      ]
    }
  end

  describe "Pass 4 — scope gate" do
    test "rejects when the owner has no creds on the required slug", %{ctx: ctx} do
      # No T.grant_all_scopes/1 call → no creds → gate fires.
      ir = ir_with_step(%{"contact_id" => "{{T.alt}}", "amount" => 1500})

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

      ir = ir_with_step(%{"contact_id" => "{{T.alt}}", "amount" => 1500})

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
      :ok = Credentials.save(user_id, "oauth:hubapi.com", "oauth2",
                             %{"access_token" => "t",
                               "scope" => "crm.objects.deals.read"},
                             account: "")

      ir = ir_with_step(%{"contact_id" => "{{T.alt}}", "amount" => 1500})

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

  describe "Pass 5 — placeholder soundness" do
    setup %{user_id: user_id} do
      # Scopes granted so the placeholder check is what catches
      # these tests — not the scope gate.
      :ok = T.grant_all_scopes(user_id)
      :ok
    end

    test "rejects single-character literal on a required string arg", %{ctx: ctx} do
      ir = ir_with_step(%{"contact_id" => "1", "amount" => 1500})

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad contact_id WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "placeholder-shaped value"
      assert msg =~ "contact_id"
    end

    test "rejects zero on quantity-named required args", %{ctx: ctx} do
      ir = ir_with_step(%{"contact_id" => "{{T.alt}}", "amount" => 0})

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad amount WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "amount"
    end

    test "rejects known placeholder tokens", %{ctx: ctx} do
      ir = ir_with_step(%{"contact_id" => "unknown", "amount" => 1500})

      assert {:error, msg} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bad token WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)

      assert msg =~ "placeholder-shaped value"
    end

    test "passes when required args are bindings, not literals", %{ctx: ctx} do
      ir = ir_with_step(%{"contact_id" => "{{T.alt}}", "amount" => 1500})

      assert {:ok, %{"version" => 0}} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Bound args WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)
    end

    test "passes when a literal is genuine (non-placeholder)", %{ctx: ctx} do
      # `amount: 1500` is a legitimate literal — not in the
      # placeholder set. `contact_id` is a trigger binding.
      ir = ir_with_step(%{"contact_id" => "{{T.alt}}", "amount" => 1500})

      assert {:ok, _} =
               UpsertWorkflow.execute(%{
                 "display_name" => "Genuine literal WF",
                 "description"  => "Test workflow placeholder description used by integration tests.",
                 "ir"           => ir,
                 "change_note"  => "v0"
               }, ctx)
    end
  end
end
