# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Auth.Discovery do
  @moduledoc """
  OAuth 2.1 / MCP authorization metadata discovery.

  Two well-known endpoints are fetched:

  - **PRM** (Protected Resource Metadata, RFC 9728) at
    `<resource>/.well-known/oauth-protected-resource`. Tells us which
    authorization server protects this resource and the canonical
    resource id used in Resource Indicators (RFC 8707).

  - **ASM** (Authorization Server Metadata, RFC 8414) at
    `<auth-server>/.well-known/oauth-authorization-server`. Tells us
    where to send the authorization-code flow, where to exchange the
    code, where to revoke, and which client-registration mechanism
    the server supports.

  Both endpoints return a JSON document. The fetch helpers normalise
  the response into a flat keyword-friendly map and perform minimal
  validation; callers (`Auth.OAuth2`, `Tools.ConnectMcp`) decide
  what to do when fields are missing.
  """

  @http_timeout_ms 10_000

  @doc """
  Fetch PRM (RFC 9728) for `resource_url`. The well-known URI is
  built by inserting `.well-known/oauth-protected-resource` between
  the resource's authority and its path — so
  `https://example.com/mcp` becomes
  `https://example.com/.well-known/oauth-protected-resource/mcp`,
  not `https://example.com/mcp/.well-known/oauth-protected-resource`.

  Returns:
    * `{:ok, prm}` where `prm` carries at least
      `:authorization_servers` (non-empty list) and `:resource`.
    * `{:error, :not_found}` for HTTP 404 (server doesn't publish PRM).
    * `{:error, {:status, n}}` for any other non-200.
    * `{:error, {:network, reason}}` for transport-level failures.
    * `{:error, {:malformed, reason}}` if the response isn't valid JSON
      or is missing required fields.
  """
  @spec fetch_prm(String.t()) ::
          {:ok, map()}
          | {:error, :not_found | {:status, integer()} | {:network, term()} | {:malformed, term()}}
  def fetch_prm(resource_url) when is_binary(resource_url) do
    url = rfc8615_well_known(resource_url, "oauth-protected-resource")
    do_fetch_json(url, &parse_prm/1)
  end

  @doc """
  Fetch a PRM document directly from a known URL. Used when the
  authorization server's 401 response advertised the PRM location
  via `WWW-Authenticate: ... resource_metadata="<url>"` (RFC 9728
  §5.1). That hint is preferred over the RFC 8615 well-known
  construction because it works regardless of where the server
  actually publishes the doc.
  """
  @spec fetch_prm_at(String.t()) ::
          {:ok, map()}
          | {:error, :not_found | {:status, integer()} | {:network, term()} | {:malformed, term()}}
  def fetch_prm_at(prm_url) when is_binary(prm_url) do
    do_fetch_json(prm_url, &parse_prm/1)
  end

  @doc """
  Fetch ASM (RFC 8414) for `auth_server_url`. Well-known URI is
  built the same way as `fetch_prm/1` — `.well-known/oauth-
  authorization-server` is inserted between authority and path.

  Falls back to OpenID Connect Discovery
  (`.well-known/openid-configuration`, RFC 5785 + OIDC §4) on
  `:not_found`. The OIDC document is a SUPERSET of RFC 8414 — it
  carries the same `authorization_endpoint`, `token_endpoint`,
  `code_challenge_methods_supported`, `scopes_supported`,
  `registration_endpoint` fields plus OIDC-specific extras we
  ignore. Without this fallback every OIDC-only provider (Google,
  Microsoft Entra, Okta, Auth0, Keycloak, AWS Cognito, Atlassian,
  …) bounces to the manual-setup form even though their metadata
  is right there.

  Returns the same shape as `fetch_prm/1`. `:not_found` means
  neither well-known path responded; discovery falls through to
  the manual setup branch.
  """
  @spec fetch_asm(String.t()) ::
          {:ok, map()}
          | {:error, :not_found | {:status, integer()} | {:network, term()} | {:malformed, term()}}
  def fetch_asm(auth_server_url) when is_binary(auth_server_url) do
    rfc8414_url = rfc8615_well_known(auth_server_url, "oauth-authorization-server")

    case do_fetch_json(rfc8414_url, &parse_asm/1) do
      {:ok, _} = ok ->
        ok

      {:error, :not_found} ->
        # OIDC Discovery (OpenID Connect Core §4) appends
        # `.well-known/openid-configuration` to the issuer URL —
        # different from RFC 8615's "insert between authority and
        # path" convention RFC 8414 mandates. Microsoft Entra,
        # Auth0, and Keycloak all publish at the append-form path.
        # Google publishes at both, so we'd find it either way; the
        # append form makes the failing providers work too.
        oidc_url = String.trim_trailing(auth_server_url, "/") <> "/.well-known/openid-configuration"
        do_fetch_json(oidc_url, &parse_asm/1)

      err ->
        err
    end
  end

  # ── private ───────────────────────────────────────────────────────────

  # RFC 8615: the well-known URI inserts `.well-known/<suffix>`
  # between the URL's authority and path. For an empty / "/" path
  # this collapses to `https://host/.well-known/<suffix>`; for a
  # non-empty path it preserves the path as a suffix to the
  # well-known location. Examples:
  #
  #   https://example.com/mcp  →  https://example.com/.well-known/<suffix>/mcp
  #   https://example.com       →  https://example.com/.well-known/<suffix>
  defp rfc8615_well_known(base_url, suffix) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host, port: port, path: path} when is_binary(scheme) and is_binary(host) ->
        authority = scheme <> "://" <> host <> port_segment(scheme, port)
        path_part =
          case path do
            nil      -> ""
            ""        -> ""
            "/"       -> ""
            other     -> "/" <> String.trim_leading(other, "/")
          end

        authority <> "/.well-known/" <> suffix <> path_part

      _ ->
        # Fall back to the naive form for invalid URLs; the fetch
        # will fail downstream and surface a clear error.
        String.trim_trailing(base_url, "/") <> "/.well-known/" <> suffix
    end
  end

  defp port_segment("http",  80),  do: ""
  defp port_segment("https", 443), do: ""
  defp port_segment(_, nil),       do: ""
  defp port_segment(_, port),      do: ":" <> Integer.to_string(port)

  defp do_fetch_json(url, parser) do
    case Req.get(url, receive_timeout: @http_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        parser.(body)

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> parser.(decoded)
          {:error, reason} -> {:error, {:malformed, reason}}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp parse_prm(body) when is_map(body) do
    auth_servers = body["authorization_servers"]
    resource     = body["resource"]

    cond do
      not is_list(auth_servers) or auth_servers == [] ->
        {:error, {:malformed, "authorization_servers missing or empty"}}

      not is_binary(resource) or resource == "" ->
        {:error, {:malformed, "resource missing"}}

      true ->
        {:ok,
         %{
           authorization_servers:    auth_servers,
           resource:                 resource,
           bearer_methods_supported: body["bearer_methods_supported"] || ["header"],
           scopes_supported:         body["scopes_supported"] || []
         }}
    end
  end

  defp parse_prm(_), do: {:error, {:malformed, "PRM response not a JSON object"}}

  defp parse_asm(body) when is_map(body) do
    auth_endpoint  = body["authorization_endpoint"]
    token_endpoint = body["token_endpoint"]
    code_methods   = body["code_challenge_methods_supported"] || []

    cond do
      not is_binary(auth_endpoint) or auth_endpoint == "" ->
        {:error, {:malformed, "authorization_endpoint missing"}}

      not is_binary(token_endpoint) or token_endpoint == "" ->
        {:error, {:malformed, "token_endpoint missing"}}

      "S256" not in code_methods and code_methods != [] ->
        {:error, {:malformed, "S256 PKCE not advertised"}}

      true ->
        {:ok,
         %{
           authorization_endpoint:           auth_endpoint,
           token_endpoint:                   token_endpoint,
           registration_endpoint:            body["registration_endpoint"],
           revocation_endpoint:              body["revocation_endpoint"],
           scopes_supported:                 body["scopes_supported"] || [],
           code_challenge_methods_supported: code_methods,
           grant_types_supported:            body["grant_types_supported"] || ["authorization_code"],
           token_endpoint_auth_methods:      body["token_endpoint_auth_methods_supported"] || ["client_secret_post"],
           issuer:                           body["issuer"]
         }}
    end
  end

  defp parse_asm(_), do: {:error, {:malformed, "ASM response not a JSON object"}}
end
