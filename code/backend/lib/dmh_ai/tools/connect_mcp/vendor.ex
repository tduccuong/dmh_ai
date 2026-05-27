# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.ConnectMcp.Vendor do
  @moduledoc """
  Connect path for MCP servers DMH-AI does NOT host — vendor-hosted
  MCP (Case B: HubSpot, M365 future, etc.), curated catalog entries
  whose `mcp_url` points outside our box, and ad-hoc URL connects
  the model resolves at runtime.

  Three things distinguish this path from `InProcess.attach/3`:

    * **We don't know the auth shape ahead of time.** We probe the
      server (`initialize` unauthenticated) to classify: open / OAuth-
      gated / API-key / not-MCP. The catalog's `auth_kind` short-
      circuits the probe when admin-curated.

    * **The OAuth dance discovers vendor metadata at runtime** via
      RFC 9728 PRM + RFC 8414 ASM. The token endpoint, scopes, and
      DCR support all come from the vendor's well-known documents.

    * **The tools list is fetched at runtime** via `MCP.tools/list`.
      The vendor's MCP server is the source of truth for what
      functions exist; we don't have a compile-time handler.

  The "already authorized + attach quick" sub-path remains here:
  when the user has a valid (non-expired) MCP credential for this
  alias, we skip discovery and just re-handshake + attach. If the
  credential is expired, `MCPAdapter.Caller` refreshes silently on
  the next call — same refresh-on-use rule as in-process. We do
  NOT initiate a re-OAuth dance just because the bearer is stale.
  """

  alias DmhAi.Auth.{Discovery, OAuth2, Credentials}
  alias DmhAi.MCP.Registry, as: MCPRegistry
  alias DmhAi.MCP.Client, as: MCPClient
  require Logger

  @doc """
  Connect a vendor-hosted MCP server. `url` is required (resolved
  from a catalog slug or passed straight in). `catalog_auth_kind`
  is `"oauth"`, `"api_key"`, `"none"`, or `nil` (probe-decide).

  Returns the same `{:ok, %{status: ...}} | {:error, reason}` shape
  as `InProcess.attach/3`.
  """
  @spec connect(map()) :: {:ok, map()} | {:error, String.t()}
  def connect(%{user_id: user_id, session_id: session_id,
                url: url, alias_: alias_, catalog_auth_kind: catalog_auth_kind}) do
    case already_authorized_and_attach(user_id, session_id, alias_) do
      {:ok, payload} -> {:ok, payload}
      :continue       -> connect_fresh(user_id, session_id, url, alias_, catalog_auth_kind)
    end
  end

  # ── already-authorized: re-handshake + attach ─────────────────────────

  # Authorization is per-user (`authorized_services`). If the user
  # has authorized this alias before AND the credential is still
  # usable for a handshake, we re-handshake to refresh the cached
  # tools list and attach. Expired creds fall through to
  # `:continue` — the call-time refresh path (Caller) will mint a
  # fresh access_token when the model actually calls a tool.
  defp already_authorized_and_attach(user_id, session_id, alias_) do
    with %{canonical_resource: resource} = authz <- MCPRegistry.find_authorized(user_id, alias_),
         cred when is_map(cred) <- Credentials.lookup(user_id, "mcp:" <> resource, ""),
         %{is_expired: false} <- cred,
         {:ok, handshake_ctx} <- build_handshake_ctx(authz, cred),
         {:ok, _info, sid}    <- MCPClient.initialize(handshake_ctx),
         {:ok, tools}          <- MCPClient.list_tools(handshake_ctx, sid) do
      MCPRegistry.set_authorized_tools(user_id, alias_, tools)
      MCPRegistry.attach(session_id, user_id, alias_)
      {:ok, %{status: "connected", alias: alias_, tools: summarize_tools(tools)}}
    else
      _ -> :continue
    end
  end

  defp build_handshake_ctx(authz, %{kind: "oauth2_mcp", payload: %{"access_token" => at}}) do
    {:ok, %{
      server_url:         authz.server_url,
      canonical_resource: authz.canonical_resource,
      access_token:       at
    }}
  end

  defp build_handshake_ctx(authz, %{kind: "api_key_mcp", payload: %{"api_key" => key} = payload}) do
    header = payload["api_key_header"] || "x-api-key"

    {:ok, %{
      server_url:         authz.server_url,
      canonical_resource: authz.canonical_resource,
      auth: %{
        type:               "api_key",
        header:             header,
        key:                key,
        canonical_resource: authz.canonical_resource
      }
    }}
  end

  defp build_handshake_ctx(authz, %{kind: "none_mcp"}) do
    {:ok, %{
      server_url:         authz.server_url,
      canonical_resource: authz.canonical_resource,
      auth:               %{type: "none"}
    }}
  end

  defp build_handshake_ctx(_, _), do: {:error, :unsupported_credential_kind}

  # ── fresh-connection cascade — probe-first ────────────────────────────
  #
  # The runtime classifies the URL via an unauthenticated `initialize`:
  #
  #   * 200 + Mcp-Session-Id  → open MCP. Run `no_auth_connect`.
  #   * 401 + Bearer scheme   → OAuth-gated MCP. Run the OAuth flow
  #     using PRM/ASM discovery (RFC 9728 / RFC 8414). The auth_type
  #     comes straight from the WWW-Authenticate scheme — we never
  #     guess from URL shape.
  #   * 401 + non-Bearer scheme → static API key. Show a single-field
  #     "paste your key" form.
  #   * 401 + ambiguous header → bail honestly; admin curation can fix.
  #   * Anything else (404, 5xx, 200-with-non-MCP-body, transport error)
  #     → URL is not an MCP server. Return an honest {:error, ...} so
  #     the model can tell the user truthfully.
  #
  # When the caller came in via a `slug` from the admin catalog, the
  # catalog row already classified auth_kind once at admin Enable
  # time — we honor it without re-probing.

  defp connect_fresh(user_id, session_id, server_url, alias_, catalog_auth_kind)

  defp connect_fresh(user_id, session_id, server_url, alias_, "none") do
    no_auth_connect(user_id, session_id, alias_, server_url)
  end

  defp connect_fresh(user_id, session_id, server_url, alias_, "oauth") do
    gated_oauth_flow(user_id, session_id, server_url, alias_, nil)
  end

  defp connect_fresh(_user_id, session_id, server_url, alias_, "api_key") do
    api_key_setup_form(session_id, server_url, alias_)
  end

  defp connect_fresh(user_id, session_id, server_url, alias_, _no_catalog) do
    case DmhAi.MCP.Probe.classify(server_url) do
      :open ->
        no_auth_connect(user_id, session_id, alias_, server_url)

      {:gated, %{auth_type: :oauth, prm_hint: prm_hint}} ->
        gated_oauth_flow(user_id, session_id, server_url, alias_, prm_hint)

      {:gated, %{auth_type: :api_key}} ->
        api_key_setup_form(session_id, server_url, alias_)

      {:gated, %{auth_type: :ambiguous}} ->
        {:error,
         "The server at #{server_url} responded with a 401 challenge that didn't identify its auth scheme. The runtime can't pick OAuth vs API-key automatically. Tell the user this URL appears to be an MCP server but uses a non-standard auth scheme; if they have credentials, they may need to provide a different URL or ask their admin to curate this server."}

      :not_mcp ->
        {:error,
         "The URL #{server_url} did not respond as an MCP server (the unauthenticated `initialize` probe failed or returned a non-MCP body). Tell the user truthfully that this URL isn't reachable as an MCP endpoint. Either the URL is wrong, the service doesn't expose MCP, or the server is down. Don't retry the same URL — ask the user for a different URL, search again, or suggest an alternative approach."}
    end
  end

  # OAuth dance: fetch PRM (using the hint URL when the server gave
  # one, otherwise falling back to the RFC 8615 well-known path),
  # then ASM, then DCR/manual client identification, then
  # `init_flow`. Returns honest `{:error, ...}` on any failure rather
  # than falling to a manual setup form — admin catalog curation is
  # the proper home for in-house MCP servers that need BYO-OAuth
  # endpoints.
  defp gated_oauth_flow(user_id, session_id, server_url, alias_, prm_hint_url) do
    with {:ok, prm}    <- fetch_prm_via_hint_or_well_known(server_url, prm_hint_url),
         auth_server    = hd(prm.authorization_servers),
         {:ok, asm}     <- Discovery.fetch_asm(auth_server),
         redirect_uri   = build_redirect_uri(),
         {:ok, client}  <- acquire_or_signal(user_id, asm, redirect_uri, prm.scopes_supported),
         {:ok, init}    <- start_auth(user_id, session_id, alias_, prm, asm, server_url, client, redirect_uri) do
      {:ok, %{
        status:   "needs_auth",
        alias:    alias_,
        auth_url: init.auth_url,
        message:  "Click the link to authorize. The chat resumes automatically once you complete authorization in the browser."
      }}
    else
      :needs_manual ->
        {:error,
         "The server at #{server_url} requires OAuth, but its authorization server does not support Dynamic Client Registration. The runtime can't auto-register a client. For in-house servers like this, ask an admin to add this server to the curated catalog (where OAuth client credentials can be configured once for all users)."}

      {:error, _reason} ->
        {:error,
         "The server at #{server_url} appears to be OAuth-gated, but auto-discovery failed (the Protected Resource Metadata document or the Authorization Server Metadata document was unreachable, missing, or malformed). The auto-OAuth path needs both. Ask the user to verify the URL, or have an admin add this server to the curated catalog."}
    end
  end

  defp fetch_prm_via_hint_or_well_known(server_url, nil),
    do: Discovery.fetch_prm(server_url)

  defp fetch_prm_via_hint_or_well_known(_server_url, hint_url) when is_binary(hint_url) do
    Discovery.fetch_prm_at(hint_url)
  end

  defp acquire_or_signal(user_id, asm, redirect_uri, scopes) do
    case OAuth2.acquire_client_id(asm, user_id, redirect_uri: redirect_uri, scopes: scopes) do
      {:ok, _} = ok       -> ok
      :needs_manual        -> :needs_manual
      {:error, _} = err   -> err
    end
  end

  defp start_auth(user_id, session_id, alias_, prm, asm, server_url, client, redirect_uri) do
    OAuth2.init_flow(%{
      user_id:            user_id,
      session_id:         session_id,
      alias:              alias_,
      canonical_resource: prm.resource,
      server_url:         server_url,
      asm:                asm,
      client_id:          client.client_id,
      client_secret:      client.client_secret,
      redirect_uri:       redirect_uri,
      scopes:             prm.scopes_supported
    })
  end

  # ── api_key form (manual fallback for static-header servers) ──────────

  defp api_key_setup_form(session_id, url, alias_) do
    form = build_setup_form(
      [
        %{
          name:  "api_key",
          label: "API key",
          type:  "password",
          secret: true
        },
        %{
          name:    "auth_header",
          label:   "Auth header",
          type:    "select",
          secret:  false,
          default: "Authorization",
          options: [
            %{value: "Authorization",      label: "Authorization: Bearer …  (most APIs — Slack, GitHub, OpenAI, HuggingFace, …)"},
            %{value: "x-api-key",          label: "x-api-key  (generic)"},
            %{value: "x-consumer-api-key", label: "x-consumer-api-key  (Composio)"}
          ]
        }
      ],
      "Connect",
      %{
        "auth_method" => "api_key",
        "alias"       => alias_,
        "server_url"  => url,
        "session_id"  => session_id
      }
    )

    {:ok, %{
      status:  "needs_setup",
      alias:   alias_,
      form:    form,
      message: "Paste this service's API key and pick which auth header it expects. If you pick the wrong one the server returns 401 and you can retry with another."
    }}
  end

  # ── no auth path ──────────────────────────────────────────────────────

  defp no_auth_connect(user_id, session_id, alias_, url) do
    handshake_ctx = %{
      server_url:         url,
      canonical_resource: url,
      auth:               %{type: "none"}
    }

    with {:ok, _info, sid} <- MCPClient.initialize(handshake_ctx),
         {:ok, tools}        <- MCPClient.list_tools(handshake_ctx, sid) do
      MCPRegistry.authorize(user_id, alias_, url, url, nil)
      MCPRegistry.set_authorized_tools(user_id, alias_, tools)
      MCPRegistry.attach(session_id, user_id, alias_)

      Credentials.save(
        user_id,
        "mcp:" <> url,
        "none_mcp",
        %{
          "alias"              => alias_,
          "canonical_resource" => url,
          "server_url"         => url
        },
        account: "",
        notes:   "Open MCP — no auth"
      )

      {:ok, %{status: "connected", alias: alias_, tools: summarize_tools(tools)}}
    else
      {:error, reason} -> {:error, "no-auth connect failed: #{inspect(reason)}"}
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp build_setup_form(fields, submit_label, setup_payload) do
    token = mint_token()
    ttl_secs = DmhAi.Agent.AgentSettings.request_input_ttl_secs()
    expires_at = System.os_time(:millisecond) + ttl_secs * 1_000

    %{
      "token"         => token,
      "fields"        => Enum.map(fields, &stringify_field/1),
      "submit_label"  => submit_label,
      "expires_at"    => expires_at,
      "submitted"     => false,
      "submitted_at"  => nil,
      "values_meta"   => nil,
      "kind"          => "connect_mcp_setup",
      "setup_payload" => setup_payload
    }
  end

  defp stringify_field(f) do
    base = %{
      "name"   => f.name,
      "label"  => f.label,
      "type"   => f.type,
      "secret" => Map.get(f, :secret, f.type == "password")
    }

    base =
      case Map.get(f, :options) do
        opts when is_list(opts) ->
          Map.put(base, "options", Enum.map(opts, &stringify_option/1))

        _ ->
          base
      end

    case Map.get(f, :default) do
      d when is_binary(d) and d != "" -> Map.put(base, "default", d)
      _                                 -> base
    end
  end

  defp stringify_option(%{value: v, label: l}), do: %{"value" => v, "label" => l}
  defp stringify_option(%{} = m), do: m
  defp stringify_option(s) when is_binary(s), do: %{"value" => s, "label" => s}

  defp mint_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp build_redirect_uri do
    base = DmhAi.Agent.AgentSettings.oauth_redirect_base_url()
    String.trim_trailing(base, "/") <> "/oauth/callback"
  end

  defp summarize_tools(tools) when is_list(tools) do
    Enum.map(tools, fn t ->
      %{
        name:        Map.get(t, "name") || Map.get(t, :name),
        description: Map.get(t, "description") || Map.get(t, :description)
      }
    end)
  end
end
