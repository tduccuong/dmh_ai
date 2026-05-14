# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.AdminKbSources do
  @moduledoc """
  Admin endpoints for org-scoped KB source management (Primitive 0.2).

  Routes (declared in `DmhAi.Router`):

      POST /admin/kb-sources/remove
        body: { "source_id": "...", "reason": "..." (optional) }
        → { "ok": true, "source_id": "..." }
        — Admin-only. Drops the kb_sources row + cascading chunks/
          vectors/FTS for the caller's org. Writes a kb_source_history
          row.

      GET /admin/kb-sources
        → { "sources": [ ... ] }
        — Admin-only. Lists every kb_sources row in the caller's org.

  ## Status

  This handler underpins the eventual admin UI's "manage KB" panel.
  Each row in the future UI will offer a remove button → POST to
  `/admin/kb-sources/remove`. The endpoint is wired and tested e2e
  by `test/flows/F33_index_remove.exs`; the UI bind-up is the only
  remaining piece.
  """

  import Plug.Conn
  alias DmhAi.{Ingest, Orgs, Permissions, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, user) do
    unless Permissions.can?(user.id, :administer, :org_settings) do
      json(conn, 403, %{error: "admin-only endpoint"})
    else
      case read_body!(conn) do
        %{"source_id" => source_id} = body when is_binary(source_id) and source_id != "" ->
          org_id = Orgs.for_user(user.id)
          reason = body["reason"]

          :ok = Ingest.remove_kb_source!(org_id, source_id,
                                          removed_by_user_id: user.id,
                                          reason: reason)

          Logger.info("[AdminKbSources] removed org=#{org_id} source_id=#{source_id} by=#{user.id}")
          json(conn, 200, %{ok: true, source_id: source_id})

        _ ->
          json(conn, 400, %{error: "missing source_id"})
      end
    end
  end

  @spec list(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list(conn, user) do
    unless Permissions.can?(user.id, :administer, :org_settings) do
      json(conn, 403, %{error: "admin-only endpoint"})
    else
      org_id = Orgs.for_user(user.id)

      %{rows: rows} =
        query!(Repo, """
        SELECT source_id, source_kind, title, content_sha256,
               last_indexed_at, last_seen_at, last_check_failed_at,
               last_check_error, ingest_status
        FROM   kb_sources
        WHERE  org_id=?
        ORDER  BY indexed_at DESC
        """, [org_id])

      sources =
        Enum.map(rows, fn [sid, kind, title, sha, idxd, seen, failed_at, err, status] ->
          %{
            source_id:            sid,
            source_kind:          kind,
            title:                title,
            content_sha256:       sha,
            last_indexed_at:      idxd,
            last_seen_at:         seen,
            last_check_failed_at: failed_at,
            last_check_error:     err,
            ingest_status:        status
          }
        end)

      json(conn, 200, %{sources: sources})
    end
  end

  # ─── helpers ─────────────────────────────────────────────────────────────

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp read_body!(conn) do
    {:ok, body, _} = read_body(conn)
    case body do
      "" -> %{}
      b  -> Jason.decode!(b)
    end
  end
end
