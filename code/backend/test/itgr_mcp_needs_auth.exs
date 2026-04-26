# Phase C / Chunk 1 — `needs_auth` status flip on the
# `authorized_services` table. Covers:
#
#   * `MCP.Registry.authorize/5` writes new rows with status
#     `'authorized'` and resets to `'authorized'` on re-authorize.
#   * `MCP.Registry.mark_needs_auth/2` flips status, invalidates
#     the per-user catalog cache, no-ops on missing rows.
#   * `find_authorized/2`, `find_authorized_by_resource/2`,
#     `list_authorized/1` carry the new status field through.
#   * `tools_for_task/2` filters out services in `needs_auth`
#     status — the LLM doesn't see names it can no longer invoke.
#   * `Re-authorize after needs_auth` clears the flag; tools come
#     back into the catalog.
#
# All offline. No HTTP, no LLM, no Tasks.* (we use synthetic
# `task_services` rows directly so this stays narrow).

defmodule Itgr.McpNeedsAuth do
  use ExUnit.Case, async: false

  alias Dmhai.MCP.Registry
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_attached(task_id, user_id, alias_) do
    now = System.os_time(:millisecond)

    query!(Repo, """
    INSERT OR REPLACE INTO task_services (task_id, user_id, alias, attached_ts)
    VALUES (?, ?, ?, ?)
    """, [task_id, user_id, alias_, now])
  end

  defp seed_tools(user_id, alias_, tools) do
    Registry.set_authorized_tools(user_id, alias_, tools)
  end

  setup do
    user_id = uid()
    alias_  = "svc_" <> uid()
    canonical = "https://example.com/mcp/#{alias_}"
    server_url = canonical
    Registry.authorize(user_id, alias_, canonical, server_url, %{issuer: "https://as.example.com"})
    {:ok, user_id: user_id, alias: alias_, canonical: canonical, server_url: server_url}
  end

  # ─── status defaults + reset on re-auth ────────────────────────────────

  describe "authorize/5" do
    test "writes new rows with status='authorized'", ctx do
      auth = Registry.find_authorized(ctx.user_id, ctx.alias)
      assert auth.status == "authorized"
    end

    test "re-authorize after needs_auth resets status to 'authorized'", ctx do
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)
      assert Registry.find_authorized(ctx.user_id, ctx.alias).status == "needs_auth"

      # User re-runs connect_service → authorize/5 fires the upsert path.
      Registry.authorize(ctx.user_id, ctx.alias, ctx.canonical, ctx.server_url, %{})

      assert Registry.find_authorized(ctx.user_id, ctx.alias).status == "authorized"
    end
  end

  # ─── mark_needs_auth ───────────────────────────────────────────────────

  describe "mark_needs_auth/2" do
    test "flips status from authorized to needs_auth", ctx do
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)
      assert Registry.find_authorized(ctx.user_id, ctx.alias).status == "needs_auth"
    end

    test "is idempotent — already needs_auth stays needs_auth", ctx do
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)
      assert Registry.find_authorized(ctx.user_id, ctx.alias).status == "needs_auth"
    end

    test "no-op on missing rows (no exception, no spurious row)", ctx do
      :ok = Registry.mark_needs_auth(ctx.user_id, "never_existed_" <> uid())
      assert Registry.find_authorized(ctx.user_id, "never_existed_anything") == nil
    end
  end

  # ─── catalog filtering ─────────────────────────────────────────────────

  describe "tools_for_task/2 filters needs_auth services" do
    setup ctx do
      task_id = "tk_" <> uid()
      seed_attached(task_id, ctx.user_id, ctx.alias)
      seed_tools(ctx.user_id, ctx.alias, [
        %{"name" => "ping", "description" => "ping",  "inputSchema" => %{}},
        %{"name" => "echo", "description" => "echo",  "inputSchema" => %{}}
      ])
      {:ok, task_id: task_id}
    end

    test "authorized service contributes tools to the catalog", ctx do
      tools = Registry.tools_for_task(ctx.user_id, ctx.task_id)
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["#{ctx.alias}.echo", "#{ctx.alias}.ping"]
    end

    test "needs_auth service contributes ZERO tools", ctx do
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)
      assert Registry.tools_for_task(ctx.user_id, ctx.task_id) == []
    end

    test "tools come back after re-authorize", ctx do
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)
      assert Registry.tools_for_task(ctx.user_id, ctx.task_id) == []

      Registry.authorize(ctx.user_id, ctx.alias, ctx.canonical, ctx.server_url, %{})

      tools = Registry.tools_for_task(ctx.user_id, ctx.task_id)
      assert length(tools) == 2
    end
  end

  # ─── reads carry the status field ──────────────────────────────────────

  describe "lookups carry status" do
    test "find_authorized_by_resource returns status", ctx do
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)
      r = Registry.find_authorized_by_resource(ctx.user_id, ctx.canonical)
      assert r.status == "needs_auth"
    end

    test "list_authorized carries status across multiple services", ctx do
      a2 = "svc2_" <> uid()
      Registry.authorize(ctx.user_id, a2, "https://example.com/two", "https://example.com/two", %{})
      :ok = Registry.mark_needs_auth(ctx.user_id, ctx.alias)

      services = Registry.list_authorized(ctx.user_id) |> Enum.sort_by(& &1.alias)
      assert length(services) == 2
      [first, second] = services

      statuses = Map.new(services, &{&1.alias, &1.status})
      assert statuses[ctx.alias] == "needs_auth"
      assert statuses[a2]        == "authorized"

      # Sanity: alias keys are present on both rows.
      assert is_binary(first.alias)
      assert is_binary(second.alias)
    end
  end
end
