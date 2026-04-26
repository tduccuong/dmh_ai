# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.MCP.Registry do
  @moduledoc """
  Two-tier MCP registry.

  **User-tier (auth, persistent).** `authorized_services` holds one
  row per service the user has authorized. Survives sessions,
  restarts, and task lifecycles. Carries the cached server tool list
  (`server_tools_json`) and authorization-server metadata
  (`asm_json`).

  **Task-tier (catalog, ephemeral).** `task_services` is a junction:
  one row per service attached to a task. The per-turn tool catalog
  returned to the LLM is filtered to the services in this table for
  the current anchor task. New session, no anchor task, or no
  attachments — empty catalog. `complete_task` / `cancel_task` drop
  every row for that task.

  Caching: `:persistent_term` keyed `{__MODULE__, user_id}` holds the
  user's authorized service catalog (alias → tool list). Invalidated
  on `authorize/5` and `set_authorized_tools/3`. Per-turn filter by
  attached aliases is a small DB query, not cached.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @cache_namespace __MODULE__

  @type authorized :: %{
          user_id:            String.t(),
          alias:              String.t(),
          canonical_resource: String.t(),
          server_url:         String.t(),
          asm:                map() | nil,
          tools:              [map()],
          created_ts:         integer()
        }

  # ── user-tier (authorization) ─────────────────────────────────────────

  @doc "Upsert an authorized-service row. Cache invalidated."
  @spec authorize(String.t(), String.t(), String.t(), String.t(), map() | nil) :: :ok
  def authorize(user_id, alias_, canonical, server_url, asm) do
    now = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO authorized_services
      (user_id, alias, canonical_resource, server_url, asm_json,
       server_tools_json, server_tools_cached_at, created_ts)
    VALUES (?, ?, ?, ?, ?, NULL, NULL, ?)
    ON CONFLICT(user_id, alias) DO UPDATE SET
      canonical_resource = excluded.canonical_resource,
      server_url         = excluded.server_url,
      asm_json           = excluded.asm_json
    """, [
      user_id, alias_, canonical, server_url,
      if(is_map(asm), do: Jason.encode!(asm), else: nil),
      now
    ])

    invalidate_cache(user_id)
    :ok
  end

  @doc "Cache the server's tools/list result on an existing authorized row."
  @spec set_authorized_tools(String.t(), String.t(), [map()]) :: :ok
  def set_authorized_tools(user_id, alias_, tools) when is_list(tools) do
    now = System.os_time(:millisecond)

    query!(Repo, """
    UPDATE authorized_services
       SET server_tools_json=?, server_tools_cached_at=?
     WHERE user_id=? AND alias=?
    """, [Jason.encode!(tools), now, user_id, alias_])

    invalidate_cache(user_id)
    :ok
  end

  @doc "Find an authorized service by `(user_id, alias)`. `nil` when missing."
  @spec find_authorized(String.t(), String.t()) :: authorized() | nil
  def find_authorized(user_id, alias_) do
    case query!(Repo, """
         SELECT user_id, alias, canonical_resource, server_url, asm_json,
                server_tools_json, created_ts
         FROM authorized_services WHERE user_id=? AND alias=?
         """, [user_id, alias_]) do
      %{rows: [row]} -> row_to_map(row)
      _              -> nil
    end
  end

  @doc "Find an authorized service by canonical resource. Useful from the OAuth callback."
  @spec find_authorized_by_resource(String.t(), String.t()) :: authorized() | nil
  def find_authorized_by_resource(user_id, canonical) do
    case query!(Repo, """
         SELECT user_id, alias, canonical_resource, server_url, asm_json,
                server_tools_json, created_ts
         FROM authorized_services WHERE user_id=? AND canonical_resource=?
         """, [user_id, canonical]) do
      %{rows: [row | _]} -> row_to_map(row)
      _                   -> nil
    end
  end

  @doc "All authorized services for a user. Empty list when none."
  @spec list_authorized(String.t()) :: [authorized()]
  def list_authorized(user_id) do
    r = query!(Repo, """
    SELECT user_id, alias, canonical_resource, server_url, asm_json,
           server_tools_json, created_ts
    FROM authorized_services
    WHERE user_id=?
    ORDER BY created_ts ASC
    """, [user_id])

    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  Drop an authorized service. Caller is responsible for revoking
  tokens and removing the matching credential row beforehand. Also
  drops every `task_services` attachment for this alias so live tasks
  don't keep referencing it.
  """
  @spec deauthorize(String.t(), String.t()) :: :ok
  def deauthorize(user_id, alias_) do
    query!(Repo, "DELETE FROM authorized_services WHERE user_id=? AND alias=?",
           [user_id, alias_])

    query!(Repo, "DELETE FROM task_services WHERE user_id=? AND alias=?",
           [user_id, alias_])

    invalidate_cache(user_id)
    :ok
  end

  # ── task-tier (attachment) ────────────────────────────────────────────

  @doc "Bind an authorized service to a task. Idempotent."
  @spec attach(String.t(), String.t(), String.t()) :: :ok
  def attach(task_id, user_id, alias_) when is_binary(task_id) do
    now = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO task_services (task_id, user_id, alias, attached_ts)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(task_id, alias) DO NOTHING
    """, [task_id, user_id, alias_, now])

    :ok
  end

  @doc """
  Drop every service attachment for a task. Called from
  `Tasks.mark_done/2` (one-off → done) and `Tasks.mark_cancelled/2`.
  Does nothing for periodic tasks since `mark_done` re-arms them
  rather than terminating.
  """
  @spec detach_all_for_task(String.t() | nil) :: :ok
  def detach_all_for_task(nil), do: :ok

  def detach_all_for_task(task_id) when is_binary(task_id) do
    query!(Repo, "DELETE FROM task_services WHERE task_id=?", [task_id])
    :ok
  end

  @doc "List the aliases attached to a task. Empty list when no attachments or task_id is nil."
  @spec attached_aliases(String.t() | nil) :: [String.t()]
  def attached_aliases(nil), do: []

  def attached_aliases(task_id) when is_binary(task_id) do
    r = query!(Repo,
      "SELECT alias FROM task_services WHERE task_id=? ORDER BY attached_ts ASC",
      [task_id])

    Enum.map(r.rows, fn [a] -> a end)
  end

  # ── catalog assembly ──────────────────────────────────────────────────

  @doc """
  Flat namespaced tool list for the current anchor task. Empty when
  `task_id` is nil or no services are attached. Each entry:
  `%{name, description, inputSchema, alias, server_tool_name}`.
  """
  @spec tools_for_task(String.t(), String.t() | nil) :: [map()]
  def tools_for_task(_user_id, nil), do: []

  def tools_for_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    case attached_aliases(task_id) do
      []      -> []
      aliases ->
        catalog = user_catalog(user_id)
        Enum.flat_map(aliases, fn alias_ -> Map.get(catalog, alias_, []) end)
    end
  end

  # ── cache ─────────────────────────────────────────────────────────────

  @doc """
  Drop the per-user cached catalog. Mutations (`authorize`,
  `set_authorized_tools`, `deauthorize`) invalidate; external callers
  (e.g. `delete_creds` removing an `mcp:*` credential) can invalidate
  through this entry point.
  """
  @spec invalidate_cache(String.t()) :: :ok
  def invalidate_cache(user_id) when is_binary(user_id) do
    :persistent_term.erase({@cache_namespace, user_id})
    :ok
  end

  # ── private ───────────────────────────────────────────────────────────

  # Per-user catalog: %{alias => [namespaced_tool_entry, ...]}.
  defp user_catalog(user_id) do
    case :persistent_term.get({@cache_namespace, user_id}, :__miss__) do
      :__miss__ ->
        fresh = build_user_catalog(user_id)
        :persistent_term.put({@cache_namespace, user_id}, fresh)
        fresh

      cached ->
        cached
    end
  end

  defp build_user_catalog(user_id) do
    user_id
    |> list_authorized()
    |> Map.new(fn auth ->
      entries =
        Enum.map(auth.tools, fn t ->
          server_name = Map.get(t, "name") || Map.get(t, :name) || ""
          %{
            name:             auth.alias <> "." <> server_name,
            description:      Map.get(t, "description") || Map.get(t, :description) || "",
            inputSchema:      Map.get(t, "inputSchema") || Map.get(t, :inputSchema) || %{},
            alias:            auth.alias,
            server_tool_name: server_name
          }
        end)

      {auth.alias, entries}
    end)
  end

  defp row_to_map([user_id, alias_, canonical, server_url, asm_json, tools_json, created_ts]) do
    %{
      user_id:            user_id,
      alias:              alias_,
      canonical_resource: canonical,
      server_url:         server_url,
      asm:                decode_json(asm_json, nil),
      tools:              decode_json(tools_json, []),
      created_ts:         created_ts
    }
  end

  defp decode_json(nil, default), do: default

  defp decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, val} -> val
      _          -> default
    end
  end
end
