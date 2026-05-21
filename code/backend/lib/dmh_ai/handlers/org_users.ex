# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.OrgUsers do
  @moduledoc """
  Read-only directory endpoint for the @-mention picker (Layer W).

      GET /org/users?q=<prefix>
        → { users: [{ id, username, display_name, email, role }, ...] }

  Same-org members only. The FE picker calls this on every `@`
  keystroke; results are filtered by leading-substring match
  against `email` (everything before `@`), `display_name`, and
  `id`. Limited to 10 hits.

  The picker substitutes `@<username>` in the textarea (where
  `<username>` is the part of the email before `@`) and keeps a
  sidecar `mentions: [{token, user_id}]` that the chat POST
  passes through to the BE. The compiler reads the sidecar (NOT
  the textarea) when resolving `@<name>` references in the user's
  prose, so name re-resolution is impossible.
  """

  import Plug.Conn
  alias DmhAi.{Orgs, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @limit 10

  @spec search(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search(conn, user) do
    conn  = Plug.Conn.fetch_query_params(conn)
    q     = (conn.query_params["q"] || "") |> String.trim() |> String.downcase()
    org_id = Orgs.for_user(user.id)

    rows = lookup(org_id, q)

    json(conn, 200, %{users: Enum.map(rows, &shape_row/1)})
  end

  # ── lookup ────────────────────────────────────────────────────────────

  defp lookup(org_id, "") do
    %{rows: rows} = query!(Repo, """
    SELECT id, email, name, org_role
      FROM users
     WHERE org_id=? AND COALESCE(deleted, 0) = 0
     ORDER BY email
     LIMIT ?
    """, [org_id, @limit])

    rows
  end

  defp lookup(org_id, q) do
    # SQLite LIKE is case-insensitive for ASCII by default; we
    # additionally lower-case the query and match against
    # lower(email) / lower(name) / lower(id) so non-ASCII names
    # are handled symmetrically.
    pattern = "%" <> q <> "%"

    %{rows: rows} = query!(Repo, """
    SELECT id, email, name, org_role
      FROM users
     WHERE org_id=?
       AND COALESCE(deleted, 0) = 0
       AND (lower(email) LIKE ? OR lower(COALESCE(name, '')) LIKE ? OR lower(id) LIKE ?)
     ORDER BY email
     LIMIT ?
    """, [org_id, pattern, pattern, pattern, @limit])

    rows
  end

  defp shape_row([id, email, name, org_role]) do
    %{
      id:           id,
      username:     username_from_email(email),
      display_name: name || username_from_email(email),
      email:        email,
      role:         org_role
    }
  end

  defp username_from_email(nil), do: ""

  defp username_from_email(email) when is_binary(email) do
    email |> String.split("@", parts: 2) |> List.first()
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
