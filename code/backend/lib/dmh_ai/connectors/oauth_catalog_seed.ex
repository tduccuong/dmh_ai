# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.OAuthCatalogSeed do
  @moduledoc """
  Idempotent seeder for `oauth_catalog` rows. Boot-time and
  operator-runnable. One call per Universal-Region OAuth connector.
  Closes I2 generically — the per-connector module simply describes
  *what* its OAuth handshake looks like; this module is the *how*
  of writing the row.

  Reads `client_id` / `client_secret` from env vars named in the
  config so the operator can supply real Google / Microsoft /
  HubSpot credentials at install time without code change. A
  missing env var seeds the row with empty string for that field —
  the row still exists (so `authorize_service` can find it) but
  the actual OAuth flow will fail loudly until creds are filled in
  via the admin UI or a re-seed after env-var population.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @typedoc """
  Per-connector OAuth catalog descriptor.

    * `:slug` — must match the connector module's `mcp_slug/0`
    * `:display_name` — operator-facing label
    * `:host_match` — host pattern, used by the OAuth callback
       handler to route incoming tokens back to this catalog row
    * `:authorization_endpoint` / `:token_endpoint` — vendor-fixed
    * `:scopes` — list of OAuth scope strings (vendor-grounded)
    * `:client_id_env` / `:client_secret_env` — env-var names the
       operator populates with the values from their vendor app
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
          required(:client_id_env)          => String.t(),
          required(:client_secret_env)      => String.t(),
          optional(:userinfo_endpoint)      => String.t() | nil,
          optional(:userinfo_field_path)    => String.t() | nil,
          optional(:extra_auth_params)      => map(),
          optional(:extra_token_params)     => map(),
          optional(:enabled)                => boolean()
        }

  @doc """
  Upsert an oauth_catalog row by `slug`. Existing row → updated;
  new slug → inserted. Idempotent — same descriptor in, same DB
  state.
  """
  @spec upsert!(descriptor()) :: :ok
  def upsert!(%{slug: slug} = d) when is_binary(slug) and slug != "" do
    client_id     = System.get_env(d.client_id_env) || ""
    client_secret = System.get_env(d.client_secret_env)
    now           = System.os_time(:millisecond)
    scopes_json   = Jason.encode!(d.scopes)
    auth_params   = Jason.encode!(Map.get(d, :extra_auth_params, %{}))
    token_params  = Jason.encode!(Map.get(d, :extra_token_params, %{}))
    enabled       = if Map.get(d, :enabled, true), do: 1, else: 0

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
          scopes_json, client_id, client_secret,
          auth_params, token_params,
          Map.get(d, :userinfo_endpoint), Map.get(d, :userinfo_field_path),
          enabled, now, now
        ])

        Logger.info("[OAuthCatalogSeed] inserted slug=#{slug}")

      _ ->
        query!(Repo, """
        UPDATE oauth_catalog
           SET display_name=?, host_match=?,
               authorization_endpoint=?, token_endpoint=?,
               scopes_default=?, client_id=?, client_secret=?,
               extra_auth_params=?, extra_token_params=?,
               userinfo_endpoint=?, userinfo_field_path=?,
               enabled=?, updated_ts=?
         WHERE slug=?
        """, [
          d.display_name, d.host_match,
          d.authorization_endpoint, d.token_endpoint,
          scopes_json, client_id, client_secret,
          auth_params, token_params,
          Map.get(d, :userinfo_endpoint), Map.get(d, :userinfo_field_path),
          enabled, now, slug
        ])

        Logger.debug("[OAuthCatalogSeed] updated slug=#{slug}")
    end

    :ok
  end
end
