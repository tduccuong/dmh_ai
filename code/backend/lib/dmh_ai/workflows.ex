# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows do
  @moduledoc """
  DB-layer for the workflow store. Two tables:

    * `workflows`         — one row per logical workflow (org_id, id) →
                            display_name, current_version, active_version.
    * `workflow_versions` — append-only version history; the full IR
                            lives in `ir_json`.

  See `arch_wiki/dmh_ai/sme/layer-W.md` for the spec, the IR shape,
  and the versioning contract (versions are immutable; current_version
  advances on each save; active_version is set on explicit arm).

  This module is the ONLY writer to either table; the `UpsertWorkflow`
  tool and the (forthcoming) workflow-arming handler both go through
  here. Tests stub Repo directly; no caching layer.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @type workflow :: %{
          id:              String.t(),
          org_id:          String.t(),
          display_name:    String.t(),
          current_version: integer(),
          active_version:  integer() | nil,
          created_at:      integer(),
          updated_at:      integer()
        }

  @type version :: %{
          workflow_id:          String.t(),
          org_id:               String.t(),
          version:              integer(),
          ir:                   map(),
          change_note:          String.t() | nil,
          compiled_at:          integer(),
          compiled_in_session:  String.t(),
          compiled_by_user_id:  String.t(),
          open_questions_count: integer()
        }

  # ─── Lookup ───────────────────────────────────────────────────────────

  @spec get_workflow(String.t(), String.t()) :: workflow() | nil
  def get_workflow(org_id, id) when is_binary(org_id) and is_binary(id) do
    case query!(Repo, """
    SELECT id, org_id, display_name, current_version, active_version,
           created_at, updated_at
    FROM workflows WHERE org_id=? AND id=?
    """, [org_id, id]).rows do
      [row] -> row_to_workflow(row)
      _     -> nil
    end
  end

  @spec list_workflows(String.t()) :: [workflow()]
  def list_workflows(org_id) when is_binary(org_id) do
    %{rows: rows} = query!(Repo, """
    SELECT id, org_id, display_name, current_version, active_version,
           created_at, updated_at
    FROM workflows WHERE org_id=? ORDER BY updated_at DESC
    """, [org_id])

    Enum.map(rows, &row_to_workflow/1)
  end

  @spec get_version(String.t(), String.t(), integer()) :: version() | nil
  def get_version(org_id, workflow_id, version)
      when is_binary(org_id) and is_binary(workflow_id) and is_integer(version) do
    case query!(Repo, """
    SELECT workflow_id, org_id, version, ir_json, change_note, compiled_at,
           compiled_in_session, compiled_by_user_id, open_questions_count
    FROM workflow_versions WHERE org_id=? AND workflow_id=? AND version=?
    """, [org_id, workflow_id, version]).rows do
      [row] -> row_to_version(row)
      _     -> nil
    end
  end

  # ─── Upsert ───────────────────────────────────────────────────────────

  @doc """
  Atomic upsert. First save creates the `workflows` row at v0; each
  subsequent save inserts a new `workflow_versions` row at
  `current_version + 1` and bumps `workflows.current_version`.

  Returns `{:ok, %{id, version, display_name, url}}`. `url` is the
  modal-only route the FE intercepts to open the viewer.

  Concurrent saves: an optimistic-concurrency check guards against
  the rare two-users-editing-the-same-workflow race — the second
  upsert sees the post-first-insert `current_version` and lands at
  current+1. The SQLite-side composite PK on
  `(org_id, workflow_id, version)` is the hard guarantee.
  """
  @spec upsert(map()) :: {:ok, map()} | {:error, term()}
  def upsert(%{
        org_id:       org_id,
        id:           id,
        display_name: display_name,
        ir:           ir,
        change_note:  change_note,
        session_id:   session_id,
        user_id:      user_id,
        open_questions_count: oq_count
      })
      when is_binary(org_id) and is_binary(id) and is_binary(display_name) and
             is_map(ir) and is_binary(session_id) and is_binary(user_id) and
             is_integer(oq_count) do
    now = System.os_time(:millisecond)
    ir_json = Jason.encode!(ir)

    case get_workflow(org_id, id) do
      nil ->
        # First save → INSERT workflow at current_version=0 + v0 row.
        query!(Repo, """
        INSERT INTO workflows
          (id, org_id, display_name, current_version, active_version,
           created_at, updated_at)
        VALUES (?, ?, ?, 0, NULL, ?, ?)
        """, [id, org_id, display_name, now, now])

        query!(Repo, """
        INSERT INTO workflow_versions
          (workflow_id, org_id, version, ir_json, change_note, compiled_at,
           compiled_in_session, compiled_by_user_id, open_questions_count)
        VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)
        """, [id, org_id, ir_json, change_note, now, session_id, user_id, oq_count])

        Logger.info("[Workflows] created slug=#{id} org=#{org_id} as v0")

        {:ok, build_result(id, display_name, 0)}

      %{current_version: cv} ->
        new_version = cv + 1

        query!(Repo, """
        INSERT INTO workflow_versions
          (workflow_id, org_id, version, ir_json, change_note, compiled_at,
           compiled_in_session, compiled_by_user_id, open_questions_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [id, org_id, new_version, ir_json, change_note, now, session_id, user_id, oq_count])

        query!(Repo, """
        UPDATE workflows SET current_version=?, display_name=?, updated_at=?
        WHERE org_id=? AND id=?
        """, [new_version, display_name, now, org_id, id])

        Logger.info("[Workflows] upserted slug=#{id} org=#{org_id} v#{new_version}")

        {:ok, build_result(id, display_name, new_version)}
    end
  rescue
    e in Exqlite.Error ->
      {:error, {:db_error, Exception.message(e)}}
  end

  # ─── Arming ───────────────────────────────────────────────────────────

  @doc """
  Flip `active_version` to the given version (must be ≤ current_version,
  must exist in workflow_versions). Returns :ok / {:error, reason}.
  """
  @spec arm(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def arm(org_id, id, version) when is_integer(version) do
    case get_workflow(org_id, id) do
      nil ->
        {:error, :workflow_not_found}

      %{current_version: cv} when version > cv ->
        {:error, :version_not_found}

      _ ->
        now = System.os_time(:millisecond)
        query!(Repo, """
        UPDATE workflows SET active_version=?, updated_at=?
        WHERE org_id=? AND id=?
        """, [version, now, org_id, id])
        Logger.info("[Workflows] armed slug=#{id} org=#{org_id} v#{version}")
        :ok
    end
  end

  @doc "Unarm — sets active_version to NULL. New trigger events drop."
  @spec disarm(String.t(), String.t()) :: :ok
  def disarm(org_id, id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE workflows SET active_version=NULL, updated_at=?
    WHERE org_id=? AND id=?
    """, [now, org_id, id])
    :ok
  end

  # ─── helpers ──────────────────────────────────────────────────────────

  defp row_to_workflow([id, org_id, display_name, current_version, active_version,
                       created_at, updated_at]) do
    %{
      id:              id,
      org_id:          org_id,
      display_name:    display_name,
      current_version: current_version,
      active_version:  active_version,
      created_at:      created_at,
      updated_at:      updated_at
    }
  end

  defp row_to_version([workflow_id, org_id, version, ir_json, change_note,
                      compiled_at, compiled_in_session, compiled_by_user_id,
                      open_questions_count]) do
    %{
      workflow_id:          workflow_id,
      org_id:               org_id,
      version:              version,
      ir:                   Jason.decode!(ir_json),
      change_note:          change_note,
      compiled_at:          compiled_at,
      compiled_in_session:  compiled_in_session,
      compiled_by_user_id:  compiled_by_user_id,
      open_questions_count: open_questions_count
    }
  end

  defp build_result(id, display_name, version) do
    %{
      id:           id,
      display_name: display_name,
      version:      version,
      url:          "/workflows/#{URI.encode(id)}/#{version}"
    }
  end

  @doc """
  Derive a stable URL-safe slug from a display name. Used by the
  compiler to produce a workflow's id from its display_name at first
  save. Lower-case, alnum + underscore only, length-capped.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(s) when is_binary(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 64)
    |> case do
      ""    -> "workflow"
      other -> other
    end
  end
end
