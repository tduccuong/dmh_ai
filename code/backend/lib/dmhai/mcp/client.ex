# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.MCP.Client do
  @moduledoc """
  MCP protocol client: handshake, tool catalog discovery, tool
  invocation. Sits on top of `Dmhai.MCP.Transport` and integrates with
  `Dmhai.Auth.Credentials` + `Dmhai.Auth.OAuth2` for bearer-token
  retrieval and 401-driven refresh.

  Three operations:

    * `initialize/1` — opens an MCP session against a server. Returns
      the server's protocol version, capabilities, and server info.
    * `list_tools/1` — fetches the server's `tools/list` catalog. Each
      entry carries `name`, `description`, and `inputSchema` —
      everything the LLM needs.
    * `call_tool/4` — invokes a tool by name, with arguments. Handles
      401 via one transparent refresh-then-retry; on still-401 the
      caller flips the connection's status to `needs_auth`.
  """

  alias Dmhai.Auth.OAuth2
  alias Dmhai.MCP.Transport

  @initialize_protocol_version "2025-06-18"

  @doc """
  Send the MCP `initialize` request. Returns `{:ok, server_info,
  session_id}` — the session id (from the `Mcp-Session-Id` response
  header, when present) must be threaded through to subsequent
  `tools/list` / `tools/call` requests in the same logical session.
  """
  @spec initialize(map()) :: {:ok, map(), String.t() | nil} | {:error, term()}
  def initialize(%{server_url: server_url} = conn) do
    case Transport.request(server_url, %{
           method: "initialize",
           params: %{
             "protocolVersion" => @initialize_protocol_version,
             "capabilities"    => %{},
             "clientInfo"      => %{"name" => "DMH-AI", "version" => "1.0"}
           }
         }, auth_for(conn)) do
      {:ok, %{"result" => result}, %{session_id: sid}} -> {:ok, result, sid}
      {:ok, %{"error" => err}, _meta}                   -> {:error, {:rpc, err}}
      {:ok, other, _meta}                                -> {:error, {:malformed, other}}
      {:error, _} = err                                  -> err
    end
  end

  @doc """
  Fetch `tools/list`. `session_id` (from `initialize/1`) is echoed in
  the `Mcp-Session-Id` header; spec-compliant servers reject the call
  when it's missing.
  """
  @spec list_tools(map(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list_tools(%{server_url: server_url} = conn, session_id \\ nil) do
    case Transport.request(server_url,
           %{method: "tools/list", session_id: session_id},
           auth_for(conn))
         |> unwrap_result() do
      {:ok, %{"tools" => tools}} when is_list(tools) -> {:ok, tools}
      {:ok, other} -> {:error, {:malformed_tools_list, other}}
      err          -> err
    end
  end

  @doc """
  Invoke a tool on the user's connected service. Each call opens a
  fresh MCP session (POST `initialize` → echo `Mcp-Session-Id` on
  the `tools/call`) — Streamable HTTP MCP servers track tool state
  per-session, and stateless calls without a session id are rejected.
  Two roundtrips per tool call; the spec doesn't expose a way to
  reuse a session across independent client processes.

  On 401 attempts a one-shot OAuth refresh + retry; on still-401
  returns `{:error, :unauthorized}` — the caller flips status to
  `needs_auth` and the model re-prompts the user via
  `connect_service`.
  """
  @spec call_tool(String.t(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def call_tool(user_id, alias_, tool_name, args) do
    case load_connection(user_id, alias_) do
      {:ok, conn} -> do_call(user_id, conn, tool_name, args, _retry = true)
      err         -> err
    end
  end

  defp do_call(user_id, conn, tool_name, args, retry?) do
    case initialize(conn) do
      {:ok, _server_info, session_id} ->
        res =
          Transport.request(conn.server_url, %{
            method:     "tools/call",
            params:     %{"name" => tool_name, "arguments" => args},
            session_id: session_id
          }, auth_for(conn))
          |> unwrap_result()

        case res do
          {:error, {:status, 401, _body}} when retry? and conn.cred_kind == "oauth2_mcp" ->
            handle_401_refresh(user_id, conn, tool_name, args)

          {:error, {:status, 401, _body}} ->
            {:error, :unauthorized}

          other ->
            other
        end

      {:error, {:status, 401, _body}} when retry? and conn.cred_kind == "oauth2_mcp" ->
        handle_401_refresh(user_id, conn, tool_name, args)

      {:error, {:status, 401, _body}} ->
        {:error, :unauthorized}

      err ->
        err
    end
  end

  defp handle_401_refresh(user_id, conn, tool_name, args) do
    case OAuth2.refresh(user_id, conn.cred_target) do
      {:ok, %{payload: payload}} ->
        refreshed = %{conn | auth: bearer_auth(payload, conn.canonical_resource)}
        do_call(user_id, refreshed, tool_name, args, false)

      {:error, _reason} ->
        # Refresh failed AS-side (revoked grant, expired refresh
        # token, AS down, …). Flip the registry to `needs_auth` so
        # the model: (a) stops seeing this service's tools in its
        # catalog and (b) sees the `[needs re-auth]` annotation in
        # the §Authorized MCP services block, which routes it to
        # `connect_service` for recovery. Returning `:needs_auth`
        # rather than `:unauthorized` lets the surface-level error
        # in the chat be specific.
        Dmhai.MCP.Registry.mark_needs_auth(user_id, conn.alias)
        {:error, :needs_auth}
    end
  end

  # ── private ───────────────────────────────────────────────────────────

  defp load_connection(user_id, alias_) do
    case Dmhai.MCP.Registry.find_authorized(user_id, alias_) do
      nil ->
        {:error, :unknown_alias}

      row ->
        target = "mcp:" <> row.canonical_resource

        # Proactive auto-refresh: when the credential is `oauth2_mcp`
        # and `is_expired`, `lookup_with_refresh/2` fires `refresh/2`
        # and returns the rotated tokens. Saves the 401 round-trip
        # the reactive path in `handle_401_refresh` would otherwise
        # catch. On `refresh_failed`, the wrapper has ALREADY flipped
        # the registry to `needs_auth`; we surface
        # `{:error, :needs_auth}` so the model gets the same recovery
        # path it'd get from a 401-then-refresh-fail.
        case OAuth2.lookup_with_refresh(user_id, target) do
          {:ok, %{kind: kind, payload: payload}} ->
            case build_auth(kind, payload, row.canonical_resource) do
              {:ok, auth} ->
                {:ok, %{
                  alias:              row.alias,
                  server_url:         row.server_url,
                  canonical_resource: row.canonical_resource,
                  auth:               auth,
                  cred_target:        target,
                  cred_kind:          kind,
                  cred_payload:       payload
                }}

              {:error, _} = err ->
                err
            end

          {:error, {:refresh_failed, _reason}} ->
            # Wrapper already flipped the registry to needs_auth;
            # the next chain will see the catalog filtered + the
            # `[needs re-auth]` annotation in the context block.
            {:error, :needs_auth}

          {:error, :missing} ->
            {:error, :missing_credentials}
        end
    end
  end

  defp build_auth("oauth2_mcp", %{"access_token" => at} = _payload, resource) when is_binary(at),
    do: {:ok, %{type: "bearer", token: at, canonical_resource: resource}}

  defp build_auth("api_key_mcp", %{"api_key" => key} = payload, resource) when is_binary(key) do
    header = case payload["api_key_header"] do
      h when is_binary(h) and h != "" -> h
      _ -> "x-api-key"
    end

    {:ok, %{type: "api_key", header: header, key: key, canonical_resource: resource}}
  end

  # Open MCP server: no Authorization header, no API key. The
  # credential row is a sentinel — written so `load_connection` can
  # find SOMETHING for the canonical resource and route through the
  # standard pipeline. Subsequent calls send `MCP-Resource:` only
  # (Resource Indicator stays for spec compliance) and skip auth
  # headers entirely. See `Tools.ConnectService` for the
  # storage-side contract.
  defp build_auth("none_mcp", _payload, resource),
    do: {:ok, %{type: "none", canonical_resource: resource}}

  defp build_auth(_kind, _payload, _resource),
    do: {:error, :unsupported_credential_kind}

  defp bearer_auth(%{"access_token" => at}, resource) when is_binary(at),
    do: %{type: "bearer", token: at, canonical_resource: resource}

  # `auth_for/1` builds the Transport-shaped auth descriptor from a
  # connection map. Two callers: the OAuth callback's post-token-
  # exchange handshake (which constructs a bare `%{server_url,
  # canonical_resource, access_token}` map) and `do_call/5` (which
  # already carries an `:auth` field built by `build_auth/3`).
  defp auth_for(%{auth: auth}) when is_map(auth), do: auth

  defp auth_for(%{access_token: token, canonical_resource: resource}) when is_binary(token),
    do: %{type: "bearer", token: token, canonical_resource: resource}

  defp auth_for(%{access_token: token}) when is_binary(token),
    do: %{type: "bearer", token: token}

  defp auth_for(_), do: %{type: "none"}

  # Transport returns `{:ok, body, meta}` on a successful HTTP 200;
  # the meta carries protocol-level fields like `:session_id`. JSON-RPC
  # success/error/malformed shapes live inside `body`.
  defp unwrap_result({:ok, %{"result" => result}, _meta}), do: {:ok, result}
  defp unwrap_result({:ok, %{"error" => err}, _meta}),     do: {:error, {:rpc, err}}
  defp unwrap_result({:ok, other, _meta}),                  do: {:error, {:malformed, other}}
  defp unwrap_result({:error, _} = err),                    do: err
end
