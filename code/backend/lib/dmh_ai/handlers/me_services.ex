# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.MeServices do
  @moduledoc """
  Per-user view of Primitive 0.3 Universal Region connectors.

    GET  /me/services             — {available[], connected[]}
    POST /me/services/disconnect  — revoke a connection

  `available` is every enabled+configured connector the user
  hasn't connected yet, plus enough metadata for the FE to render
  a "Connect" button (slug + display_name + start URL of the
  existing authorize_service flow). `connected` is the
  authorized_services rows for the user, plus the connector's
  display_name.

  Available to every authenticated user (not admin-gated). The
  per-user `authorize_service` flow already handles RBAC at the
  permission layer.
  """

  alias DmhAi.{Constants, Repo}
  alias DmhAi.Handlers.Proxy
  import Ecto.Adapters.SQL, only: [query!: 3]
  import Plug.Conn
  require Logger

  def list(conn, user) do
    org_id = Map.get(user, :org_id) || Constants.default_org_id()
    user_id = user.id

    enabled = enabled_connectors(org_id)
    connected_slugs = connected_slugs(user_id)

    available =
      enabled
      |> Enum.reject(fn c -> c.slug in connected_slugs end)
      |> Enum.map(fn c ->
        %{
          slug:         c.slug,
          display_name: c.display_name,
          auth_kind:    c.auth_kind,
          # The existing authorize_service / connect_mcp flow takes a
          # slug — the FE button posts to /agent/tools/authorize_service
          # (or the user types `/connect_mcp slug:<slug>` in chat).
          # Either path lands at the same OAuth handshake.
          authorize_url: "/agent/tools/authorize_service?slug=#{c.slug}"
        }
      end)

    connected =
      list_connected(user_id)
      |> Enum.map(fn row ->
        slug = row.alias
        meta = Enum.find(enabled, fn c -> c.slug == slug end) || %{display_name: slug}

        %{
          slug:           slug,
          display_name:   meta.display_name,
          status:         row.status,
          connected_at:   row.created_ts,
          canonical_resource: row.canonical_resource
        }
      end)

    Proxy.json(conn, 200, %{available: available, connected: connected})
  end

  @doc """
  Mint a Google-style consent URL for `slug` and return it so the
  FE can `window.location.href = …` and walk the user through real
  OAuth. The state row is stamped with `flow_kind="connector_oauth"`
  so the callback's `finalize_connector_oauth/6` runs and writes
  the three credential rows the connector runtime needs.

  Returns 200 `{"url": "...", "redirect_uri": "..."}` on success;
  404 if the catalog rows aren't configured.
  """
  def connect(conn, user, slug) do
    org_id = Map.get(user, :org_id) || Constants.default_org_id()

    with {:ok, oauth} <- fetch_oauth_row(slug),
         {:ok, mcp}   <- fetch_mcp_row(org_id, slug) do
      asm = %{
        authorization_endpoint: oauth.auth_url,
        token_endpoint:         oauth.token_url,
        scopes_supported:       oauth.scopes,
        issuer:                 oauth.auth_url
      }

      redirect_uri =
        DmhAi.Agent.AgentSettings.oauth_redirect_base_url()
        |> String.trim_trailing("/")
        |> Kernel.<>("/oauth/callback")

      {:ok, %{auth_url: auth_url}} =
        DmhAi.Auth.OAuth2.init_flow(%{
          user_id:            user.id,
          # Sentinel session + anchor — finalize_connector_oauth
          # doesn't read these (no chat-resume to do; the user is
          # outside a chat session). The DB columns are NOT NULL
          # so we supply a stable label.
          session_id:         "me-services-connect",
          anchor_task_id:     "me-services-connect",
          alias:              slug,
          canonical_resource: mcp.mcp_url,
          server_url:         mcp.mcp_url,
          asm:                asm,
          client_id:          oauth.client_id,
          client_secret:      oauth.client_secret,
          redirect_uri:       redirect_uri,
          scopes:             oauth.scopes,
          flow_kind:          "connector_oauth",
          extra_auth_params:  oauth.extra_auth_params
        })

      Proxy.json(conn, 200, %{url: auth_url, redirect_uri: redirect_uri})
    else
      {:error, reason} -> Proxy.json(conn, 404, %{error: reason})
    end
  end

  defp fetch_oauth_row(slug) do
    case query!(Repo, """
    SELECT client_id, client_secret, scopes_default,
           authorization_endpoint, token_endpoint, extra_auth_params
    FROM oauth_catalog WHERE slug=?
    """, [slug]).rows do
      [[client_id, client_secret, scopes_json, auth_url, token_url, extra_json]]
          when is_binary(client_id) and client_id != "" ->
        {:ok, %{
          client_id:         client_id,
          client_secret:     client_secret,
          scopes:            decode_json_list(scopes_json),
          auth_url:          auth_url,
          token_url:         token_url,
          extra_auth_params: decode_json_map(extra_json)
        }}

      [[_, _, _, _, _, _]] ->
        {:error, "oauth_catalog row exists for #{slug} but client_id is empty — admin must paste credentials in the Connectors page"}

      _ ->
        {:error, "no oauth_catalog row for slug=#{slug}"}
    end
  end

  defp fetch_mcp_row(org_id, slug) do
    case query!(Repo, """
    SELECT mcp_url FROM mcp_catalog WHERE org_id=? AND slug=? AND enabled=1
    """, [org_id, slug]).rows do
      [[url]] when is_binary(url) and url != "" ->
        {:ok, %{mcp_url: url}}

      _ ->
        {:error, "no enabled mcp_catalog row for slug=#{slug} in org=#{org_id}"}
    end
  end

  defp decode_json_list(nil), do: []
  defp decode_json_list(""),  do: []
  defp decode_json_list(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_map(nil), do: %{}
  defp decode_json_map(""),  do: %{}
  defp decode_json_map(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  def disconnect(conn, user) do
    user_id = user.id
    {:ok, body, conn} = read_body(conn)

    case Jason.decode(body) do
      {:ok, %{"slug" => slug}} when is_binary(slug) and slug != "" ->
        do_disconnect(conn, user_id, slug)

      _ ->
        Proxy.json(conn, 400, %{error: "missing required field: slug"})
    end
  end

  # ─── DB helpers ───────────────────────────────────────────────────────

  defp enabled_connectors(org_id) do
    # Join mcp_catalog (enabled + url set) with oauth_catalog
    # (display_name + auth_kind). Per-org mcp_catalog; per-deployment
    # oauth_catalog. Connector is "available" to the user iff:
    #   - mcp_catalog row exists for this org, enabled=1, mcp_url
    #     non-empty
    #   - oauth_catalog row exists (so authorize_service has
    #     somewhere to redirect)
    rows =
      query!(Repo, """
      SELECT m.slug, COALESCE(o.display_name, m.name), m.auth_kind, m.mcp_url
      FROM   mcp_catalog m
      LEFT JOIN oauth_catalog o ON o.slug = m.slug
      WHERE  m.org_id = ?
        AND  m.enabled = 1
        AND  m.mcp_url IS NOT NULL
        AND  m.mcp_url != ''
      """, [org_id]).rows

    Enum.map(rows, fn [slug, display_name, auth_kind, mcp_url] ->
      %{slug: slug, display_name: display_name, auth_kind: auth_kind, mcp_url: mcp_url}
    end)
  end

  defp connected_slugs(user_id) do
    query!(Repo, """
    SELECT alias FROM authorized_services WHERE user_id = ?
    """, [user_id]).rows
    |> Enum.map(fn [a] -> a end)
  end

  defp list_connected(user_id) do
    query!(Repo, """
    SELECT alias, canonical_resource, status, created_ts
    FROM   authorized_services
    WHERE  user_id = ?
    ORDER  BY created_ts DESC
    """, [user_id]).rows
    |> Enum.map(fn [alias_, canonical, status, created] ->
      %{alias: alias_, canonical_resource: canonical, status: status, created_ts: created}
    end)
  end

  defp do_disconnect(conn, user_id, slug) do
    # Look up the authorized_services row to find the canonical_resource
    # so we can also drop the user_credentials at `mcp:<canonical>`.
    canonical =
      case query!(Repo, """
      SELECT canonical_resource FROM authorized_services WHERE user_id=? AND alias=?
      """, [user_id, slug]).rows do
        [[c]] -> c
        _     -> nil
      end

    query!(Repo, "DELETE FROM authorized_services WHERE user_id=? AND alias=?", [user_id, slug])
    query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?",
                 [user_id, "oauth:" <> slug])

    if is_binary(canonical) do
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?",
                   [user_id, "mcp:" <> canonical])
    end

    Logger.info("[MeServices] user=#{user_id} disconnected slug=#{slug}")

    Proxy.json(conn, 200, %{ok: true})
  end
end
