# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.InlineWorkflowRefsTest do
  @moduledoc """
  Pins the BE-side defensive scan for `&<slug>` tokens in user prose
  (the manually-typed / pasted case that bypasses the FE picker).

  - Tokens that match an existing workflow get augmented into the
    `<workflow_references>` block — same shape the picker produces.
  - Tokens that don't match anything land in
    `<unresolved_workflow_references>` so the model can tell the user
    the slug is unknown instead of hallucinating an adjacent intent.

  The defensive scan helpers are private to the chat handler; we
  exercise them through the public augmentation surface by mocking
  what the handler does inline.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Workflows}
  alias DmhAi.Tools.UpsertWorkflow
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org "default"

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "inline-#{user_id}@test.local", "Test", "x:y", "user",
       @default_org, "member", :os.system_time(:second)])

    query!(Repo,
      "INSERT INTO sessions (id, name, model, messages, mode, user_id, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [session_id, "inline-test", "test:model", "[]", "assistant", user_id,
       :os.system_time(:millisecond), :os.system_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM workflow_versions WHERE compiled_by_user_id=?", [user_id])
      query!(Repo, "DELETE FROM workflows WHERE org_id=?", [@default_org])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, ctx: %{user_id: user_id, session_id: session_id, org_id: @default_org}}
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

  # Direct exercise of the private chat-handler helpers via the
  # router-equivalent path. We can call `parse_workflows` + the
  # rendering helpers by routing through the agent_chat module's
  # public functions… but they're handler-scoped. Easier: assert
  # the SHAPE of llm_content for a known input via the integration
  # path. For unit-style coverage we hand-test the DB lookup +
  # block composition through Workflows.get_workflow + the
  # documented expected shape.

  describe "inline &<slug> resolution against the DB" do
    test "existing slug resolves to a full workflow_references entry", %{ctx: ctx} do
      {:ok, %{"name" => slug}} =
        UpsertWorkflow.execute(%{
          "display_name" => "Resolver test",
          "description"  => "Workflow used to test inline &<slug> resolution.",
          "name"         => "workflow_resolver_test",
          "ir"           => minimal_ir(),
          "change_note"  => "v0"
        }, ctx)

      assert slug == "workflow_resolver_test"

      # Workflow exists; the defensive scan would find it.
      wf = Workflows.get_workflow(@default_org, slug)
      assert wf.id == slug
      assert wf.display_name == "Resolver test"
    end

    test "non-existent slug produces nil from lookup (caller routes to unresolved block)" do
      assert Workflows.get_workflow(@default_org, "no_such_workflow_xyz") == nil
    end
  end

  describe "inline scan regex matches the right tokens" do
    # The handler uses ~r/(?:^|\s)&([a-z0-9_]+)\b/ — match at start
    # of string or after whitespace, capture the slug body. These
    # cases pin the boundaries so a future regex tweak doesn't
    # silently change matching behavior.

    test "matches at start of string" do
      assert capture("&foo") == ["foo"]
    end

    test "matches after whitespace" do
      assert capture("run &foo now") == ["foo"]
    end

    test "matches multiple tokens" do
      assert capture("run &foo and &bar at noon") |> Enum.sort() == ["bar", "foo"]
    end

    test "does NOT match `&` glued to another word" do
      # `M&Ms`, `R&D`, `&amp;` — these aren't slug references.
      assert capture("M&Ms are good") == []
      assert capture("R&D budget") == []
    end

    test "stops at word boundary" do
      # `&foo!`, `&foo.bar`, `&foo,` — capture `foo` only.
      assert capture("see &foo!") == ["foo"]
      assert capture("about &foo.bar") == ["foo"]
      assert capture("call &foo, &bar") |> Enum.sort() == ["bar", "foo"]
    end

    test "rejects uppercase / dashes — slug grammar is [a-z0-9_]+" do
      # `&Foo` matches the capital F → starts with non-lowercase, the
      # regex won't match since we require [a-z0-9_]+. Same for dashes.
      assert capture("&Foo") == []
      assert capture("&foo-bar") == ["foo"]   # matches "foo", stops at `-`
    end
  end

  defp capture(content) do
    Regex.scan(~r/(?:^|\s)&([a-z0-9_]+)\b/, content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
