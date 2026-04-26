# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Auth.OAuth2 do
  @moduledoc """
  OAuth 2.1 authorization-code client, metadata-driven.

  Endpoints, scopes, and registration mechanism come from the
  authorization-server metadata document (`Auth.Discovery.fetch_asm/1`),
  not from a hardcoded provider table. Same code reaches Composio,
  Bitrix24, Slack, or any RFC 8414-compliant authorization server.

  Three flow primitives:

    * `acquire_client_id/3` — establish a client_id (and optional
      client_secret) for the auth server, via Dynamic Client
      Registration (RFC 7591) or by reading manual credentials the
      user provided in an earlier `connect_service` setup form.
    * `init_flow/3` — mint a state token + PKCE verifier, persist a
      `pending_oauth_states` row, return the authorization URL the
      user must visit.
    * `complete_flow/2` — invoked by the OAuth callback handler:
      validates + consumes the state, exchanges the code for tokens,
      and hands the rest of the connection setup back to the caller.

  And one operational primitive:

    * `refresh/2` — refresh tokens for a stored `oauth2_mcp`
      credential, rotating refresh tokens per OAuth 2.1.

  PKCE is mandatory (S256). Resource Indicators (RFC 8707) are emitted
  on every authorization + token request so issued tokens are
  audience-bound to a specific MCP server.
  """

  alias Dmhai.Repo
  alias Dmhai.Auth.Credentials
  import Ecto.Adapters.SQL, only: [query!: 3]

  @http_timeout_ms 10_000

  # ── Client identification (CIMD → DCR → manual) ───────────────────────

  @doc """
  Establish a client_id for `asm`. Lookup order:

    1. Existing manual creds at `target = "oauth_client:<auth-server>"`
       — saved during a previous `needs_setup` form.
    2. Dynamic Client Registration (RFC 7591) against
       `asm.registration_endpoint`. On success, persists the resulting
       client_id (and any secret) at the same target so subsequent
       connections to sibling resources behind the same AS reuse it.
    3. `:needs_manual` — caller renders a `request_input` form for the
       user to paste credentials registered out-of-band.

  CIMD (Client ID Metadata Documents) is reachable from this same
  cascade once the deployment exposes a public CIMD URL — slot it in
  ahead of DCR when that's available.
  """
  @spec acquire_client_id(map(), String.t(), keyword()) ::
          {:ok, %{client_id: String.t(), client_secret: String.t() | nil}}
          | :needs_manual
          | {:error, term()}
  def acquire_client_id(asm, user_id, opts \\ []) when is_map(asm) and is_binary(user_id) do
    target = client_target(asm)

    case Credentials.lookup(user_id, target) do
      %{payload: %{"client_id" => cid} = payload} ->
        {:ok, %{client_id: cid, client_secret: payload["client_secret"]}}

      _ ->
        case asm[:registration_endpoint] do
          nil ->
            :needs_manual

          reg_url when is_binary(reg_url) and reg_url != "" ->
            case dynamic_register(reg_url, opts) do
              {:ok, %{client_id: cid, client_secret: secret}} = resp ->
                Credentials.save(user_id, target, "oauth_client",
                  %{"client_id" => cid, "client_secret" => secret},
                  notes: "DCR-registered for #{asm[:issuer] || "unknown issuer"}"
                )
                resp

              other ->
                other
            end
        end
    end
  end

  defp dynamic_register(reg_url, opts) do
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    scopes       = Keyword.get(opts, :scopes, [])

    body = %{
      "client_name"                => "DMH-AI",
      "redirect_uris"              => [redirect_uri],
      "grant_types"                => ["authorization_code", "refresh_token"],
      "response_types"             => ["code"],
      "token_endpoint_auth_method" => "client_secret_post",
      "scope"                      => Enum.join(scopes, " ")
    }

    case Req.post(reg_url,
           json: body,
           headers: [{"accept", "application/json"}],
           receive_timeout: @http_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status, body: resp_body}} when status in 200..201 ->
        decoded = decode_body(resp_body)

        case decoded do
          %{"client_id" => cid} ->
            {:ok, %{client_id: cid, client_secret: decoded["client_secret"]}}

          _ ->
            {:error, {:malformed_dcr_response, decoded}}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:dcr_failed, status, decode_body(resp_body)}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp client_target(asm) do
    "oauth_client:" <> (asm[:issuer] || asm[:authorization_endpoint])
  end

  # ── init_flow ─────────────────────────────────────────────────────────

  @doc """
  Mint a fresh authorization-code flow against `asm`. Caller passes
  the connection metadata (`alias`, `canonical_resource`, `server_url`)
  and the client identifiers from `acquire_client_id/3`. Returns the
  authorization URL the user must visit and the state token bound to
  the call.

  Required keys in `params`:
    * `:user_id`, `:session_id` — bind the callback to the right place.
    * `:anchor_task_id` — the task that initiated this connect. The
      callback handler attaches the resulting service to this task.
    * `:alias`, `:canonical_resource`, `:server_url` — connection metadata.
    * `:asm` — the full ASM map from `Auth.Discovery.fetch_asm/1`.
    * `:client_id` — from `acquire_client_id/3`.
    * `:redirect_uri` — the BE callback URL.

  Optional:
    * `:client_secret` — emitted on the eventual token request.
    * `:scopes` — list of strings; defaults to `asm.scopes_supported`
      or empty.
    * `:ttl_secs` — pending-state lifetime; defaults to
      `AgentSettings.oauth_state_ttl_secs/0`.
  """
  @spec init_flow(map()) ::
          {:ok, %{auth_url: String.t(), state: String.t(), redirect_uri: String.t()}}
          | {:error, term()}
  def init_flow(params) when is_map(params) do
    user_id        = fetch!(params, :user_id)
    session_id     = fetch!(params, :session_id)
    anchor_task_id = fetch!(params, :anchor_task_id)
    alias_         = fetch!(params, :alias)
    canonical      = fetch!(params, :canonical_resource)
    server_url     = fetch!(params, :server_url)
    asm            = fetch!(params, :asm)
    client_id      = fetch!(params, :client_id)
    redirect_uri   = fetch!(params, :redirect_uri)
    client_secret  = Map.get(params, :client_secret)
    scopes         = Map.get(params, :scopes) || asm[:scopes_supported] || []
    ttl_secs       = Map.get(params, :ttl_secs) || Dmhai.Agent.AgentSettings.oauth_state_ttl_secs()

    state    = mint_token(32)
    verifier = mint_token(64)
    challenge = pkce_s256(verifier)
    now = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO pending_oauth_states
      (state, user_id, session_id, anchor_task_id, alias, canonical_resource,
       server_url, pkce_verifier, client_id, client_secret, asm_json, scopes,
       redirect_uri, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      state, user_id, session_id, anchor_task_id, alias_, canonical, server_url,
      verifier, client_id, client_secret, Jason.encode!(asm), Jason.encode!(scopes),
      redirect_uri, now, now + ttl_secs * 1_000
    ])

    auth_url = build_auth_url(asm, %{
      client_id:     client_id,
      redirect_uri:  redirect_uri,
      code_challenge: challenge,
      state:         state,
      scopes:        scopes,
      resource:      canonical
    })

    {:ok, %{auth_url: auth_url, state: state, redirect_uri: redirect_uri}}
  end

  defp build_auth_url(asm, %{} = qp) do
    base = asm[:authorization_endpoint]

    params = [
      {"response_type",         "code"},
      {"client_id",             qp.client_id},
      {"redirect_uri",          qp.redirect_uri},
      {"code_challenge",        qp.code_challenge},
      {"code_challenge_method", "S256"},
      {"state",                 qp.state},
      {"resource",              qp.resource}
    ]

    params =
      case qp.scopes do
        []    -> params
        scopes -> params ++ [{"scope", Enum.join(scopes, " ")}]
      end

    sep = if String.contains?(base, "?"), do: "&", else: "?"
    base <> sep <> URI.encode_query(params)
  end

  # ── complete_flow ─────────────────────────────────────────────────────

  @doc """
  Finalize an in-flight authorization. Looks up the pending state,
  validates it isn't expired, exchanges the code for tokens, and
  consumes the row. Returns the token response together with the
  connection metadata the caller needs to persist creds and run the
  MCP handshake.

  The caller (the `/oauth/callback/:state` handler) is responsible for
  saving tokens, registering MCP tools, and dispatching the
  auto-resume to the user's agent.
  """
  @spec complete_flow(String.t(), String.t()) ::
          {:ok, %{
            user_id:            String.t(),
            session_id:         String.t(),
            anchor_task_id:     String.t(),
            alias:              String.t(),
            canonical_resource: String.t(),
            server_url:         String.t(),
            asm:                map(),
            tokens:             map()
          }}
          | {:error, :not_found | :expired | term()}
  def complete_flow(state, code) when is_binary(state) and is_binary(code) do
    case fetch_pending(state) do
      {:ok, pending} ->
        if pending.expires_at < System.os_time(:millisecond) do
          delete_pending(state)
          {:error, :expired}
        else
          asm = decode_asm(pending.asm_json)

          case exchange_code(asm, code, pending) do
            {:ok, tokens} ->
              delete_pending(state)

              {:ok, %{
                user_id:            pending.user_id,
                session_id:         pending.session_id,
                anchor_task_id:     pending.anchor_task_id,
                alias:              pending.alias,
                canonical_resource: pending.canonical_resource,
                server_url:         pending.server_url,
                asm:                asm,
                tokens:             tokens
              }}

            {:error, _} = err ->
              err
          end
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  defp exchange_code(asm, code, pending) do
    body = [
      {"grant_type",    "authorization_code"},
      {"code",          code},
      {"redirect_uri",  pending.redirect_uri},
      {"client_id",     pending.client_id},
      {"code_verifier", pending.pkce_verifier},
      {"resource",      pending.canonical_resource}
    ]

    body = if is_binary(pending.client_secret) and pending.client_secret != "" do
      body ++ [{"client_secret", pending.client_secret}]
    else
      body
    end

    case Req.post(asm[:token_endpoint],
           form: body,
           headers: [{"accept", "application/json"}],
           receive_timeout: @http_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        normalize_token_response(decode_body(resp_body))

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:token_exchange_failed, status, decode_body(resp_body)}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp normalize_token_response(%{"access_token" => at} = body) when is_binary(at) do
    expires_at =
      case body["expires_in"] do
        n when is_integer(n) -> System.os_time(:millisecond) + n * 1_000
        _ -> nil
      end

    {:ok, %{
      access_token:  at,
      refresh_token: body["refresh_token"],
      scope:         body["scope"],
      token_type:    body["token_type"] || "Bearer",
      expires_at:    expires_at
    }}
  end

  defp normalize_token_response(other),
    do: {:error, {:malformed_token_response, other}}

  # ── refresh ───────────────────────────────────────────────────────────

  @doc """
  Refresh tokens for an `oauth2_mcp` credential. Reads the cached ASM
  and refresh token from the credential's payload, exchanges, persists
  rotated tokens (RFC 6749 §10.4 + OAuth 2.1 mandatory rotation).

  Returns the refreshed credential record (mirrors `Credentials.lookup/2`).
  Errors propagate upward; callers (typically `MCP.Client` on a 401)
  decide whether to flip the connection status to `needs_auth`.
  """
  @spec refresh(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def refresh(user_id, target) when is_binary(user_id) and is_binary(target) do
    case Credentials.lookup(user_id, target) do
      %{kind: "oauth2_mcp", payload: %{"refresh_token" => rt} = payload} when is_binary(rt) ->
        do_refresh(user_id, target, payload, rt)

      %{kind: "oauth2_mcp"} ->
        {:error, :no_refresh_token}

      _ ->
        {:error, :wrong_kind}
    end
  end

  defp do_refresh(user_id, target, payload, refresh_token) do
    asm = decode_asm(payload["asm_json"])
    client_id     = payload["client_id"]
    client_secret = payload["client_secret"]
    canonical     = payload["canonical_resource"]

    body = [
      {"grant_type",    "refresh_token"},
      {"refresh_token", refresh_token},
      {"client_id",     client_id},
      {"resource",      canonical}
    ]

    body = if is_binary(client_secret) and client_secret != "" do
      body ++ [{"client_secret", client_secret}]
    else
      body
    end

    case Req.post(asm[:token_endpoint],
           form: body,
           headers: [{"accept", "application/json"}],
           receive_timeout: @http_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        case normalize_token_response(decode_body(resp_body)) do
          {:ok, tokens} ->
            new_payload = Map.merge(payload, %{
              "access_token"  => tokens.access_token,
              "refresh_token" => tokens.refresh_token || refresh_token,
              "token_type"    => tokens.token_type,
              "scope"         => tokens.scope || payload["scope"]
            })

            Credentials.save(user_id, target, "oauth2_mcp", new_payload,
              notes: "refreshed",
              expires_at: tokens.expires_at
            )

            {:ok, Credentials.lookup(user_id, target)}

          err ->
            err
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:refresh_failed, status, decode_body(resp_body)}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  # ── private helpers ───────────────────────────────────────────────────

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error   -> raise ArgumentError, "missing key #{inspect(key)}"
    end
  end

  defp mint_token(byte_count) do
    :crypto.strong_rand_bytes(byte_count) |> Base.url_encode64(padding: false)
  end

  defp pkce_s256(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp fetch_pending(state) do
    case query!(Repo, """
         SELECT user_id, session_id, anchor_task_id, alias, canonical_resource,
                server_url, pkce_verifier, client_id, client_secret, asm_json,
                scopes, redirect_uri, created_at, expires_at
         FROM pending_oauth_states WHERE state=?
         """, [state]) do
      %{rows: [[uid, sid, atid, al, cres, surl, pv, cid, csec, asm_j, sc, ruri, cat, eat]]} ->
        {:ok, %{
          user_id:            uid,
          session_id:         sid,
          anchor_task_id:     atid,
          alias:              al,
          canonical_resource: cres,
          server_url:         surl,
          pkce_verifier:      pv,
          client_id:          cid,
          client_secret:      csec,
          asm_json:           asm_j,
          scopes:             sc,
          redirect_uri:       ruri,
          created_at:         cat,
          expires_at:         eat
        }}

      _ ->
        :not_found
    end
  end

  defp delete_pending(state) do
    query!(Repo, "DELETE FROM pending_oauth_states WHERE state=?", [state])
    :ok
  end

  defp decode_asm(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} -> Map.new(m, fn {k, v} -> {String.to_atom(k), v} end)
      _        -> %{}
    end
  end

  defp decode_asm(_), do: %{}

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} -> m
      _        -> %{"_raw" => body}
    end
  end

  defp decode_body(_), do: %{}
end
