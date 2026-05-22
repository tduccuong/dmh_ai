# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.OAuthCallback do
  @moduledoc """
  OAuth callback state machine — receives the provider's redirect at
  `GET /oauth/callback`, exchanges the auth code for tokens via
  `Auth.OAuth2.complete_flow/2`, then routes to one of three
  finalize paths based on the pending state's `flow_kind`:

    * `"oauth_service"`  — generic OAuth-protected REST API, stored at
      `oauth:<slug>` with `kind: oauth2_service`. The model picks the
      token up via `lookup_creds` and uses it in `run_script` curl.
    * `"connector_oauth"` — Layer-0.3 click-driven connector OAuth.
      Writes the three rows the connector runtime needs: `oauth:<slug>`
      pre-check + `mcp:<canonical>` MCP bearer + `authorized_services`
      row. Identity capture goes through the connector module's
      `OAuthIdentity.fetch_userinfo/1` callback.
    * fallback — legacy MCP-direct OAuth, stored at `mcp:<canonical>`,
      runs the MCP handshake + tools/list, registers tools on the
      task.

  All three paths append a synthetic `service_connected` user-role
  message to the session so the model's next chain sees the new
  capability, and dispatch `auto_resume_assistant` so an in-flight
  chain picks up immediately. The response is an HTML page rendered
  in the user's browser (this endpoint is reached by the OAuth
  provider redirecting the browser, not by an XHR from the SPA); the
  page posts on a `dmh-ai-oauth` BroadcastChannel so the original
  chat tab can react + closes itself.
  """

  import Plug.Conn
  import Ecto.Adapters.SQL, only: [query!: 3]

  alias DmhAi.Repo

  require Logger

  # GET /oauth/callback?code=…&state=…
  #
  # Unauthenticated — invoked by the user's browser after they
  # authorize at the provider. The state token (single-use, TTL-
  # bounded; minted in `Auth.OAuth2.init_flow/1`) ties the request
  # back to a specific user_id + session_id + connection alias.
  def callback(conn) do
    conn  = fetch_query_params(conn)
    code  = conn.query_params["code"]  || ""
    state = conn.query_params["state"] || ""
    err   = conn.query_params["error"] || conn.query_params["error_description"]

    cond do
      err && err != "" ->
        oauth_html_response(conn, 400, "Authorization server returned an error: #{err}")

      code == "" or state == "" ->
        oauth_html_response(conn, 400, "Missing `code` or `state` query param.")

      true ->
        do_callback(conn, state, code)
    end
  end

  # ─── private ────────────────────────────────────────────────────────

  defp do_callback(conn, state, code) do
    DmhAi.SysLog.log("[OAUTH] callback hit state=#{shorten(state)} code=#{shorten(code)}")
    Logger.info("[OAuth.callback] state=#{shorten(state)} code=#{shorten(code)}")

    case DmhAi.Auth.OAuth2.complete_flow(state, code) do
      {:ok, %{
        user_id:            user_id,
        session_id:         session_id,
        anchor_task_id:     anchor_task_id,
        alias:              alias_,
        canonical_resource: resource,
        server_url:         server_url,
        asm:                asm,
        tokens:             tokens,
        flow_kind:          flow_kind
      }} ->
        DmhAi.SysLog.log("[OAUTH] callback exchange OK flow_kind=#{flow_kind} alias=#{alias_} user=#{user_id} session=#{session_id}")

        case flow_kind do
          "oauth_service" ->
            finalize_oauth_service(user_id, session_id, alias_, resource, server_url, asm, tokens)

          "connector_oauth" ->
            finalize_connector_oauth(user_id, alias_, resource, server_url, asm, tokens)

          _ ->
            finalize_connection(user_id, session_id, anchor_task_id, alias_, resource, server_url, asm, tokens)
        end

        case flow_kind do
          "connector_oauth" -> connector_oauth_success_response(conn, alias_)
          _ -> oauth_html_response(conn, 200, "✓ Authorized — return to your chat.", alias_)
        end

      {:error, :not_found} ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=not_found (state row gone)")
        oauth_html_response(conn, 404, "Unknown or already-used state. Start the authorization again from chat.")

      {:error, :expired} ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=expired (state TTL elapsed)")
        oauth_html_response(conn, 410, "The authorization request expired. Start again from chat.")

      {:error, reason} when is_binary(reason) ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=#{reason}")
        oauth_html_response(conn, 500, "Authorization failed: #{reason}")

      {:error, reason} ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=#{inspect(reason)}")
        oauth_html_response(conn, 500, "Authorization failed: #{inspect(reason)}")
    end
  end

  defp shorten(s) when is_binary(s) and byte_size(s) > 12, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: s

  # ─── finalize: legacy MCP-direct OAuth ──────────────────────────────

  defp finalize_connection(user_id, session_id, anchor_task_id, alias_, resource, server_url, asm, tokens) do
    cred_payload = %{
      "access_token"        => tokens.access_token,
      "refresh_token"       => tokens.refresh_token,
      "scope"               => tokens.scope,
      "token_type"          => tokens.token_type,
      "server_url"          => server_url,
      "alias"               => alias_,
      "canonical_resource"  => resource,
      "asm_json"            => Jason.encode!(asm),
      "client_id"           => nil,
      "client_secret"       => nil
    }

    # Pull client identifiers from the AS-scoped row and fold them
    # into the token credential's payload so the refresh hook has
    # everything it needs without an extra DB hit per refresh.
    client_target =
      "oauth_client:" <> (asm[:issuer] || asm[:authorization_endpoint] || "")

    cred_payload =
      case DmhAi.Auth.Credentials.lookup(user_id, client_target, "") do
        %{payload: %{"client_id" => cid} = cp} ->
          Map.merge(cred_payload, %{
            "client_id"     => cid,
            "client_secret" => cp["client_secret"]
          })

        _ ->
          cred_payload
      end

    DmhAi.Auth.Credentials.save(
      user_id,
      "mcp:" <> resource,
      "oauth2_mcp",
      cred_payload,
      account:    "",
      notes:      "MCP connection: #{alias_}",
      expires_at: tokens.expires_at
    )

    handshake_ctx = %{
      server_url:         server_url,
      canonical_resource: resource,
      access_token:       tokens.access_token
    }

    tools =
      with {:ok, _server_info, sid} <- DmhAi.MCP.Client.initialize(handshake_ctx),
           {:ok, tools}              <- DmhAi.MCP.Client.list_tools(handshake_ctx, sid) do
        tools
      else
        _ -> []
      end

    DmhAi.MCP.Registry.authorize(user_id, alias_, resource, server_url, asm)
    DmhAi.MCP.Registry.set_authorized_tools(user_id, alias_, tools)
    DmhAi.MCP.Registry.attach(anchor_task_id, user_id, alias_)

    append_service_connected_message(session_id, user_id, alias_, length(tools))

    case DmhAi.Agent.Supervisor.ensure_started(user_id) do
      {:ok, pid} -> send(pid, {:auto_resume_assistant, session_id})
      _          -> :ok
    end
  end

  # ─── finalize: generic OAuth-protected REST API ─────────────────────

  # Finalizer for generic-service OAuth (flow_kind = "oauth_service").
  # Same callback URL as MCP, different shape after token exchange:
  # store at `oauth:<slug>`, kind oauth2_service, no MCP Registry
  # attach. The model picks tokens up via lookup_creds and uses them
  # in run_script + curl. The slug is OUR stable identifier; the
  # vendor's `host_match` rides along in the payload for refresh-
  # endpoint resolution but is no longer part of the credential's
  # primary key. Per-slug rows isolate scope sets and re-auth
  # lifecycles when several connectors share a vendor host.
  defp finalize_oauth_service(user_id, session_id, alias_, host_match, server_url, asm, tokens) do
    catalog_row = DmhAi.OAuth.Catalog.get_by_host(host_match)

    {client_id, client_secret, extra_token_params} =
      case catalog_row do
        %{client_id: cid, client_secret: csec, extra_token_params: etp} ->
          {cid, csec, (if is_map(etp), do: etp, else: %{})}

        _ ->
          DmhAi.SysLog.log("[OAUTH] finalize_oauth_service: catalog miss for host=#{host_match} — refresh will likely fail without client credentials")
          {nil, nil, %{}}
      end

    # Discover the account identifier (typically email/login) so the
    # credential gets stored under (user_id, target, account=<email>).
    # NULL userinfo fields on the catalog row OR a network/parse
    # failure both fall back to account="" — the credential still gets
    # saved (failing the whole OAuth callback because userinfo blew up
    # would be worse UX), it just won't surface a per-account label.
    account =
      case catalog_row && DmhAi.OAuth.Userinfo.fetch(catalog_row, tokens.access_token) do
        {:ok, acc} ->
          DmhAi.SysLog.log("[OAUTH] finalize_oauth_service: userinfo resolved account=#{inspect(acc)}")
          acc

        {:error, reason} ->
          DmhAi.SysLog.log("[OAUTH] finalize_oauth_service: userinfo failed (#{inspect(reason)}) — storing credential with empty account")
          ""

        nil ->
          # No catalog row at all — finalize without an account label.
          ""
      end

    # `auth_target` is the stable handle the model copies from
    # lookup_creds output into authorize_service input when the token
    # is rejected mid-call. The catalog slug is the most stable /
    # shortest identifier.
    auth_target =
      case catalog_row do
        %{slug: slug} when is_binary(slug) and slug != "" -> slug
        _ -> alias_
      end

    cred_payload = %{
      "access_token"       => tokens.access_token,
      "refresh_token"      => tokens.refresh_token,
      "scope"              => tokens.scope,
      "token_type"         => tokens.token_type,
      "server_url"         => server_url,
      "alias"              => alias_,
      "host_match"         => host_match,
      "account"            => account,
      "auth_target"        => auth_target,
      "asm_json"           => Jason.encode!(asm),
      "extra_token_params" => extra_token_params,
      "client_id"          => client_id,
      "client_secret"      => client_secret
    }

    DmhAi.Auth.Credentials.save(
      user_id,
      "oauth:" <> alias_,
      "oauth2_service",
      cred_payload,
      account:    account,
      notes:      "OAuth connection: #{alias_}#{if account != "", do: " (#{account})", else: ""}",
      expires_at: tokens.expires_at
    )

    DmhAi.SysLog.log("[OAUTH] finalize_oauth_service: stored cred user=#{user_id} target=oauth:#{alias_} account=#{inspect(account)} expires_at=#{inspect(tokens.expires_at)}")

    append_oauth_service_connected_message(session_id, user_id, alias_, host_match)

    case DmhAi.Agent.Supervisor.ensure_started(user_id) do
      {:ok, pid} ->
        send(pid, {:auto_resume_assistant, session_id})
        DmhAi.SysLog.log("[OAUTH] auto_resume dispatched session=#{session_id}")

      _ ->
        :ok
    end
  end

  # ─── finalize: Layer-0.3 connector OAuth ────────────────────────────

  # Click-driven connector OAuth — writes the three rows the connector
  # runtime needs to invoke a function on behalf of the user. Called
  # from the OAuth callback when the state row's flow_kind ==
  # "connector_oauth".
  #
  # `alias_` is the connector slug; `canonical_resource` and
  # `server_url` both equal the in-process MCPServer URL for that
  # slug (e.g. `http://127.0.0.1:8087/google_workspace`).
  defp finalize_connector_oauth(user_id, alias_, canonical_resource, server_url, asm, tokens) do
    catalog_row = DmhAi.OAuth.Catalog.get_by_slug(alias_)

    {client_id, client_secret, extra_token_params, host_match} =
      case catalog_row do
        %{client_id: cid, client_secret: csec, extra_token_params: etp, host_match: hm} ->
          {cid, csec, (if is_map(etp), do: etp, else: %{}), hm}

        _ ->
          DmhAi.SysLog.log("[OAUTH] finalize_connector_oauth: catalog miss for slug=#{alias_}")
          {nil, nil, %{}, ""}
      end

    # Each Layer-0.3 connector module owns its own identity capture
    # via the `OAuthIdentity.fetch_userinfo/1` callback — current
    # best endpoint, vendor-specific auth model (token-in-Bearer for
    # OIDC providers, token-in-path for HubSpot, etc.), custom
    # response parsing. Connectors that don't implement the callback
    # (Stripe, anonymous MCP) leave `account = ""`.
    account =
      case DmhAi.Connectors.Registry.module_for_slug(alias_) do
        nil ->
          ""

        mod ->
          if DmhAi.Connectors.OAuthIdentity.implements?(mod) do
            case mod.fetch_userinfo(tokens.access_token) do
              {:ok, %{email: e}} when is_binary(e) and e != "" ->
                e

              {:error, reason} ->
                DmhAi.SysLog.log(
                  "[OAUTH] finalize_connector_oauth: " <>
                    "#{alias_}.fetch_userinfo failed: #{inspect(reason)}"
                )
                ""

              _ ->
                ""
            end
          else
            ""
          end
      end

    # Per RFC 6749 §5.1 the `scope` response parameter is optional —
    # when the IdP grants exactly what was requested it MAY omit it.
    # HubSpot does. Fall back to the install URL's scope list so
    # Layer-1 enforcement sees a non-empty granted set.
    granted_scope = tokens.scope || Enum.join(asm[:scopes_supported] || [], " ")

    common_payload = %{
      "access_token"       => tokens.access_token,
      "refresh_token"      => tokens.refresh_token,
      "scope"              => granted_scope,
      "token_type"         => tokens.token_type,
      "server_url"         => server_url,
      "alias"              => alias_,
      "host_match"         => host_match,
      "account"            => account,
      "auth_target"        => alias_,
      "asm_json"           => Jason.encode!(asm),
      "extra_token_params" => extra_token_params,
      "client_id"          => client_id,
      "client_secret"      => client_secret
    }

    # 1) `oauth:<slug>` — Caller.lookup_credentials/3 pre-check.
    DmhAi.Auth.Credentials.save(
      user_id,
      "oauth:" <> alias_,
      "oauth2",
      common_payload,
      account:    account,
      notes:      "Connector OAuth: #{alias_}#{if account != "", do: " (#{account})", else: ""}",
      expires_at: tokens.expires_at
    )

    # 2) `mcp:<canonical>` — bearer token MCP.Client.call_tool/4 sends
    #    to the in-process MCPServer (which forwards to the vendor REST
    #    API).
    DmhAi.Auth.Credentials.save(
      user_id,
      "mcp:" <> canonical_resource,
      "oauth2_mcp",
      common_payload,
      account:    account,
      notes:      "Connector MCP bearer: #{alias_}",
      expires_at: tokens.expires_at
    )

    # 3) authorized_services row — ties (user_id, alias=slug) to the
    #    MCPServer URL. MCP.Client.load_connection reads this.
    DmhAi.MCP.Registry.authorize(user_id, alias_, canonical_resource, server_url, asm)

    DmhAi.SysLog.log(
      "[OAUTH] finalize_connector_oauth: wired slug=#{alias_} user=#{user_id} account=#{inspect(account)}"
    )

    :ok
  end

  # ─── service-connected user-role messages ───────────────────────────

  defp append_oauth_service_connected_message(session_id, user_id, alias_, host_match) do
    cred_target = "oauth:" <> alias_

    # The content tells the model EXACTLY where its access_token lives.
    # The credential target is the slug (`oauth:<alias>`); `host_match`
    # rides along in the saved payload but isn't part of the
    # credential's primary key. Naming the cred_target here saves a
    # wasted round-trip when the model goes to read the token for the
    # first time.
    content =
      "[#{alias_} authorized] Access token is now stored at " <>
      "`#{cred_target}`. Call `lookup_creds(target: \"#{cred_target}\")` " <>
      "to read it, then use it as `Authorization: Bearer <access_token>` " <>
      "in your `run_script` curl."

    case query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                [session_id, user_id]) do
      %{rows: [[msgs_json]]} ->
        msgs = Jason.decode!(msgs_json || "[]")

        msg = %{
          "role"    => "user",
          "content" => content,
          "ts"      => System.os_time(:millisecond),
          "kind"    => "service_connected",
          "service_connected" => %{
            "alias"       => alias_,
            "host_match"  => host_match,
            "cred_target" => cred_target
          }
        }

        new_msgs = msgs ++ [msg]
        now = System.os_time(:millisecond)

        query!(Repo,
          "UPDATE sessions SET messages=?, updated_at=? WHERE id=? AND user_id=?",
          [Jason.encode!(new_msgs), now, session_id, user_id])

      _ -> :ok
    end
  end

  defp append_service_connected_message(session_id, user_id, alias_, tools_count) do
    case query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                [session_id, user_id]) do
      %{rows: [[msgs_json]]} ->
        msgs = Jason.decode!(msgs_json || "[]")

        msg = %{
          "role"              => "user",
          "content"           => "[#{alias_} connected — #{tools_count} tools available]",
          "ts"                => System.os_time(:millisecond),
          "kind"              => "service_connected",
          "service_connected" => %{"alias" => alias_, "tools_count" => tools_count}
        }

        new_msgs = msgs ++ [msg]

        query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
               [Jason.encode!(new_msgs), session_id, user_id])
        :ok

      _ ->
        :ok
    end
  end

  # ─── HTML responses + browser-side postback ─────────────────────────

  # Used for non-success outcomes (errors, expired state, etc.) AND
  # the legacy `oauth_service` success message. Always carries a
  # "Return to DMH-AI" button AND a BroadcastChannel `oauth_result`
  # post so the chat tab (parent of the new-tab OAuth flow) can react.
  # The page tries `window.close()` for the common case where the
  # OAuth opened in a `window.open`-spawned tab; the button is the
  # manual fallback if `window.close()` is denied.
  defp oauth_html_response(conn, status, body_text, slug \\ nil) do
    success? = status in 200..299
    head_colour = if success?, do: "#60c080", else: "#e6a060"
    payload_status = if success?, do: "connected", else: "error"

    html = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>OAuth</title>
    <style>
      body{font-family:system-ui,sans-serif;background:#0a0810;color:#e8d8f0;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;text-align:center;padding:24px;}
      .box{padding:32px 40px;background:#1a1428;border:1px solid #2c2238;border-radius:8px;max-width:480px;}
      h1{margin:0 0 14px;font-size:18px;color:#{head_colour};}
      p{margin:0 0 24px;font-size:13px;color:#b098b8;line-height:1.5;}
      a.btn{display:inline-block;padding:11px 26px;background:#5a4099;color:#fff;text-decoration:none;border-radius:6px;font-size:14px;font-weight:600;}
      a.btn:hover{background:#6a4fb0;}
    </style></head>
    <body><div class="box">
      <h1>#{Plug.HTML.html_escape_to_iodata(body_text)}</h1>
      <p>#{if success?, do: "You can return to DMH-AI now.", else: "Click below to return to DMH-AI and try again."}</p>
      <a class="btn" href="/">Return to DMH-AI</a>
    </div>
    #{oauth_postback_script(payload_status, slug, body_text)}
    </body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  # Embedded JS that runs on every OAuth-callback HTML page. Posts the
  # outcome on a same-origin BroadcastChannel ("dmh-ai-oauth") so the
  # original chat tab (which opened this OAuth tab via `window.open`)
  # can show a toast + refresh My Services. Then attempts
  # `window.close()` so the new tab dismisses itself — `try/catch`
  # because some browsers refuse to close non-script-opened windows,
  # and the visible button is the fallback for those cases.
  defp oauth_postback_script(status, slug, message) do
    payload =
      %{
        "type"    => "oauth_result",
        "status"  => status,
        "slug"    => slug,
        "message" => message
      }
      |> Jason.encode!()

    """
    <script>
    (function() {
      try {
        if ('BroadcastChannel' in window) {
          var bc = new BroadcastChannel('dmh-ai-oauth');
          bc.postMessage(#{payload});
          setTimeout(function() { try { window.close(); } catch (e) {} }, 250);
        } else {
          try { window.close(); } catch (e) {}
        }
      } catch (e) {}
    })();
    </script>
    """
  end

  # Success page for the click-driven `connector_oauth` flow that
  # started from the My Services FE. Shows the result, then waits for
  # the user to tap Continue — no auto-redirect, no flash of a button
  # that disappears under them. The page is the same on every
  # platform; on iOS PWA the OAuth happened in Safari, so the user
  # taps Continue here and then taps their home-screen icon to reopen
  # the PWA (visibilitychange in the FE then pops the connected-toast).
  defp connector_oauth_success_response(conn, slug) do
    return_url = "/?services=connected&slug=#{URI.encode_www_form(slug)}"
    safe_slug  = Plug.HTML.html_escape_to_iodata(slug)

    html = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Connected</title>
    <style>
      body{font-family:system-ui,sans-serif;background:#0a0810;color:#e8d8f0;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;text-align:center;padding:24px;}
      .box{padding:32px 40px;background:#1a1428;border:1px solid #2c2238;border-radius:8px;max-width:480px;}
      h1{margin:0 0 12px;font-size:18px;color:#60c080;}
      p{margin:0 0 24px;font-size:13px;color:#b098b8;line-height:1.5;}
      a.btn{display:inline-block;padding:11px 26px;background:#5a4099;color:#fff;text-decoration:none;border-radius:6px;font-size:14px;font-weight:600;}
      a.btn:hover{background:#6a4fb0;}
      .note{margin-top:16px;font-size:11px;color:#7d6f88;line-height:1.4;}
    </style></head>
    <body><div class="box">
      <h1>✓ #{safe_slug} connected</h1>
      <p>You can now use #{safe_slug} from DMH-AI chat.</p>
      <a class="btn" href="#{return_url}">Continue to DMH-AI</a>
      <div class="note">On iOS, if you started in the DMH-AI home-screen app, tap your home-screen icon instead — Safari can't switch you back automatically.</div>
    </div>
    #{oauth_postback_script("connected", slug, "Connected to " <> slug)}
    </body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
