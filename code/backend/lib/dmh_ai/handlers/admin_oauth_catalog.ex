# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.AdminOAuthCatalog do
  @moduledoc """
  Admin CRUD for the curated OAuth services catalog. Backs the
  Settings → Curated Services page in the admin UI.

  All endpoints require an authenticated admin user. Non-admins get
  403; the AuthPlug above the route handles that uniformly.

  The handler also computes the deployment's redirect URI (via
  `AgentSettings.oauth_redirect_base_url/0`) and includes it in the
  list response so the FE can show it click-to-copy without
  hard-coding deploy details.

  `client_secret` is masked on read — the FE never sees the stored
  value, only `<has_secret: true|false>`. On write, an empty-string
  secret means *"don't change the stored value"* (so editing a row
  doesn't require re-typing the secret each time).
  """

  import Plug.Conn
  alias DmhAi.OAuth.Catalog

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp require_admin(conn, user, fun) do
    if user.role == "admin" do
      fun.()
    else
      json(conn, 403, %{error: "Forbidden"})
    end
  end

  defp redirect_uri do
    base = DmhAi.Agent.AgentSettings.oauth_redirect_base_url()
    String.trim_trailing(base, "/") <> "/oauth/callback"
  end

  defp safe_entry(%{} = entry) do
    entry
    |> Map.delete(:client_secret)
    |> Map.put(:has_secret, is_binary(entry.client_secret) and entry.client_secret != "")
  end

  # GET /admin/oauth_catalog
  def list(conn, user) do
    require_admin(conn, user, fn ->
      json(conn, 200, %{
        redirect_uri: redirect_uri(),
        services:     Catalog.list_all() |> Enum.map(&safe_entry/1)
      })
    end)
  end

  # POST /admin/oauth_catalog
  def create(conn, user) do
    require_admin(conn, user, fn ->
      {:ok, body, conn} = read_body(conn)
      attrs = Jason.decode!(body || "{}")

      case Catalog.create(attrs) do
        {:ok, entry}     -> json(conn, 201, safe_entry(entry))
        {:error, reason} -> json(conn, 400, %{error: format_reason(reason)})
      end
    end)
  end

  # PUT /admin/oauth_catalog/:id
  def update(conn, user, id_str) do
    require_admin(conn, user, fn ->
      case parse_id(id_str) do
        {:ok, id} ->
          {:ok, body, conn} = read_body(conn)
          attrs = Jason.decode!(body || "{}")

          case Catalog.update(id, attrs) do
            {:ok, entry}      -> json(conn, 200, safe_entry(entry))
            {:error, :not_found} -> json(conn, 404, %{error: "Not found"})
            {:error, reason}  -> json(conn, 400, %{error: format_reason(reason)})
          end

        :error ->
          json(conn, 400, %{error: "invalid id"})
      end
    end)
  end

  # DELETE /admin/oauth_catalog/:id
  def delete(conn, user, id_str) do
    require_admin(conn, user, fn ->
      case parse_id(id_str) do
        {:ok, id} ->
          :ok = Catalog.delete(id)
          json(conn, 200, %{ok: true})

        :error ->
          json(conn, 400, %{error: "invalid id"})
      end
    end)
  end

  defp parse_id(id_str) when is_binary(id_str) do
    case Integer.parse(id_str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
