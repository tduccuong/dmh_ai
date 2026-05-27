# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Router do
  use Plug.Router
  import Plug.Conn
  alias DmhAi.AuthPlug
  alias DmhAi.Handlers.{AdminIdentities, AdminKbSources, OrgUsers}
  alias DmhAi.Handlers.AdminConnectors
  alias DmhAi.Handlers.MeServices
  alias DmhAi.Handlers.AdminPools
  alias DmhAi.Handlers.Auth
  alias DmhAi.Handlers.Data
  alias DmhAi.Handlers.KbQuery
  alias DmhAi.Handlers.Media
  alias DmhAi.Handlers.Proxy
  alias DmhAi.Handlers.Tools
  alias DmhAi.Handlers.AgentChat
  alias DmhAi.Agent.UserAgent

  plug DmhAi.Plugs.BlockScanners
  plug DmhAi.Plugs.SecurityHeaders
  plug Plug.Static, at: "/", from: "/app/static", gzip: false,
    headers: %{"cache-control" => "no-store"}
  plug DmhAi.Plugs.RateLimit
  plug Plug.Head
  plug :match
  plug :dispatch

  # ─── Public (no-auth, no-rate-limit-bypass) routes ───────────────────────────

  get "/" do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/html")
    |> send_file(200, "/app/static/index.html")
  end

  get "/dmh-ai.crt" do
    conn
    |> put_resp_header("content-disposition", "attachment; filename=\"dmh-ai.crt\"")
    |> put_resp_content_type("application/x-x509-ca-cert")
    |> send_file(200, "/app/ssl/cert.pem")
  end

  # ─── No-auth GET routes ──────────────────────────────────────────────────────

  get "/auth/me" do
    Auth.get_me(conn)
  end

  # GET /detect-lang — IP-geolocation hint for the FE language fallback
  # chain. Returns `{"lang": "vi" | "de" | … | null}`. Best-effort:
  # any failure (private IP, API down, unsupported country) yields
  # `null` and the FE keeps its existing default. Cached server-side
  # (see DmhAi.GeoIP) so external API hits stay rare.
  get "/detect-lang" do
    lang = client_ip(conn) |> DmhAi.GeoIP.lookup_lang()
    body = Jason.encode!(%{lang: lang})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # GET /local-api/* — proxies to the configured `miner` pool's
  # base_url (typically the operator's local Ollama). Authentication
  # required: without it, anyone hitting the BE through the public
  # nginx endpoint can drive the operator's Ollama (model time +
  # bandwidth) without going through chat.
  get "/local-api/*glob" do
    with {:ok, conn, _user} <- check_auth(conn) do
      sub = Enum.join(glob, "/")
      Proxy.get_local_api(conn, sub)
    end
  end

  # GET /api/* — same handler as /local-api/*, same auth requirement.
  get "/api/*glob" do
    with {:ok, conn, _user} <- check_auth(conn) do
      sub = Enum.join(glob, "/")
      Proxy.get_local_api(conn, sub)
    end
  end

  # GET /search — direct SearXNG passthrough. Authenticated to keep
  # the operator's SearXNG from being driven as an open relay (which
  # gets the host IP banned from upstream search engines).
  get "/search" do
    with {:ok, conn, _user} <- check_auth(conn) do
      Proxy.get_search(conn)
    end
  end

  # GET /fetch-page — fetches arbitrary URLs the caller supplies.
  # Authenticated: an unauthenticated caller turns this into an
  # SSRF primitive (cloud metadata, internal LAN, etc).
  get "/fetch-page" do
    with {:ok, conn, _user} <- check_auth(conn) do
      Proxy.get_fetch_page(conn)
    end
  end

  # ─── POST no-auth ─────────────────────────────────────────────────────────────

  post "/auth/login" do
    Auth.post_login(conn)
  end

  post "/auth/logout" do
    Auth.post_logout(conn)
  end

  # POST /local-api/* — streaming proxy to the configured `miner`
  # pool's base_url. Authenticated; same rationale as the GET above.
  post "/local-api/*glob" do
    with {:ok, conn, _user} <- check_auth(conn) do
      sub = Enum.join(glob, "/")
      Proxy.post_local_api(conn, sub)
    end
  end

  # POST /api/show — capability stub for the legacy Ollama probe
  # surface; backend models always support vision + video. No
  # secrets surfaced, but auth-gated for symmetry with the other
  # /api/* routes — there's no scenario where an unauthenticated
  # client legitimately probes capabilities.
  post "/api/show" do
    with {:ok, conn, _user} <- check_auth(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{capabilities: ["vision", "video"]}))
    end
  end

  # POST /api/* — same handler as POST /local-api/*, same auth.
  post "/api/*glob" do
    with {:ok, conn, _user} <- check_auth(conn) do
      sub = Enum.join(glob, "/")
      Proxy.post_local_api(conn, sub)
    end
  end

  # ─── PUT /ai_pools — loopback-only bulk import for fresh-install bootstrap ──
  #
  # Accepts a `pools.json` (same shape as the operator seed file at
  # `/data/pools.json`) and inserts each pool that doesn't already exist
  # by name. Gated to the loopback interface so anyone with shell access
  # to the host can curl-import their LLM-account config without first
  # going through admin login. Remote pool management uses the
  # authenticated `/admin/pools/*` routes.
  #
  # Example:
  #   curl http://127.0.0.1:8080/ai_pools -XPUT \
  #     --data-binary @/path/to/pools.json
  put "/ai_pools" do
    if loopback?(conn) do
      AdminPools.put_ai_pools(conn)
    else
      Proxy.json(conn, 403, %{error: "Forbidden — /ai_pools accepts loopback requests only"})
    end
  end

  # ─── Authenticated GET routes ─────────────────────────────────────────────────

  get "/users" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.get_users(conn, user)
    end
  end

  get "/user/profile" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.get_user_profile(conn, user)
    end
  end

  get "/admin/user-profiles" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.get_admin_user_profiles(conn, user)
    end
  end

  get "/users/prefs" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.get_user_prefs(conn, user)
    end
  end

  get "/user/fact-counts" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.get_user_fact_counts(conn, user)
    end
  end

  get "/admin/settings" do
    with {:ok, conn, user} <- check_auth(conn) do
      Proxy.get_admin_settings(conn, user)
    end
  end

  get "/admin/pools" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.list(conn, user)
    end
  end

  get "/admin/pools/models" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.list_models(conn, user)
    end
  end

  post "/admin/pools" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.create(conn, user)
    end
  end

  post "/admin/pools/probe" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.probe(conn, user)
    end
  end

  put "/admin/pools/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.update(conn, user, id)
    end
  end

  delete "/admin/pools/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.delete(conn, user, id)
    end
  end

  post "/admin/pools/:id/accounts" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.add_account(conn, user, id)
    end
  end

  delete "/admin/pools/:id/accounts/:account_name" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.remove_account(conn, user, id, account_name)
    end
  end

  # ── KB sources (Primitive 0.2) ───────────────────────────────────────
  # Admin-only: list & remove org-scoped KB sources. Underpins the
  # future admin UI's "manage KB" panel. See
  # `DmhAi.Handlers.AdminKbSources` for status.

  get "/admin/kb-sources" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminKbSources.list(conn, user)
    end
  end

  post "/admin/kb-sources/remove" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminKbSources.remove(conn, user)
    end
  end

  # Primitive 0.9 — manual-override surface for connector_identities.
  # Admin maps a DMH-AI user_id to a connector's native external_id
  # when the email-pivot can't (different work email across SaaS,
  # vendor lookup unreliable, etc.).
  post "/admin/identities" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminIdentities.put(conn, user)
    end
  end

  get "/admin/identities" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminIdentities.list(conn, user)
    end
  end

  # Layer W — @-mention picker. Returns up to 10 same-org users
  # matching the prefix. Authenticated; no role gate (every member
  # can see the org directory; that's how Slack-style mentions work).
  get "/org/users" do
    with {:ok, conn, user} <- check_auth(conn) do
      OrgUsers.search(conn, user)
    end
  end

  post "/admin/pools/import" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.import_many(conn, user)
    end
  end

  # ── Connectors (Primitive 0.3) — consolidated admin view + probe ──────

  get "/admin/connectors" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminConnectors.list(conn, user)
    end
  end

  post "/admin/connectors/:slug/test" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminConnectors.test(conn, user, slug)
    end
  end

  post "/admin/connectors/:slug/save" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminConnectors.save(conn, user, slug)
    end
  end

  get "/admin/connectors/:slug/discovery_state" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminConnectors.discovery_state(conn, user, slug)
    end
  end

  post "/admin/connectors/:slug/discover/:layer" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminConnectors.discover(conn, user, slug, layer)
    end
  end

  # ── Workflow viewer (Layer W) ─────────────────────────────────────────
  #
  # The chat reply renders saved workflows as markdown links like
  # `[customer_onboarding · v3](/workflows/customer_onboarding/3)`;
  # the FE intercepts the click and opens a modal that fetches one of
  # the endpoints below. Read-only — saving / arming / running live
  # in the LLM tool surface (`upsert_workflow`, future
  # `arm_workflow` / `workflow.invoke`).

  get "/workflows" do
    with {:ok, conn, user} <- check_auth(conn) do
      DmhAi.Handlers.Workflows.list(conn, user)
    end
  end

  get "/workflows/:slug/:version" do
    with {:ok, conn, user} <- check_auth(conn) do
      DmhAi.Handlers.Workflows.show(conn, user, slug, version)
    end
  end

  # ── Workflow run viewer (Layer W) ─────────────────────────────────────
  # Renders the executor's actual output (status + emits + trigger
  # payload) for one run. The model returns `run_url: "/runs/<id>"`
  # from `invoke_workflow`; the FE intercepts the click and opens a
  # modal that fetches this endpoint.
  get "/runs/:run_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      DmhAi.Handlers.Runs.show(conn, user, run_id)
    end
  end

  # ── Workflow webhook ingress (Layer W) ────────────────────────────────
  # External M2M endpoint. NO auth header (the token IS the auth) —
  # this is the URL the user pastes into the external SaaS's webhook
  # configuration (HubSpot, Stripe, Calendly, etc). Three-layer
  # validation lives in the handler.
  post "/wf/webhook/:workflow_id/:token" do
    DmhAi.Handlers.WfWebhook.receive(conn, workflow_id, token)
  end

  # ── Per-user services view (Primitive 0.3) ────────────────────────────

  get "/me/services" do
    with {:ok, conn, user} <- check_auth(conn) do
      MeServices.list(conn, user)
    end
  end

  post "/me/services/disconnect" do
    with {:ok, conn, user} <- check_auth(conn) do
      MeServices.disconnect(conn, user)
    end
  end

  post "/me/services/connect/:slug" do
    with {:ok, conn, user} <- check_auth(conn) do
      MeServices.connect(conn, user, slug)
    end
  end

  get "/model-labels" do
    with {:ok, conn, user} <- check_auth(conn) do
      Proxy.get_model_labels(conn, user)
    end
  end

  get "/admin/test-endpoint" do
    with {:ok, conn, user} <- check_auth(conn) do
      Proxy.get_test_endpoint(conn, user)
    end
  end

  get "/tools" do
    with {:ok, conn, user} <- check_auth(conn) do
      Tools.get_tools(conn, user)
    end
  end

  get "/cloud-api/*glob" do
    with {:ok, conn, user} <- check_auth(conn) do
      sub = Enum.join(glob, "/")
      Proxy.get_cloud_api(conn, user, sub)
    end
  end

  get "/sessions/current" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_current_session(conn, user)
    end
  end

  get "/sessions" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_sessions(conn, user)
    end
  end

  get "/sessions/:session_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_session(conn, user, session_id)
    end
  end

  get "/sessions/:session_id/token-stats" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_token_stats(conn, user, session_id)
    end
  end

  get "/sessions/:session_id/progress" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_session_progress(conn, user, session_id)
    end
  end

  # Poll endpoint — unified delta fetch for messages, progress rows,
  # streaming-buffer text, and the `is_working` flag. FE hits this at
  # 500 ms when the agent is active, 5 s when idle.
  get "/sessions/:session_id/poll" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.poll_session(conn, user, session_id)
    end
  end

  # POST /sessions/:session_id/inputs/:token — submit an in-chat form
  # rendered by the model's `request_input` tool. Body: {"values": ...}.
  # Single-use token; submission marks the source assistant message
  # `form.submitted = true` and synthesises a user-role message that
  # auto-resumes the chain.
  post "/sessions/:session_id/inputs/:token" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.submit_input(conn, user, session_id, token)
    end
  end

  # GET /oauth/callback?code=…&state=…
  # OAuth callback for `connect_mcp`. Unauthenticated — the state
  # token (single-use, TTL-bounded) ties the request back to a
  # specific user_id + session_id + connection alias. See specs/mcp.md.
  get "/oauth/callback" do
    DmhAi.Handlers.OAuthCallback.callback(conn)
  end

  get "/image-descriptions/:session_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_image_descriptions(conn, user, session_id)
    end
  end

  get "/video-descriptions/:session_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_video_descriptions(conn, user, session_id)
    end
  end

  # `/assets/<session_id>/<rest>` where `<rest>` is the path under
  # `<session_data_dir>` — typically `uploaded/<filename>` (POST
  # /assets writes here) or `published/<filename>` (mk_download_link
  # writes here). Plug.Router's `*` glob captures multi-segment
  # paths into a list of strings; the handler joins them back.
  #
  # Auth accepts EITHER (1) bearer header — used by the FE for
  # programmatic image-preview fetches on uploaded attachments,
  # OR (2) HMAC signature in `?expires=&sig=` — used by `<a>`-click
  # downloads and by recipients of shared `mk_download_link` URLs
  # (no DMH-AI account required). See architecture.md §Execution
  # tools → mk_download_link → Signed URLs.
  get "/assets/:session_id/*rest" do
    rel_path = Path.join(rest)

    case authorize_asset_access(conn, session_id, rel_path) do
      {:ok, owner_email} ->
        Data.get_asset(conn, %{email: owner_email}, session_id, rel_path)

      {:error, conn} ->
        conn
    end
  end

  # ─── Authenticated POST routes ────────────────────────────────────────────────

  post "/users" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.post_create_user(conn, user)
    end
  end

  post "/log" do
    with {:ok, conn, _user} <- check_auth(conn) do
      Data.post_log(conn)
    end
  end

  post "/user/track-facts" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.post_track_facts(conn, user)
    end
  end

  post "/image-descriptions" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.post_image_description(conn, user)
    end
  end

  post "/video-descriptions" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.post_video_description(conn, user)
    end
  end

  get "/video-frame-count" do
    with {:ok, conn, _user} <- check_auth(conn) do
      Media.get_video_frame_count(conn)
    end
  end

  post "/describe-video" do
    with {:ok, conn, user} <- check_auth(conn) do
      Media.post_describe_video(conn, user)
    end
  end

  post "/describe-image" do
    with {:ok, conn, user} <- check_auth(conn) do
      Media.post_describe_image(conn, user)
    end
  end

  post "/upload-session-attachment" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.post_session_attachment(conn, user)
    end
  end

  post "/agent/chat" do
    with {:ok, conn, user} <- check_auth(conn) do
      AgentChat.post_chat(conn, user)
    end
  end

  # KB query (partial Primitive 0.6 — REST API). Org-scoped per the
  # calling user's org_id. See `DmhAi.Handlers.KbQuery` for status.
  post "/kb/query" do
    with {:ok, conn, user} <- check_auth(conn) do
      KbQuery.query(conn, user)
    end
  end

  post "/tools/execute" do
    with {:ok, conn, user} <- check_auth(conn) do
      Tools.post_execute(conn, user)
    end
  end

  post "/sessions/:session_id/name" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.post_name_session(conn, user, session_id)
    end
  end

  post "/sessions" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.post_create_session(conn, user)
    end
  end

  post "/assets" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.post_asset(conn, user)
    end
  end

  # ─── Authenticated PUT routes ─────────────────────────────────────────────────

  put "/auth/password" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.put_password(conn, user)
    end
  end

  put "/user/profile" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.put_user_profile(conn, user)
    end
  end

  put "/users/prefs" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.put_user_prefs(conn, user)
    end
  end

  put "/user/fact-counts" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.put_user_fact_counts(conn, user)
    end
  end

  # GET /me/credentials — list the caller's saved credentials,
  # metadata-only (no payloads). Used by the Conversation Settings
  # "Connected accounts" panel. Visible to every authenticated user.
  get "/me/credentials" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.list_my_credentials(conn, user)
    end
  end

  # DELETE /me/credentials/:id — revoke one credential row. Scopes
  # to (user_id, id) so users can only delete their OWN rows; admin
  # is not special here. Visible to every authenticated user.
  delete "/me/credentials/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.delete_my_credential(conn, user, id)
    end
  end

  put "/users/:uid" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.put_update_user(conn, user, uid)
    end
  end

  put "/admin/settings" do
    with {:ok, conn, user} <- check_auth(conn) do
      Proxy.put_admin_settings(conn, user)
    end
  end

  put "/sessions/current" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.put_current_session(conn, user)
    end
  end

  put "/sessions/:session_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.put_session(conn, user, session_id)
    end
  end

  # ─── Authenticated DELETE routes ──────────────────────────────────────────────

  delete "/users/:uid" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.delete_user(conn, user, uid)
    end
  end

  delete "/sessions/:session_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.delete_session(conn, user, session_id)
    end
  end

  # Stop the user's currently-running inline turn (Confidant or
  # Assistant). FE Stop button. Idempotent — repeated calls or
  # calls when no turn is in flight return 200 with `stopped: false`.
  # session_id is in the URL for FE clarity / future per-session
  # filtering, but the cancellation is per-user (one inline turn at a
  # time per user). See specs/architecture.md §Stop button.
  post "/sessions/:session_id/stop" do
    with {:ok, conn, user} <- check_auth(conn) do
      _ = session_id
      result =
        case UserAgent.cancel_current_turn(user.id) do
          {:ok, :stopped}        -> %{stopped: true}
          {:ok, :no_active_turn} -> %{stopped: false, reason: "no_active_turn"}
          {:error, :not_started} -> %{stopped: false, reason: "agent_not_started"}
          {:error, reason}       -> %{stopped: false, reason: inspect(reason)}
        end

      send_resp(conn, 200, Jason.encode!(result))
    end
  end

  delete "/image-descriptions/:session_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.delete_image_descriptions(conn, user, session_id)
    end
  end

  delete "/video-descriptions/:session_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.delete_video_descriptions(conn, user, session_id)
    end
  end

  # ─── SPA-fallback routes (FE owns the URL space) ─────────────────────────────
  #
  # The FE has a small client-side router (`code/js/router.js`).
  # Paths the FE handles need a BE route that serves the SPA shell
  # so a refresh / direct-link / browser-back doesn't 404. Each FE
  # route gets ONE explicit entry below — a catch-all would mask
  # typos in API URLs (`/admin/connectorss` would silently return
  # HTML), so the trade is more typing for better debugability.

  get "/connectors" do
    serve_spa(conn)
  end

  get "/connectors/:_slug" do
    serve_spa(conn)
  end

  defp serve_spa(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/html")
    |> send_file(200, "/app/static/index.html")
  end

  # ─── Catch-all ────────────────────────────────────────────────────────────────

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  # ─── Auth helper ──────────────────────────────────────────────────────────────

  # Two return shapes:
  #
  #   * `{:ok, conn, user}` — authenticated; route handler runs with
  #     the user.
  #   * `%Plug.Conn{}` (already 401-sent) — unauthenticated. Returned
  #     as the conn directly so the surrounding `with` block:
  #
  #         with {:ok, conn, user} <- check_auth(conn) do
  #           Handler.do_thing(conn, user)
  #         end
  #
  #     falls through with the conn (Elixir `with` semantics: when no
  #     `else` clause, the non-matching term is returned verbatim) —
  #     and `Plug.Router` accepts a `Plug.Conn` from `dispatch/2`.
  #
  #     Returning `{:error, conn}` here would crash the request with
  #     "expected dispatch/2 to return a Plug.Conn" because the tuple
  #     leaks through the same `with` fall-through.
  defp check_auth(conn) do
    case AuthPlug.get_auth_user(conn) do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))

      user ->
        {:ok, conn, user}
    end
  end

  # `/assets/<session>/<rest>` accepts EITHER bearer auth (FE's
  # programmatic fetches) OR a valid HMAC signature in the query
  # string (`?expires=&sig=`, used by shareable download links).
  # Returns `{:ok, owner_email}` on success, `{:error, conn}` after
  # writing a 401/410 response.
  defp authorize_asset_access(conn, session_id, rel_path) do
    case AuthPlug.get_auth_user(conn) do
      %{email: email} ->
        {:ok, email}

      nil ->
        conn = Plug.Conn.fetch_query_params(conn)

        case DmhAi.Auth.SignedUrl.verify(conn.query_params, session_id, rel_path) do
          :ok ->
            case session_owner_email(session_id) do
              {:ok, email} ->
                {:ok, email}

              :error ->
                {:error,
                 conn
                 |> put_resp_content_type("application/json")
                 |> send_resp(404, Jason.encode!(%{error: "Not found"}))}
            end

          {:error, :expired} ->
            {:error,
             conn
             |> put_resp_content_type("application/json")
             |> send_resp(410, Jason.encode!(%{error: "Link expired"}))}

          {:error, :invalid} ->
            {:error,
             conn
             |> put_resp_content_type("application/json")
             |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))}
        end
    end
  end

  defp session_owner_email(session_id) when is_binary(session_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]

    case query!(DmhAi.Repo, """
         SELECT u.email FROM sessions s JOIN users u ON s.user_id = u.id
         WHERE s.id = ?
         """, [session_id]) do
      %{rows: [[email]]} when is_binary(email) -> {:ok, email}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Loopback-only gate for /ai_pools and any other host-local
  # convenience endpoints. Two invariants must hold:
  #
  #   1. `remote_ip` is the loopback address (127/8 or ::1).
  #   2. NO `X-Forwarded-For` header is present.
  #
  # Behind a reverse proxy on the SAME host (the recommended deploy:
  # nginx → 127.0.0.1:8080), every public request reaches the BE with
  # `remote_ip = 127.0.0.1` — so check (1) alone is bypassed by the
  # deployment topology. nginx (and every other reverse proxy) appends
  # to `X-Forwarded-For` on every forwarded request, so the mere
  # PRESENCE of the header proves the request was forwarded, even if
  # the immediate hop was loopback. A real "operator typed `curl` on
  # the host shell" request has no `X-F-F`.
  #
  # Asymmetric to `client_ip/1` below by design: `client_ip` is
  # intentionally permissive (UI hint, never security); `loopback?` is
  # intentionally restrictive (security gate). Both read X-F-F for
  # opposite reasons — that's not a bug, it's the contract.
  #
  # An attacker hitting the BE directly (port 8080 exposed) with a
  # spoofed `X-Forwarded-For: 1.2.3.4` is now correctly 403'd —
  # presence disqualifies, the value doesn't matter.
  defp loopback?(conn) do
    ip_loopback?(conn.remote_ip) and Plug.Conn.get_req_header(conn, "x-forwarded-for") == []
  end

  defp ip_loopback?({127, _, _, _}),           do: true
  defp ip_loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp ip_loopback?(_),                         do: false

  # Best-effort client IP for non-security purposes (UI language hint).
  # When behind a reverse proxy (nginx, traefik, Caddy) `conn.remote_ip`
  # is the proxy's IP; the original client is in `X-Forwarded-For`
  # (leftmost = original) or `X-Real-IP`. We accept those headers
  # unconditionally — this value is NEVER used for security/auth, only
  # for picking a default UI language, so a spoofed header at worst
  # gives the spoofer a different default language. Falls back to
  # `conn.remote_ip` formatted as a string.
  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [val | _] when val != "" ->
        val |> String.split(",") |> hd() |> String.trim()

      _ ->
        case Plug.Conn.get_req_header(conn, "x-real-ip") do
          [val | _] when val != "" ->
            val

          _ ->
            case conn.remote_ip do
              ip when is_tuple(ip) -> ip |> :inet_parse.ntoa() |> List.to_string()
              _ -> nil
            end
        end
    end
  end
end
