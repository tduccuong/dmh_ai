# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ConnectMcp do
  @moduledoc """
  Single user-facing tool for attaching an MCP server to the current
  task. MCP-only: the discovery cascade (PRM → ASM), client
  identification (DCR or reusing manual creds saved earlier), and
  OAuth 2.1 init are all parts of the MCP-2025-06-18 spec. Non-MCP
  external integrations (regular REST APIs, webhooks, raw OAuth-
  protected endpoints) live outside this tool — the model uses
  `run_script` + `lookup_creds`/`save_creds` for those instead.

  Authorization is per-user (persists across sessions and tasks); the
  resulting tool catalog is per-task (visible only while the
  originating task is active). The OAuth callback handler and the
  form-submission async finalizer both attach the service to the
  task that initiated the call.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Auth.{Discovery, OAuth2, Credentials}
  alias Dmhai.MCP.Registry, as: MCPRegistry
  alias Dmhai.MCP.Client, as: MCPClient

  @impl true
  def name, do: "connect_mcp"

  @impl true
  def description do
    """
    Attach an MCP server (JSON-RPC `initialize`/`tools/list`/`tools/call`) to the current task.

    `auth_method` (default `"auto"`): `"auto"` (OAuth 2.1 + RFC 9728/8414 discovery), `"api_key"` (returns needs_setup form), `"oauth"` (manual, returns needs_setup form), `"none"` (no auth).

    Returns: `{status: "connected", alias, tools}` | `{status: "needs_auth", alias, auth_url}` | `{status: "needs_setup", alias, form}`. Last two are chain-terminating.

    Tools detach on `complete_task`/`cancel_task`; a new task re-calls `connect_mcp` (re-attach is fast).
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "MCP server URL or service base URL."
          },
          alias: %{
            type: "string",
            description: "Optional friendly label for this connection. Defaults to a slug derived from the URL."
          },
          auth_method: %{
            type: "string",
            enum: ["auto", "api_key", "oauth", "none"],
            description: "How the server authenticates clients. Defaults to 'auto'."
          }
        },
        required: ["url"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id     = Map.get(ctx, :user_id)
    session_id  = Map.get(ctx, :session_id)
    anchor_n    = Map.get(ctx, :anchor_task_num)
    url         = Map.get(args, "url")
    alias_in    = Map.get(args, "alias")
    auth_method = Map.get(args, "auth_method") || "auto"

    with :ok                      <- require_ctx(user_id, session_id),
         :ok                      <- validate_url(url),
         :ok                      <- validate_auth_method(auth_method),
         {:ok, anchor_task_id}    <- resolve_anchor(session_id, anchor_n) do
      alias_ = alias_or_default(alias_in, url)

      case already_authorized_and_attach(user_id, anchor_task_id, alias_) do
        {:ok, payload} ->
          {:ok, payload}

        :continue ->
          case auth_method do
            "auto"    -> connect_fresh(user_id, session_id, anchor_task_id, url, alias_)
            "api_key" -> api_key_setup_form(anchor_task_id, url, alias_)
            "oauth"   -> oauth_manual_setup_form(anchor_task_id, url, alias_)
            "none"    -> no_auth_connect(user_id, anchor_task_id, alias_, url)
          end
      end
    end
  end

  defp validate_auth_method(m) when m in ["auto", "api_key", "oauth", "none"], do: :ok
  defp validate_auth_method(other), do: {:error, "invalid auth_method: #{inspect(other)} (use auto | api_key | oauth | none)"}

  defp resolve_anchor(session_id, n) when is_binary(session_id) and is_integer(n) do
    case Dmhai.Agent.Tasks.resolve_num(session_id, n) do
      {:ok, task_id}        -> {:ok, task_id}
      {:error, :not_found}  -> {:error, "anchor task (#{n}) not found in this session"}
    end
  end

  defp resolve_anchor(_, _),
    do: {:error, "connect_mcp requires an anchor task — call create_task or pickup_task first"}

  # ── already-authorized: re-handshake + attach ─────────────────────────

  # Authorization is at the user tier; if the user has authorized this
  # alias before AND credentials are still valid, we just rehandshake
  # to refresh the cached tool list and attach to the current task.
  # Empty / failing path: fall through to `:continue` so the caller
  # runs the appropriate fresh flow.
  defp already_authorized_and_attach(user_id, anchor_task_id, alias_) do
    with %{canonical_resource: resource} = authz <- MCPRegistry.find_authorized(user_id, alias_),
         cred when is_map(cred) <- Credentials.lookup(user_id, "mcp:" <> resource),
         %{is_expired: false} <- cred,
         {:ok, handshake_ctx} <- build_handshake_ctx(authz, cred),
         {:ok, _info, sid}    <- MCPClient.initialize(handshake_ctx),
         {:ok, tools}          <- MCPClient.list_tools(handshake_ctx, sid) do
      MCPRegistry.set_authorized_tools(user_id, alias_, tools)
      MCPRegistry.attach(anchor_task_id, user_id, alias_)
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
  # We don't know up front what kind of server lives at this URL: an
  # open MCP, a gated OAuth-protected MCP, an MCP that needs an API
  # key, or — sometimes — a non-MCP URL the user pasted by mistake.
  # The cascade decides by ASKING the URL via an unauthenticated
  # `initialize`:
  #
  #   * 200 + Mcp-Session-Id  → open MCP. Run `no_auth_connect`.
  #   * 401                   → gated MCP. Inspect `WWW-Authenticate`
  #     for the RFC 9728 §5.1 `resource_metadata=<PRM URL>` hint; that
  #     URL takes us straight to the right PRM doc without guessing
  #     the well-known location. Without the hint, fall back to the
  #     RFC 8615 well-known construction.
  #   * Anything else (404, 5xx, 200-with-non-MCP-body, transport error)
  #     → this URL is not an MCP server. Fall to the api_key form,
  #     where the message tells the model: if this is a regular REST
  #     API or webhook, abandon `connect_mcp` and call it directly
  #     with `run_script` + curl.
  #
  # The OAuth-2 dance only fires when the server explicitly tells us
  # it's OAuth-protected — we don't ASSUME OAuth from URL shape.

  defp connect_fresh(user_id, session_id, anchor_task_id, server_url, alias_) do
    case probe_mcp(server_url) do
      :open ->
        no_auth_connect(user_id, anchor_task_id, alias_, server_url)

      {:gated, prm_hint_url} ->
        gated_oauth_flow(user_id, session_id, anchor_task_id, server_url, alias_, prm_hint_url)

      :not_mcp ->
        api_key_setup_form(anchor_task_id, server_url, alias_)
    end
  end

  # Probe with an unauthed `initialize` and classify the response:
  #   :open                  — 200 + valid MCP result.
  #   {:gated, prm_url|nil}  — 401; PRM URL pulled from
  #                            `WWW-Authenticate: resource_metadata=`
  #                            when present, else nil (caller falls
  #                            back to RFC 8615 well-known).
  #   :not_mcp               — anything else; URL is not an MCP server.
  defp probe_mcp(server_url) do
    handshake_ctx = %{
      server_url:         server_url,
      canonical_resource: server_url,
      auth:               %{type: "none"}
    }

    case MCPClient.initialize(handshake_ctx) do
      {:ok, _info, sid} when is_binary(sid) and sid != "" ->
        :open

      {:error, {:rpc, _err}} ->
        # Server understood our JSON-RPC but errored — still MCP,
        # treat as gated and let the OAuth path try.
        {:gated, nil}

      {:error, {:status, 401, _body, headers}} ->
        {:gated, parse_resource_metadata_hint(headers)}

      _ ->
        :not_mcp
    end
  end

  # Pull the `resource_metadata=<URL>` parameter out of a
  # `WWW-Authenticate` header per RFC 9728 §5.1. Tolerates quoted
  # and unquoted forms, multiple challenge schemes, and extra
  # whitespace. Returns nil when missing.
  defp parse_resource_metadata_hint(headers) when is_list(headers) do
    case Enum.find(headers, fn {k, _} -> k == "www-authenticate" end) do
      nil -> nil
      {_, value} when is_binary(value) -> extract_resource_metadata(value)
      _ -> nil
    end
  end
  defp parse_resource_metadata_hint(_), do: nil

  defp extract_resource_metadata(value) do
    case Regex.run(~r/resource_metadata\s*=\s*"?([^",\s]+)"?/i, value) do
      [_, url] -> url
      _        -> nil
    end
  end

  # OAuth dance: fetch PRM (using the hint URL when the server gave
  # one, otherwise falling back to the RFC 8615 well-known path),
  # then ASM, then DCR/CIMD/manual client identification, then
  # `init_flow`. Falls through to the api_key form on any expected
  # failure (PRM not found, ASM missing, no DCR, etc.).
  defp gated_oauth_flow(user_id, session_id, anchor_task_id, server_url, alias_, prm_hint_url) do
    with {:ok, prm}    <- fetch_prm_via_hint_or_well_known(server_url, prm_hint_url),
         auth_server    = hd(prm.authorization_servers),
         {:ok, asm}     <- Discovery.fetch_asm(auth_server),
         redirect_uri   = build_redirect_uri(),
         {:ok, client}  <- acquire_or_signal(user_id, asm, redirect_uri, prm.scopes_supported),
         {:ok, init}    <- start_auth(user_id, session_id, anchor_task_id, alias_, prm, asm, server_url, client, redirect_uri) do
      {:ok, %{
        status:   "needs_auth",
        alias:    alias_,
        auth_url: init.auth_url,
        message:  "Click the link to authorize. The chat resumes automatically once you complete authorization in the browser."
      }}
    else
      :needs_manual ->
        api_key_setup_form(anchor_task_id, server_url, alias_)

      # PRM unreachable / malformed / 404; ASM missing or non-spec.
      # The server gated on us but doesn't publish enough metadata
      # for the auto-OAuth path. Drop to the api_key form so the
      # user can paste a key (or the model can re-call with
      # `auth_method: "oauth"` for a manual OAuth dance).
      {:error, _reason} ->
        api_key_setup_form(anchor_task_id, server_url, alias_)
    end
  end

  defp fetch_prm_via_hint_or_well_known(server_url, nil),
    do: Discovery.fetch_prm(server_url)

  defp fetch_prm_via_hint_or_well_known(_server_url, hint_url) when is_binary(hint_url) do
    # The hint URL is a fully-qualified PRM document URL emitted by
    # the AS. We bypass `rfc8615_well_known/2` and fetch directly.
    Discovery.fetch_prm_at(hint_url)
  end

  defp acquire_or_signal(user_id, asm, redirect_uri, scopes) do
    case OAuth2.acquire_client_id(asm, user_id, redirect_uri: redirect_uri, scopes: scopes) do
      {:ok, _} = ok       -> ok
      :needs_manual        -> :needs_manual
      {:error, _} = err   -> err
    end
  end

  defp start_auth(user_id, session_id, anchor_task_id, alias_, prm, asm, server_url, client, redirect_uri) do
    OAuth2.init_flow(%{
      user_id:            user_id,
      session_id:         session_id,
      anchor_task_id:     anchor_task_id,
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

  defp api_key_setup_form(anchor_task_id, url, alias_) do
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
        "auth_method"    => "api_key",
        "alias"          => alias_,
        "server_url"     => url,
        "anchor_task_id" => anchor_task_id
      }
    )

    {:ok, %{
      status:  "needs_setup",
      alias:   alias_,
      form:    form,
      message: "Paste this service's API key and pick which auth header it expects. If you pick the wrong one the server returns 401 and you can retry with another. If this URL isn't an MCP server but a regular REST API or webhook, abandon `connect_mcp` and call the API directly with `run_script` + `curl`."
    }}
  end

  # ── oauth (manual) form (no-discovery OAuth servers) ──────────────────

  defp oauth_manual_setup_form(anchor_task_id, url, alias_) do
    form = build_setup_form(
      [
        %{name: "authorization_endpoint", label: "Authorization URL",         type: "text",     secret: false},
        %{name: "token_endpoint",         label: "Token URL",                  type: "text",     secret: false},
        %{name: "scopes",                  label: "Scopes (space-separated)",   type: "text",     secret: false},
        %{name: "client_id",               label: "Client ID",                  type: "text",     secret: false},
        %{name: "client_secret",           label: "Client Secret",              type: "password", secret: true}
      ],
      "Continue to authorize",
      %{
        "auth_method"        => "oauth",
        "alias"              => alias_,
        "server_url"         => url,
        "canonical_resource" => url,
        "anchor_task_id"     => anchor_task_id
      }
    )

    {:ok, %{
      status:  "needs_setup",
      alias:   alias_,
      form:    form,
      message: "Provide this service's OAuth endpoints and client credentials. After submit, the form is replaced with an authorization link to click."
    }}
  end

  # ── no auth path ──────────────────────────────────────────────────────
  #
  # Single helper used by both:
  #   * `auth_method: "none"` — the model explicitly declares the
  #     server is open.
  #   * `auth_method: "auto"` open auto-detect — Phase D's cascade
  #     fallthrough probes an unauthed `initialize` when PRM 404s
  #     and routes here on success.
  #
  # The credential row at `mcp:<canonical>` is a sentinel of kind
  # `none_mcp`. It carries no secrets but lets `MCP.Client.load_connection`
  # find the canonical resource on subsequent calls and route through
  # the standard pipeline (`build_auth/3`'s `none_mcp` clause yields
  # `%{type: "none"}`). Without it, follow-up `<alias>.<tool>` calls
  # would 404 at credential lookup.

  defp no_auth_connect(user_id, anchor_task_id, alias_, url) do
    handshake_ctx = %{
      server_url:         url,
      canonical_resource: url,
      auth:               %{type: "none"}
    }

    with {:ok, _info, sid} <- MCPClient.initialize(handshake_ctx),
         {:ok, tools}        <- MCPClient.list_tools(handshake_ctx, sid) do
      MCPRegistry.authorize(user_id, alias_, url, url, nil)
      MCPRegistry.set_authorized_tools(user_id, alias_, tools)
      MCPRegistry.attach(anchor_task_id, user_id, alias_)

      Credentials.save(
        user_id,
        "mcp:" <> url,
        "none_mcp",
        %{
          "alias"              => alias_,
          "canonical_resource" => url,
          "server_url"         => url
        },
        notes: "Open MCP — no auth"
      )

      {:ok, %{status: "connected", alias: alias_, tools: summarize_tools(tools)}}
    else
      {:error, reason} -> {:error, "no-auth connect failed: #{inspect(reason)}"}
    end
  end

  # ── form builder ──────────────────────────────────────────────────────

  defp build_setup_form(fields, submit_label, setup_payload) do
    token = mint_token()
    ttl_secs = Dmhai.Agent.AgentSettings.request_input_ttl_secs()
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

  # ── helpers ───────────────────────────────────────────────────────────

  defp require_ctx(nil, _), do: {:error, "connect_mcp called without user_id in context"}
  defp require_ctx(_, nil), do: {:error, "connect_mcp called without session_id in context"}
  defp require_ctx(_, _),    do: :ok

  defp validate_url(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, "url must be an http(s) URL"}
    end
  end

  defp validate_url(_), do: {:error, "url is required"}

  defp alias_or_default(s, _) when is_binary(s) and s != "", do: s

  defp alias_or_default(_, url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path not in ["", "/"] ->
        path
        |> String.trim_leading("/")
        |> String.split("/")
        |> List.last()
        |> slugify()

      %URI{host: host} when is_binary(host) ->
        slugify(host)

      _ ->
        "service"
    end
  end

  defp slugify(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      ""  -> "service"
      out -> out
    end
  end

  defp build_redirect_uri do
    base = Dmhai.Agent.AgentSettings.oauth_redirect_base_url()
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
