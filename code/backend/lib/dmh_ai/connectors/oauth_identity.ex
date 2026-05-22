# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.OAuthIdentity do
  @moduledoc """
  Optional behaviour for Layer-0.3 connector modules that can resolve
  the connecting user's identity at the vendor after the OAuth token
  exchange completes.

  The connector module owns:
    * The endpoint URL (current best — `/oauth/v1/access-tokens/<token>`
      for HubSpot, `/userinfo` for OIDC providers, etc.).
    * The auth model (token-in-Bearer-header, token-in-path, custom
      headers, multi-step calls — whatever the vendor demands).
    * Response parsing (OIDC giving `email` at the root vs. Calendly
      nesting `resource.email`, HubSpot's `user` field).

  When `finalize_connector_oauth` runs after a successful OAuth
  callback, it dispatches via `function_exported?(mod, :fetch_userinfo, 1)`
  — connectors that don't capture identity (Stripe, anonymous MCP)
  simply don't implement the callback and the credential row's
  `account` field stays empty. No data-driven descriptor fields, no
  catalog-row template substitution, no per-vendor branching in the
  generic OAuth path.

  The shared OIDC helper at `DmhAi.OAuth.Identity.OIDC.fetch/3`
  covers the standard case (Bearer-auth GET, JSONPath field
  extraction) so most connector implementations are one line.
  """

  @typedoc """
  Identity facts captured at OAuth time. All keys optional; the
  caller is expected to handle missing fields gracefully (default to
  `""` when persisting to `user_credentials.account`).
  """
  @type identity :: %{
          optional(:email) => String.t() | nil,
          optional(:id)    => String.t() | nil,
          optional(:name)  => String.t() | nil
        }

  @callback fetch_userinfo(access_token :: String.t()) ::
              {:ok, identity()} | {:error, term()}

  @optional_callbacks fetch_userinfo: 1

  @doc """
  Reflect whether a connector module exports the callback. Used by
  the OAuth finalize path to decide between calling the connector or
  leaving `account = ""`.
  """
  @spec implements?(module()) :: boolean()
  def implements?(mod) when is_atom(mod),
    do: function_exported?(mod, :fetch_userinfo, 1)

  def implements?(_), do: false
end
