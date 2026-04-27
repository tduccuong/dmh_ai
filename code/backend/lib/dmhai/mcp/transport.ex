# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.MCP.Transport do
  @moduledoc """
  Streamable HTTP transport for MCP. Speaks JSON-RPC over POST against
  the MCP server URL; bearer-token auth; Resource Indicator header.

  v1 sends and receives whole JSON-RPC messages — no SSE upgrade. The
  agent's chain loop already invokes tools synchronously, so a
  `tools/call` that takes a few seconds simply blocks the caller's
  Task. SSE streaming for progressive tool output lands when there's a
  concrete need.

  Returns the parsed JSON-RPC response (`%{"result" => …}` or
  `%{"error" => …}`) on success. On HTTP-level failures returns
  `{:error, {:status, n, body}}` (e.g. 401 — caller drives refresh)
  or `{:error, {:network, reason}}`.
  """

  @http_timeout_ms 30_000

  @doc """
  POST a JSON-RPC request body to `server_url` with the given
  authorization context. `request` is a map with `:method` and
  optional `:params`; `:id` and `:jsonrpc` are filled in.

  `auth` is a typed map describing how to attach credentials:

    * `%{type: "bearer", token: "...", canonical_resource: "..."}`
      — OAuth 2.1 bearer token. `Authorization: Bearer …` plus
      Resource Indicator (`MCP-Resource: …`).
    * `%{type: "api_key", header: "x-api-key", key: "...",
       canonical_resource: "..."}` — static API-key header. Header
      name is configurable (defaults expected to be `x-api-key`
      where standard).
    * `%{type: "none"}` or `%{}` — unauthenticated request.

  `:canonical_resource` is optional in every variant; emitted as
  `MCP-Resource:` when present.
  """
  @spec request(String.t(), map(), map()) ::
          {:ok, map(), %{session_id: String.t() | nil}}
          | {:error, {:status, integer(), term(), [{String.t(), String.t()}]} | {:network, term()}}
  def request(server_url, %{method: method} = req, auth \\ %{}) when is_binary(server_url) do
    body = %{
      "jsonrpc" => "2.0",
      "id"      => :erlang.unique_integer([:positive]),
      "method"  => method,
      "params"  => Map.get(req, :params) || %{}
    }

    headers = build_headers(auth, Map.get(req, :session_id))

    # Test hook (mirrors `Application.get_env(:dmhai,
    # :__llm_call_stub__)` in `Dmhai.Agent.LLM.call/3`). Lets tests
    # drive the discovery cascade and per-tool calls without standing
    # up a real MCP server. The stub receives the same arguments the
    # real Req.post would and must return one of the
    # request/3-shaped tuples. Production runs never set this env.
    if stub = Application.get_env(:dmhai, :__mcp_transport_stub__) do
      stub.(server_url, %{method: method, body: body, headers: headers, auth: auth, session_id: Map.get(req, :session_id)})
    else
      case Req.post(server_url,
             json: body,
             headers: headers,
             receive_timeout: @http_timeout_ms,
             retry: false
           ) do
        {:ok, %{status: 200, body: resp_body, headers: resp_headers}} ->
          {:ok, decode_body(resp_body), %{session_id: extract_session_id(resp_headers)}}

        {:ok, %{status: status, body: resp_body, headers: resp_headers}} ->
          # Surface response headers on non-200s too — Phase D's
          # probe-first cascade reads `WWW-Authenticate` on 401 to
          # find the spec-mandated `resource_metadata=<PRM URL>`
          # hint per RFC 9728 §5.1, which beats guessing the PRM
          # location via the RFC 8615 well-known construction.
          {:error, {:status, status, decode_body(resp_body), normalize_headers(resp_headers)}}

        {:error, reason} ->
          {:error, {:network, reason}}
      end
    end
  end

  # Streamable HTTP MCP servers allocate a session on `initialize` and
  # return its id in the `Mcp-Session-Id` response header. Subsequent
  # JSON-RPC requests in that session must echo the id; without it
  # spec-compliant servers reject with `-32600 Session ID required`.
  defp extract_session_id(resp_headers) when is_map(resp_headers) do
    case Map.get(resp_headers, "mcp-session-id") || Map.get(resp_headers, "Mcp-Session-Id") do
      [id | _] when is_binary(id) -> id
      id when is_binary(id)        -> id
      _                             -> nil
    end
  end

  defp extract_session_id(resp_headers) when is_list(resp_headers) do
    Enum.find_value(resp_headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == "mcp-session-id", do: v
      _ ->
        nil
    end)
  end

  defp extract_session_id(_), do: nil

  # Normalise Req's variable header shapes into a flat
  # `[{lowercased_key, value}]` list — Req sometimes returns a map,
  # sometimes a list of tuples, and value strings can themselves be
  # lists of one element. Callers get a stable shape they can grep.
  defp normalize_headers(h) when is_map(h) do
    Enum.flat_map(h, fn
      {k, v} when is_binary(v) -> [{String.downcase(to_string(k)), v}]
      {k, [v | _]}              -> [{String.downcase(to_string(k)), v}]
      _                         -> []
    end)
  end

  defp normalize_headers(h) when is_list(h) do
    Enum.flat_map(h, fn
      {k, v} when is_binary(v) -> [{String.downcase(to_string(k)), v}]
      {k, [v | _]}              -> [{String.downcase(to_string(k)), v}]
      _                         -> []
    end)
  end

  defp normalize_headers(_), do: []

  defp build_headers(%{type: "bearer", token: token} = auth, session_id) when is_binary(token) do
    [{"accept", "application/json, text/event-stream"}, {"authorization", "Bearer " <> token}]
    |> maybe_resource_header(auth)
    |> maybe_session_header(session_id)
  end

  defp build_headers(%{type: "api_key", header: hdr, key: key} = auth, session_id)
       when is_binary(hdr) and is_binary(key) and hdr != "" do
    [{"accept", "application/json, text/event-stream"}, {String.downcase(hdr), key}]
    |> maybe_resource_header(auth)
    |> maybe_session_header(session_id)
  end

  defp build_headers(%{type: "none"} = auth, session_id),
    do: [{"accept", "application/json, text/event-stream"}] |> maybe_resource_header(auth) |> maybe_session_header(session_id)

  defp build_headers(auth, session_id) when is_map(auth),
    do: [{"accept", "application/json, text/event-stream"}] |> maybe_resource_header(auth) |> maybe_session_header(session_id)

  defp maybe_session_header(headers, sid) when is_binary(sid) and sid != "",
    do: headers ++ [{"mcp-session-id", sid}]

  defp maybe_session_header(headers, _), do: headers

  defp maybe_resource_header(headers, %{canonical_resource: resource})
       when is_binary(resource) and resource != "" do
    headers ++ [{"mcp-resource", resource}]
  end

  defp maybe_resource_header(headers, _), do: headers

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} -> m
      _        -> %{"_raw" => body}
    end
  end

  defp decode_body(_), do: %{}
end
