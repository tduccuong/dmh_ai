# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.MCP.Probe do
  @moduledoc """
  Shared MCP probe: classifies an MCP server URL by issuing an
  unauthenticated `initialize` and inspecting the response.

  Used in two places:
    * `DmhAi.Tools.ConnectMcp` — per-chat, fresh-connection cascade
      (called with no prior knowledge of the URL's auth model).
    * `DmhAi.MCP.Catalog` — admin-side preflight on Enable, so the
      catalog row records the auth_kind + AS metadata once and
      every later `connect_mcp(slug:)` skips re-discovery.

  Classification:

    * `:open` — 200 + valid `Mcp-Session-Id`. Service accepts
      `Authorization: none` traffic.

    * `{:gated, gated_meta()}` — 401, with details about the
      challenge:

        - `prm_hint`         — the `resource_metadata=<URL>` value
          from `WWW-Authenticate` (RFC 9728 §5.1) when present, else
          `nil` (callers fall back to RFC 8615 well-known).
        - `www_authenticate` — the raw header value (or `nil`).
        - `auth_type`        — classified from the challenge scheme:

            * `:oauth`     — `Bearer …` scheme (standard MCP-OAuth path).
            * `:api_key`   — non-Bearer scheme (`ApiKey`, `Token`, …)
              or no header at all but a 401 — caller prompts the user
              for a single API key.
            * `:ambiguous` — header malformed beyond classification.
              Caller bails honestly; admin curation can fill in.

    * `:not_mcp` — anything else: 404, 5xx, transport error, or
      200-with-non-MCP body. URL isn't an MCP server.
  """

  alias DmhAi.MCP.Client, as: MCPClient

  @type gated_meta :: %{
          prm_hint:         String.t() | nil,
          www_authenticate: String.t() | nil,
          auth_type:        :oauth | :api_key | :ambiguous
        }

  @type result :: :open | {:gated, gated_meta()} | :not_mcp

  @spec classify(String.t()) :: result()
  def classify(server_url) when is_binary(server_url) do
    handshake_ctx = %{
      server_url:         server_url,
      canonical_resource: server_url,
      auth:               %{type: "none"}
    }

    case MCPClient.initialize(handshake_ctx) do
      {:ok, _info, sid} when is_binary(sid) and sid != "" ->
        :open

      {:error, {:rpc, _err}} ->
        # Server understood JSON-RPC but errored — still MCP, treat
        # as OAuth-gated (the most common gating mode) and let the
        # caller's OAuth flow try discovery.
        {:gated, gated_meta(nil, nil, :oauth)}

      {:error, {:status, 401, _body, headers}} ->
        www_auth = get_www_authenticate(headers)

        {:gated,
         gated_meta(
           parse_resource_metadata_hint(www_auth),
           www_auth,
           classify_scheme(www_auth)
         )}

      _ ->
        :not_mcp
    end
  end

  defp gated_meta(prm_hint, www_auth, auth_type) do
    %{prm_hint: prm_hint, www_authenticate: www_auth, auth_type: auth_type}
  end

  @doc """
  Pull the `resource_metadata=<URL>` parameter out of a
  `WWW-Authenticate` header per RFC 9728 §5.1. Tolerates quoted /
  unquoted forms, multiple challenge schemes, extra whitespace.
  Returns `nil` when the param is missing.
  """
  @spec parse_resource_metadata_hint(String.t() | nil) :: String.t() | nil
  def parse_resource_metadata_hint(value) when is_binary(value) do
    case Regex.run(~r/resource_metadata\s*=\s*"?([^",\s]+)"?/i, value) do
      [_, url] -> url
      _        -> nil
    end
  end

  def parse_resource_metadata_hint(_), do: nil

  @doc """
  Classify the auth scheme in a `WWW-Authenticate` header.

  - Header starting with `Bearer` (case-insensitive) → `:oauth`.
  - Any other named scheme (`ApiKey`, `Token`, `X-API-Key`, …) →
    `:api_key`.
  - Missing or malformed → `:ambiguous`.

  RFC 7235 says the first whitespace-delimited token is the scheme
  name; we trust that and ignore params.
  """
  @spec classify_scheme(String.t() | nil) :: :oauth | :api_key | :ambiguous
  def classify_scheme(nil), do: :ambiguous

  def classify_scheme(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split(~r/[\s,]/, parts: 2)
    |> List.first()
    |> case do
      "" -> :ambiguous
      scheme when is_binary(scheme) ->
        case String.downcase(scheme) do
          "bearer" -> :oauth
          _        -> :api_key
        end
      _ -> :ambiguous
    end
  end

  defp get_www_authenticate(headers) when is_list(headers) do
    case Enum.find(headers, fn {k, _} -> k == "www-authenticate" end) do
      {_, value} when is_binary(value) -> value
      _                                 -> nil
    end
  end

  defp get_www_authenticate(_), do: nil
end
