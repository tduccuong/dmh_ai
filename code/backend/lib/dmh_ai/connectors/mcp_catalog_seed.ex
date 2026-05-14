# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPCatalogSeed do
  @moduledoc """
  Idempotent seeder for `mcp_catalog` rows. The mcp_catalog row
  tells the runtime *where* a vendor's MCP server lives — the row's
  `mcp_url` flows through `connect_mcp` → `authorized_services` →
  `MCP.Client.call_tool/4`. Closes #373 generically.

  The URL is read from an env var keyed in the descriptor so the
  operator points the deployment at:

    * Production: the real vendor MCP URL (e.g. Google Cloud's
      official MCP endpoint for Workspace).
    * Stage / demo: a `Connectors.Mock.VendorMCPServer` instance
      bound to a known port.
    * Tests: the in-process mock URL captured by `setup_supervised`.

  Per-org scoping: the catalog is per-org (Primitive 0.1). The
  seeder writes one row per `(org_id, slug)` — single-tenant
  installs use `org_id = "default"`; multi-tenant installs call
  the seeder once per org.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @typedoc """
  Per-connector MCP catalog descriptor.

    * `:slug` — must match the connector module's `mcp_slug/0`
       and (by convention) the user's `authorized_services.alias`
       after `connect_mcp` runs.
    * `:name` — operator-facing label.
    * `:description` — operator-facing one-line summary.
    * `:mcp_url_env` — env var the operator sets to the vendor's
       (or mock's) MCP endpoint URL. Required at seed time; the
       row stores whatever the env var contains (empty string if
       unset, with a warning logged).
    * `:org_id` — defaults to `"default"` (single-tenant install).
    * `:enabled` — defaults to `true`.
    * `:auth_kind` — `:oauth` | `:api_key` | `:none`. Matches the
       paired oauth_catalog row when applicable.
    * `:categories` — list of strings for FE filtering.
  """
  @type descriptor :: %{
          required(:slug)        => String.t(),
          required(:name)        => String.t(),
          required(:description) => String.t(),
          required(:mcp_url_env) => String.t(),
          required(:auth_kind)   => :oauth | :api_key | :none,
          optional(:org_id)      => String.t(),
          optional(:enabled)     => boolean(),
          optional(:categories)  => [String.t()]
        }

  @doc """
  Upsert an mcp_catalog row by `(org_id, slug)`. Returns `:ok`.
  Idempotent — same descriptor in, same DB state.
  """
  @spec upsert!(descriptor()) :: :ok
  def upsert!(%{slug: slug, mcp_url_env: url_env} = d)
      when is_binary(slug) and slug != "" do
    mcp_url   = System.get_env(url_env) || ""
    org_id    = Map.get(d, :org_id, "default")
    enabled   = if Map.get(d, :enabled, true), do: 1, else: 0
    auth_kind = d.auth_kind |> Atom.to_string()
    cats_json = Jason.encode!(Map.get(d, :categories, []))
    now       = System.os_time(:millisecond)

    if mcp_url == "" do
      Logger.warning(
        "[MCPCatalogSeed] env var #{url_env} is empty — seeding slug=#{slug} with empty mcp_url. " <>
          "Set #{url_env} and re-seed (or edit the catalog row in admin UI) before users can authorize."
      )
    end

    %{rows: rows} =
      query!(Repo, """
      SELECT id FROM mcp_catalog WHERE org_id=? AND slug=? LIMIT 1
      """, [org_id, slug])

    case rows do
      [] ->
        query!(Repo, """
        INSERT INTO mcp_catalog
          (org_id, slug, name, description, mcp_url, categories,
           enabled, auth_kind, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
          org_id, slug, d.name, d.description, mcp_url, cats_json,
          enabled, auth_kind, now, now
        ])

        Logger.info("[MCPCatalogSeed] inserted org=#{org_id} slug=#{slug} url=#{redact(mcp_url)}")

      _ ->
        query!(Repo, """
        UPDATE mcp_catalog
           SET name=?, description=?, mcp_url=?, categories=?,
               enabled=?, auth_kind=?, updated_at=?
         WHERE org_id=? AND slug=?
        """, [
          d.name, d.description, mcp_url, cats_json,
          enabled, auth_kind, now,
          org_id, slug
        ])

        Logger.debug("[MCPCatalogSeed] updated org=#{org_id} slug=#{slug}")
    end

    :ok
  end

  defp redact(""), do: "(empty)"
  defp redact(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: nil} -> "(invalid)"
      %URI{host: h}   -> h
    end
  end
end
