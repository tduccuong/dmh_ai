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

  # Universal Region slice-3 connectors — manifest modules haven't
  # landed yet but the FE External Connectors page lists them as
  # "Coming soon" so admins know the full target surface. Keep
  # this list in lock-step with the slice-3 ticket numbers in the
  # 0.3 audit. When a connector module is added to
  # `Connectors.Registry.universal_modules/0`, drop its slug from
  # this list — the registered path takes over automatically.
  @planned_connectors [
    %{slug: "shopify",     display_name: "Shopify",       auth_kind: "oauth"},
    %{slug: "salesforce",  display_name: "Salesforce",    auth_kind: "oauth"},
    %{slug: "slack",       display_name: "Slack",         auth_kind: "oauth"},
    %{slug: "zoom",        display_name: "Zoom",          auth_kind: "oauth"},
    %{slug: "docusign",    display_name: "DocuSign",      auth_kind: "oauth"},
    %{slug: "calendly",    display_name: "Calendly",      auth_kind: "oauth"},
    %{slug: "klaviyo",     display_name: "Klaviyo",       auth_kind: "api_key"},
    %{slug: "atlassian",   display_name: "Atlassian",     auth_kind: "oauth"},
    %{slug: "asana",       display_name: "Asana",         auth_kind: "oauth"},
    %{slug: "notion",      display_name: "Notion",        auth_kind: "oauth"},
    %{slug: "brevo",       display_name: "Brevo",         auth_kind: "api_key"}
  ]

  def list(conn, user) do
    if user.role != "admin" do
      Proxy.json(conn, 403, %{error: "Forbidden"})
    else
      Proxy.json(conn, 200, %{
        connectors:        build_list(user),
        oauth_redirect_uri: oauth_redirect_uri()
      })
    end
  end

  # Computed at request time so the admin sees the URI matching the
  # current deployment — defaults to `http://localhost:8080/oauth/callback`,
  # operator overrides via the `oauth_redirect_base_url` setting when
  # behind a real DNS / TLS frontend. Same string for every connector
  # (one OAuth callback handles all of them).
  defp oauth_redirect_uri do
    DmhAi.Agent.AgentSettings.oauth_redirect_base_url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/oauth/callback")
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

    # Capability curation — admin's ticked subset. JSON array of
    # capability ids. NULL/absent means "all enabled" (a row the
    # admin hasn't yet curated). Empty array means "deliberately
    # none enabled" — connector reachable but no functions exposed.
    if Map.has_key?(params, "enabled_capabilities") do
      caps_json =
        case params["enabled_capabilities"] do
          list when is_list(list) -> Jason.encode!(list)
          nil                      -> nil
          _                        -> nil
        end

      query!(Repo, """
      UPDATE mcp_catalog SET enabled_capabilities=?, updated_at=? WHERE org_id=? AND slug=?
      """, [caps_json, now, org_id, slug])
    end

    Proxy.json(conn, 200, %{ok: true})
  end

  # ─── List build ───────────────────────────────────────────────────────

  defp build_list(user) do
    oauth = oauth_rows_by_slug()
    mcp   = mcp_rows_by_slug(user)

    registered =
      Connectors.Registry.universal_modules()
      |> Enum.map(fn mod ->
        slug = mod.mcp_slug()
        o    = Map.get(oauth, slug, %{})
        m    = Map.get(mcp,   slug, %{})

        %{
          slug:                  slug,
          display_name:          Map.get(o, :display_name) || derive_display_name(slug),
          auth_kind:             apply_or(mod, :credential_kind, :oauth2),
          status:                "registered",
          mcp_url:               Map.get(m, :mcp_url),
          mcp_url_set:           (Map.get(m, :mcp_url) not in [nil, ""]),
          # Connectors that host their MCP server in-process (e.g.
          # GoogleWorkspace's REST translator) export default_mcp_url/0
          # so the FE can pre-fill the field — admin doesn't need to
          # know the deployment-internal URL. Case-B vendor-hosted
          # connectors leave it nil → FE shows an empty placeholder.
          default_mcp_url:       apply_or(mod, :default_mcp_url, nil),
          capabilities:          apply_or(mod, :capabilities, []),
          enabled_capabilities:  Map.get(m, :enabled_capabilities),
          client_id:             Map.get(o, :client_id, ""),
          client_id_present:     (Map.get(o, :client_id) not in [nil, ""]),
          client_secret_present: Map.get(o, :client_secret_present, false),
          scopes:                Map.get(o, :scopes, []),
          enabled:               Map.get(m, :enabled, false),
          last_probe_status:     Map.get(m, :last_probe_status),
          last_probe_at:         Map.get(m, :last_probe_at),
          manifest_functions:    manifest_function_names(mod)
        }
      end)

    planned =
      @planned_connectors
      |> Enum.map(fn p ->
        %{
          slug:                  p.slug,
          display_name:          p.display_name,
          auth_kind:             p.auth_kind,
          status:                "planned",
          mcp_url:               nil,
          mcp_url_set:           false,
          default_mcp_url:       nil,
          capabilities:          [],
          enabled_capabilities:  nil,
          client_id:             "",
          client_id_present:     false,
          client_secret_present: false,
          scopes:                [],
          enabled:               false,
          last_probe_status:     nil,
          last_probe_at:         nil,
          manifest_functions:    []
        }
      end)

    registered ++ planned
  end

  defp oauth_rows_by_slug do
    rows =
      query!(Repo, """
      SELECT slug, display_name, client_id, client_secret, scopes_default,
             authorization_endpoint, token_endpoint
      FROM oauth_catalog
      """, []).rows

    Enum.into(rows, %{}, fn [slug, display_name, client_id, client_secret, scopes_json, auth_url, token_url] ->
      {slug,
       %{
         display_name:           display_name,
         # client_id is NOT a secret — it appears verbatim in every
         # OAuth consent URL the provider generates. Expose it
         # directly so the admin UI can pre-fill the field instead
         # of forcing the operator to remember it.
         client_id:              client_id,
         # client_secret IS a secret — never echo back. The FE
         # uses this presence flag to decide between a "paste new"
         # vs "redacted dots" placeholder.
         client_secret_present:  client_secret not in [nil, ""],
         scopes:                 decode_json_list(scopes_json),
         auth_url:               auth_url,
         token_url:              token_url
       }}
    end)
  end

  defp mcp_rows_by_slug(user) do
    org_id = Map.get(user, :org_id) || DmhAi.Constants.default_org_id()

    rows =
      query!(Repo, """
      SELECT slug, mcp_url, enabled, enabled_capabilities, last_probe_status, last_probe_at
      FROM mcp_catalog
      WHERE org_id=?
      """, [org_id]).rows

    Enum.into(rows, %{}, fn [slug, url, enabled, caps_json, status, probed_at] ->
      {slug,
       %{
         mcp_url:              url,
         enabled:              enabled == 1,
         # nil here means "admin has not curated yet" (Capabilities
         # module treats nil as all-enabled); an empty list means
         # "deliberately none enabled" — semantically distinct.
         enabled_capabilities: decode_json_list_or_nil(caps_json),
         last_probe_status:    status,
         last_probe_at:        probed_at
       }}
    end)
  end

  defp decode_json_list_or_nil(nil), do: nil
  defp decode_json_list_or_nil(""),  do: nil
  defp decode_json_list_or_nil(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, list} when is_list(list) -> list
      _                              -> nil
    end
  end

  defp manifest_function_names(mod) do
    case apply_or(mod, :manifest, nil) do
      %{functions: functions} when is_map(functions) -> Map.keys(functions) |> Enum.sort()
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
            {:ok, %{server_info: info, function_count: length(tools),
                    function_names: Enum.map(tools, & &1["name"])}}

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
