# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPCatalogSeed do
  @moduledoc """
  Seeder for `mcp_catalog` rows. Writes VENDOR metadata only —
  `name`, `description`, `auth_kind`, `categories`. The admin sets
  `mcp_url` (where the vendor's MCP server lives) and `enabled`
  via `/admin/connectors/:slug/save`; the seeder never touches
  those columns once the row exists. The FE Save is the only
  writer of operator-owned fields.

  On first install the row is INSERTed with empty `mcp_url` and
  `enabled=1`; the admin then opens External Connectors and types
  the MCP URL (real vendor endpoint in production, mock URL in
  stage demos). On every subsequent boot the seeder refreshes
  vendor metadata only.

  Per-org scoping: the catalog is per-org (Primitive 0.1). One
  row per `(org_id, slug)` — single-tenant installs use
  `org_id = "default"`.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @typedoc """
  Per-connector MCP catalog descriptor — vendor facts only.

    * `:slug` — must match the connector module's `mcp_slug/0`
       and (by convention) the user's `authorized_services.alias`
       after `connect_mcp` runs.
    * `:name` — operator-facing label.
    * `:description` — operator-facing one-line summary.
    * `:auth_kind` — `:oauth` | `:api_key` | `:none`. Matches the
       paired oauth_catalog row when applicable.
    * `:categories` — list of strings for FE filtering.
    * `:org_id` — defaults to `"default"` (single-tenant install).
  """
  @type descriptor :: %{
          required(:slug)        => String.t(),
          required(:name)        => String.t(),
          required(:description) => String.t(),
          required(:auth_kind)   => :oauth | :api_key | :none,
          optional(:categories)  => [String.t()],
          optional(:org_id)      => String.t()
        }

  @doc """
  Upsert an mcp_catalog row by `(org_id, slug)`. First boot
  INSERTs with vendor metadata + empty mcp_url + enabled=1.
  Subsequent boots UPDATE vendor metadata only.
  """
  @spec upsert!(descriptor()) :: :ok
  def upsert!(%{slug: slug} = d) when is_binary(slug) and slug != "" do
    org_id    = Map.get(d, :org_id, "default")
    auth_kind = d.auth_kind |> Atom.to_string()
    cats_json = Jason.encode!(Map.get(d, :categories, []))
    now       = System.os_time(:millisecond)

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
          org_id, slug, d.name, d.description, "", cats_json,
          1, auth_kind, now, now
        ])

        Logger.info("[MCPCatalogSeed] inserted org=#{org_id} slug=#{slug}")

      _ ->
        query!(Repo, """
        UPDATE mcp_catalog
           SET name=?, description=?, categories=?,
               auth_kind=?, updated_at=?
         WHERE org_id=? AND slug=?
        """, [
          d.name, d.description, cats_json,
          auth_kind, now,
          org_id, slug
        ])

        Logger.debug("[MCPCatalogSeed] refreshed vendor metadata org=#{org_id} slug=#{slug}")
    end

    :ok
  end
end
