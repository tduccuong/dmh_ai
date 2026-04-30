# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Handlers.AdminMcpCatalog do
  @moduledoc """
  Admin REST endpoints for the MCP Catalog. See specs/mcp.md §Phase E.

    GET    /admin/mcp-catalog            — list rows
    POST   /admin/mcp-catalog            — create
    PUT    /admin/mcp-catalog/:id        — update fields
    DELETE /admin/mcp-catalog/:id        — remove
    POST   /admin/mcp-catalog/:id/enable — run preflight + flip enabled
    POST   /admin/mcp-catalog/:id/disable — flip enabled=0 (no probe)
    POST   /admin/mcp-catalog/import     — bulk insert from a JSON array

  Admin-gated (`user.role == "admin"`).
  """

  import Plug.Conn
  alias Dmhai.Handlers.Proxy
  alias Dmhai.MCP.Catalog
  require Logger

  def list(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      Proxy.json(conn, 200, %{entries: Catalog.list()})
    end
  end

  def create(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)

      case Catalog.create(parse_json(body)) do
        {:ok, entry}                  -> Proxy.json(conn, 201, %{entry: entry})
        {:error, :missing_slug}       -> Proxy.json(conn, 400, %{error: "missing required field: slug"})
        {:error, :missing_name}       -> Proxy.json(conn, 400, %{error: "missing required field: name"})
        {:error, :missing_url}        -> Proxy.json(conn, 400, %{error: "missing required field: mcp_url"})
        {:error, :slug_taken}         -> Proxy.json(conn, 409, %{error: "slug already exists"})
      end
    end
  end

  def update(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      with_id(conn, id_str, fn id ->
        {:ok, body, conn} = read_body(conn)

        case Catalog.update(id, parse_json(body)) do
          {:ok, entry}        -> Proxy.json(conn, 200, %{entry: entry})
          {:error, :not_found} -> Proxy.json(conn, 404, %{error: "catalog entry not found"})
        end
      end)
    end
  end

  def delete(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      with_id(conn, id_str, fn id ->
        case Catalog.delete(id) do
          :ok                  -> Proxy.json(conn, 200, %{ok: true})
          {:error, :not_found} -> Proxy.json(conn, 404, %{error: "catalog entry not found"})
        end
      end)
    end
  end

  def enable(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      with_id(conn, id_str, fn id ->
        case Catalog.enable(id) do
          {:ok, entry}         -> Proxy.json(conn, 200, %{entry: entry})
          {:error, :not_found} -> Proxy.json(conn, 404, %{error: "catalog entry not found"})
          {:error, :not_mcp}   -> Proxy.json(conn, 422, %{error: "URL does not respond as an MCP server", entry: Catalog.get(id)})
          {:error, reason}     -> Proxy.json(conn, 500, %{error: to_string(reason), entry: Catalog.get(id)})
        end
      end)
    end
  end

  def disable(conn, user, id_str) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      with_id(conn, id_str, fn id ->
        case Catalog.disable(id) do
          {:ok, entry}         -> Proxy.json(conn, 200, %{entry: entry})
          {:error, :not_found} -> Proxy.json(conn, 404, %{error: "catalog entry not found"})
        end
      end)
    end
  end

  @doc """
  Bulk import. Body: a JSON ARRAY of catalog-entry-shaped maps.
  Slug collisions are skipped; other errors are reported per-row.
  """
  def import_many(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)

      case Jason.decode(body || "[]") do
        {:ok, rows} when is_list(rows) ->
          summary = Catalog.import_many(rows)

          # Tuple errors aren't JSON-encodable; flatten before
          # returning so the FE can render the per-row failures.
          flat_errors =
            Enum.map(summary.errors, fn {slug, reason} ->
              %{slug: slug, error: to_string(reason)}
            end)

          Proxy.json(conn, 200, Map.put(summary, :errors, flat_errors))

        _ ->
          Proxy.json(conn, 400, %{error: "body must be a JSON array of catalog entries"})
      end
    end
  end

  # ─── private ───────────────────────────────────────────────────────────

  defp parse_json(body) do
    case Jason.decode(body || "{}") do
      {:ok, m} when is_map(m) -> m
      _                       -> %{}
    end
  end

  defp with_id(conn, id_str, fun) do
    case Integer.parse(id_str) do
      {id, ""} -> fun.(id)
      _        -> Proxy.json(conn, 400, %{error: "invalid id"})
    end
  end
end
