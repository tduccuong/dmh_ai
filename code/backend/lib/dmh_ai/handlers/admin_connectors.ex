# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.AdminConnectors do
  @moduledoc """
  Consolidated admin view + probe for Primitive 0.3 Universal
  Region connectors. Joins `oauth_catalog` + `mcp_catalog` rows
  per slug and reports each connector's configuration state so
  the admin FE can render a "Connectors" page (one card per
  connector) without making N round-trips.

    GET  /admin/connectors            — consolidated list
    POST /admin/connectors/:slug/test — probe MCP URL, return tools/list

  Admin-gated (`user.role == "admin"`).

  No CREATE / UPDATE here — those routes already exist on
  `/admin/oauth_catalog` and `/admin/mcp-catalog` and the FE
  uses them directly. This handler is read-only + probe.
  """

  alias DmhAi.{Repo, Connectors}
  alias DmhAi.Handlers.Proxy
  alias DmhAi.MCP.Transport
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  def list(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      Proxy.json(conn, 200, %{connectors: build_list(user)})
    end
  end

  def test(conn, user, slug) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      case probe_slug(user, slug) do
        {:ok, info}      -> Proxy.json(conn, 200, %{ok: true, info: info})
        {:error, reason} -> Proxy.json(conn, 200, %{ok: false, error: reason})
      end
    end
  end

  def save(conn, user, slug) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode(body) do
        {:ok, params} when is_map(params) ->
          do_save(conn, user, slug, params)

        _ ->
          Proxy.json(conn, 400, %{error: "invalid JSON body"})
      end
    end
  end

  defp do_save(conn, user, slug, params) do
    org_id = Map.get(user, :org_id) || DmhAi.Constants.default_org_id()
    now = System.os_time(:millisecond)

    # OAuth catalog: update client_id / client_secret (only if
    # provided — blank secret means "keep existing").
    if Map.has_key?(params, "client_id") or Map.has_key?(params, "client_secret") do
      set_clauses = []
      bindings    = []

      {set_clauses, bindings} =
        case Map.get(params, "client_id") do
          v when is_binary(v) -> {set_clauses ++ ["client_id=?"], bindings ++ [v]}
          _                    -> {set_clauses, bindings}
        end

      {set_clauses, bindings} =
        case Map.get(params, "client_secret") do
          v when is_binary(v) and v != "" ->
            {set_clauses ++ ["client_secret=?"], bindings ++ [v]}
          _ ->
            {set_clauses, bindings}
        end

      if set_clauses != [] do
        clauses_sql = Enum.join(set_clauses ++ ["updated_ts=?"], ", ")

        query!(Repo, """
        UPDATE oauth_catalog SET #{clauses_sql} WHERE slug=?
        """, bindings ++ [now, slug])
      end
    end

    # MCP catalog: update mcp_url (per-org row).
    if v = Map.get(params, "mcp_url") do
      if is_binary(v) do
        query!(Repo, """
        UPDATE mcp_catalog SET mcp_url=?, updated_at=? WHERE org_id=? AND slug=?
        """, [v, now, org_id, slug])
      end
    end

    # Enabled flag — optional. Lets the FE flip the row on without
    # a separate /enable round-trip.
    if Map.has_key?(params, "enabled") do
      enabled_int = if params["enabled"], do: 1, else: 0

      query!(Repo, """
      UPDATE mcp_catalog SET enabled=?, updated_at=? WHERE org_id=? AND slug=?
      """, [enabled_int, now, org_id, slug])
    end

    Proxy.json(conn, 200, %{ok: true})
  end

  # ─── List build ───────────────────────────────────────────────────────

  defp build_list(user) do
    oauth = oauth_rows_by_slug()
    mcp   = mcp_rows_by_slug(user)

    Connectors.Registry.universal_modules()
    |> Enum.map(fn mod ->
      slug = mod.mcp_slug()
      o    = Map.get(oauth, slug, %{})
      m    = Map.get(mcp,   slug, %{})

      %{
        slug:              slug,
        display_name:      Map.get(o, :display_name) || derive_display_name(slug),
        auth_kind:         apply_or(mod, :credential_kind, :oauth2),
        mcp_url:           Map.get(m, :mcp_url),
        mcp_url_set:       (Map.get(m, :mcp_url) not in [nil, ""]),
        client_id_present: (Map.get(o, :client_id) not in [nil, ""]),
        scopes:            Map.get(o, :scopes, []),
        enabled:           Map.get(m, :enabled, false),
        last_probe_status: Map.get(m, :last_probe_status),
        last_probe_at:     Map.get(m, :last_probe_at),
        manifest_verbs:    manifest_verb_names(mod)
      }
    end)
  end

  defp oauth_rows_by_slug do
    rows =
      query!(Repo, """
      SELECT slug, display_name, client_id, scopes_default,
             authorization_endpoint, token_endpoint
      FROM oauth_catalog
      """, []).rows

    Enum.into(rows, %{}, fn [slug, display_name, client_id, scopes_json, auth_url, token_url] ->
      {slug,
       %{
         display_name: display_name,
         client_id:    client_id,
         scopes:       decode_json_list(scopes_json),
         auth_url:     auth_url,
         token_url:    token_url
       }}
    end)
  end

  defp mcp_rows_by_slug(user) do
    org_id = Map.get(user, :org_id) || DmhAi.Constants.default_org_id()

    rows =
      query!(Repo, """
      SELECT slug, mcp_url, enabled, last_probe_status, last_probe_at
      FROM mcp_catalog
      WHERE org_id=?
      """, [org_id]).rows

    Enum.into(rows, %{}, fn [slug, url, enabled, status, probed_at] ->
      {slug,
       %{
         mcp_url:           url,
         enabled:           enabled == 1,
         last_probe_status: status,
         last_probe_at:     probed_at
       }}
    end)
  end

  defp manifest_verb_names(mod) do
    case apply_or(mod, :manifest, nil) do
      %{verbs: verbs} when is_map(verbs) -> Map.keys(verbs) |> Enum.sort()
      _                                  -> []
    end
  end

  defp derive_display_name(slug),
    do: slug |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  defp apply_or(mod, fun, default) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: default
  end

  defp decode_json_list(nil), do: []
  defp decode_json_list(""),  do: []
  defp decode_json_list(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, list} when is_list(list) -> list
      _                              -> []
    end
  end

  # ─── Probe ────────────────────────────────────────────────────────────

  defp probe_slug(user, slug) do
    org_id = Map.get(user, :org_id) || DmhAi.Constants.default_org_id()

    case query!(Repo, """
    SELECT mcp_url FROM mcp_catalog WHERE org_id=? AND slug=?
    """, [org_id, slug]).rows do
      [[url]] when is_binary(url) and url != "" ->
        probe_url(url)

      _ ->
        {:error, "mcp_catalog row not found or mcp_url empty for slug=#{slug}"}
    end
  end

  defp probe_url(url) do
    init_req = %{method: "initialize", params: %{}}

    case Transport.request(url, init_req, %{type: "none"}) do
      {:ok, %{"result" => %{"serverInfo" => info}}, _} ->
        list_req = %{method: "tools/list", params: %{}}

        case Transport.request(url, list_req, %{type: "none"}) do
          {:ok, %{"result" => %{"tools" => tools}}, _} when is_list(tools) ->
            {:ok, %{server_info: info, verb_count: length(tools),
                    verb_names: Enum.map(tools, & &1["name"])}}

          {:ok, _, _} ->
            {:error, "tools/list returned non-MCP body"}

          {:error, {:status, status, _, _}} ->
            {:error, "tools/list returned HTTP #{status}"}

          {:error, {:network, reason}} ->
            {:error, "network error on tools/list: #{inspect(reason)}"}
        end

      {:ok, _, _} ->
        {:error, "initialize returned non-MCP body"}

      {:error, {:status, status, _, _}} ->
        {:error, "initialize returned HTTP #{status}"}

      {:error, {:network, reason}} ->
        {:error, "network error on initialize: #{inspect(reason)}"}
    end
  end
end
