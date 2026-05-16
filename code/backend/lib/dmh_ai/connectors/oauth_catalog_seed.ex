# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.OAuthCatalogSeed do
  @moduledoc """
  Seeder for `oauth_catalog` rows. Boot-time. One call per
  Universal-Region OAuth connector. Writes VENDOR metadata only —
  `display_name`, `host_match`, endpoints, scopes, userinfo path,
  extra auth/token params. Never writes `client_id`,
  `client_secret`, or `enabled` — those are operator-owned via
  `/admin/connectors/:slug/save`. The admin's FE Save is the only
  writer of those columns.

  On first install the row is INSERTed with empty `client_id` /
  `client_secret` and `enabled=1`; the admin then opens External
  Connectors and pastes their vendor-app credentials. On every
  subsequent boot the seeder refreshes vendor fields only — if
  Google changes a scope or endpoint, the next deploy picks it up
  without clobbering the admin's credentials.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @typedoc """
  Per-connector OAuth catalog descriptor — vendor facts only.

    * `:slug` — must match the connector module's `mcp_slug/0`
    * `:display_name` — operator-facing label
    * `:host_match` — host pattern, used by the OAuth callback
       handler to route incoming tokens back to this catalog row
    * `:authorization_endpoint` / `:token_endpoint` — vendor-fixed
    * `:scopes` — list of OAuth scope strings (vendor-grounded)
    * `:userinfo_endpoint` / `:userinfo_field_path` — optional,
       used by the multi-account auth flow to label credentials
       with the authenticated user's email/id
    * `:extra_auth_params` / `:extra_token_params` — optional
       query/body additions some vendors require (e.g. Google's
       `access_type=offline` + `prompt=consent` to get a refresh
       token on every grant)
  """
  @type descriptor :: %{
          required(:slug)                   => String.t(),
          required(:display_name)           => String.t(),
          required(:host_match)             => String.t(),
          required(:authorization_endpoint) => String.t(),
          required(:token_endpoint)         => String.t(),
          required(:scopes)                 => [String.t()],
          optional(:userinfo_endpoint)      => String.t() | nil,
          optional(:userinfo_field_path)    => String.t() | nil,
          optional(:extra_auth_params)      => map(),
          optional(:extra_token_params)     => map()
        }

  @doc """
  Upsert an oauth_catalog row by `slug`. First boot INSERTs the
  row with vendor metadata + empty operator fields. Subsequent
  boots UPDATE vendor metadata only.
  """
  @spec upsert!(descriptor()) :: :ok
  def upsert!(%{slug: slug} = d) when is_binary(slug) and slug != "" do
    now          = System.os_time(:millisecond)
    scopes_json  = Jason.encode!(d.scopes)
    auth_params  = Jason.encode!(Map.get(d, :extra_auth_params, %{}))
    token_params = Jason.encode!(Map.get(d, :extra_token_params, %{}))

    %{rows: rows} =
      query!(Repo, """
      SELECT id FROM oauth_catalog WHERE slug=? LIMIT 1
      """, [slug])

    case rows do
      [] ->
        query!(Repo, """
        INSERT INTO oauth_catalog
          (slug, display_name, host_match, authorization_endpoint, token_endpoint,
           scopes_default, client_id, client_secret,
           extra_auth_params, extra_token_params,
           userinfo_endpoint, userinfo_field_path,
           enabled, created_ts, updated_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
          slug, d.display_name, d.host_match,
          d.authorization_endpoint, d.token_endpoint,
          scopes_json, "", nil,
          auth_params, token_params,
          Map.get(d, :userinfo_endpoint), Map.get(d, :userinfo_field_path),
          1, now, now
        ])

        Logger.info("[OAuthCatalogSeed] inserted slug=#{slug}")

      _ ->
        query!(Repo, """
        UPDATE oauth_catalog
           SET display_name=?, host_match=?,
               authorization_endpoint=?, token_endpoint=?,
               scopes_default=?,
               extra_auth_params=?, extra_token_params=?,
               userinfo_endpoint=?, userinfo_field_path=?,
               updated_ts=?
         WHERE slug=?
        """, [
          d.display_name, d.host_match,
          d.authorization_endpoint, d.token_endpoint,
          scopes_json,
          auth_params, token_params,
          Map.get(d, :userinfo_endpoint), Map.get(d, :userinfo_field_path),
          now, slug
        ])

        Logger.debug("[OAuthCatalogSeed] refreshed vendor metadata slug=#{slug}")
    end

    :ok
  end
end
