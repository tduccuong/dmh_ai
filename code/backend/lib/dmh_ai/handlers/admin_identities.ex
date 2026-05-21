# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.AdminIdentities do
  @moduledoc """
  Primitive 0.9 admin surface — manual override entries for the
  `connector_identities` cache.

  Routes (declared in `DmhAi.Router`):

      POST /admin/identities
        body: { "user_id": "u_alice",
                "connector_slug": "hubspot",
                "external_id": "12345" }
        → { "ok": true }
        — Admin-only. Writes a permanent (`ttl_s = 0`) row in the
          cache with `resolved_via = "manual_override"`. Idempotent.

      GET /admin/identities?user_id=<id>
        → { "identities": [{ slug, external_id, resolved_via,
                              cached_at, ttl_s }, ...] }
        — Admin-only. Diagnostic listing.

  Use cases:

  - DMH-AI user has a different work email in the vendor
    (`alice@personal.com` ↔ `alice.smith@acme.com` in HubSpot).
    Auto-pivot fails; admin writes the mapping.
  - Vendor user-by-email API is unreliable; admin pins the
    mapping permanently.
  """

  import Plug.Conn
  alias DmhAi.{Identities, Permissions}

  @spec put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put(conn, user) do
    unless Permissions.can?(user.id, :write_settings, "org_settings") do
      json(conn, 403, %{error: "admin-only endpoint"})
    else
      case read_body!(conn) do
        %{"user_id" => uid, "connector_slug" => slug, "external_id" => ext}
        when is_binary(uid) and is_binary(slug) and is_binary(ext)
             and uid != "" and slug != "" and ext != "" ->
          :ok = Identities.put_manual_override(uid, slug, ext, user.id)
          json(conn, 200, %{ok: true})

        _ ->
          json(conn, 400, %{error: "expected {user_id, connector_slug, external_id}"})
      end
    end
  end

  @spec list(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list(conn, user) do
    unless Permissions.can?(user.id, :write_settings, "org_settings") do
      json(conn, 403, %{error: "admin-only endpoint"})
    else
      conn = Plug.Conn.fetch_query_params(conn)
      uid  = conn.query_params["user_id"]

      cond do
        not is_binary(uid) or uid == "" ->
          json(conn, 400, %{error: "missing query param user_id"})

        true ->
          json(conn, 200, %{identities: Identities.list_for_user(uid)})
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

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
