# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.MCP.Probe do
  @moduledoc """
  Shared MCP probe: classifies an MCP server URL by issuing an
  unauthenticated `initialize` and inspecting the response.

  Used in two places:
    * `Dmhai.Tools.ConnectMcp` — per-chat, fresh-connection cascade
      (called with no prior knowledge of the URL's auth model).
    * `Dmhai.MCP.Catalog` — admin-side preflight on Enable, so the
      catalog row records the auth_kind + AS metadata once and
      every later `connect_mcp(slug:)` skips re-discovery.

  Classification:
    * `:open`                 — 200 + valid `Mcp-Session-Id`. Service
      accepts `Authorization: none` traffic.
    * `{:gated, prm_hint}`    — 401. `prm_hint` is the
      `resource_metadata=<URL>` value from `WWW-Authenticate`
      (RFC 9728 §5.1) when present, else `nil` and callers fall
      back to the RFC 8615 well-known path.
    * `:not_mcp`              — anything else: 404, 5xx, transport
      error, or 200-with-non-MCP body. URL isn't an MCP server.
  """

  alias Dmhai.MCP.Client, as: MCPClient

  @type result :: :open | {:gated, String.t() | nil} | :not_mcp

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
        # Server understood the JSON-RPC envelope but errored —
        # still MCP, treat as gated and let the OAuth path try.
        {:gated, nil}

      {:error, {:status, 401, _body, headers}} ->
        {:gated, parse_resource_metadata_hint(headers)}

      _ ->
        :not_mcp
    end
  end

  @doc """
  Pull the `resource_metadata=<URL>` parameter out of a
  `WWW-Authenticate` header per RFC 9728 §5.1. Tolerates quoted /
  unquoted forms, multiple challenge schemes, extra whitespace.
  Returns `nil` when the param is missing.
  """
  @spec parse_resource_metadata_hint([{String.t(), String.t()}] | any()) :: String.t() | nil
  def parse_resource_metadata_hint(headers) when is_list(headers) do
    case Enum.find(headers, fn {k, _} -> k == "www-authenticate" end) do
      nil                              -> nil
      {_, value} when is_binary(value) -> extract_resource_metadata(value)
      _                                -> nil
    end
  end

  def parse_resource_metadata_hint(_), do: nil

  defp extract_resource_metadata(value) do
    case Regex.run(~r/resource_metadata\s*=\s*"?([^",\s]+)"?/i, value) do
      [_, url] -> url
      _        -> nil
    end
  end
end
