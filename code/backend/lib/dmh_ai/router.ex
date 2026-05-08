# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Router do
  use Plug.Router
  import Plug.Conn
  alias DmhAi.AuthPlug
  alias DmhAi.Handlers.AdminMcpCatalog
  alias DmhAi.Handlers.AdminPools
  alias DmhAi.Handlers.AdminSeeds
  alias DmhAi.Handlers.Auth
  alias DmhAi.Handlers.Data
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

  # GET /local-api/* — no auth required
  get "/local-api/*glob" do
    sub = Enum.join(glob, "/")
    Proxy.get_local_api(conn, sub)
  end

  # GET /api/* — no auth, proxy to local Ollama (replaces nginx /api → :11434)
  get "/api/*glob" do
    sub = Enum.join(glob, "/")
    Proxy.get_local_api(conn, sub)
  end

  # GET /search — no auth required
  get "/search" do
    Proxy.get_search(conn)
  end

  # GET /fetch-page — no auth required
  get "/fetch-page" do
    Proxy.get_fetch_page(conn)
  end

  # ─── POST no-auth ─────────────────────────────────────────────────────────────

  post "/auth/login" do
    Auth.post_login(conn)
  end

  post "/auth/logout" do
    Auth.post_logout(conn)
  end

  # POST /local-api/* — no auth required (streaming)
  post "/local-api/*glob" do
    sub = Enum.join(glob, "/")
    Proxy.post_local_api(conn, sub)
  end

  # POST /api/show — capability check; backend models always support vision + video
  post "/api/show" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{capabilities: ["vision", "video"]}))
  end

  # POST /api/* — no auth, proxy to local Ollama (replaces nginx /api → :11434)
  post "/api/*glob" do
    sub = Enum.join(glob, "/")
    Proxy.post_local_api(conn, sub)
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

  # ── Admin: curated OAuth services ────────────────────────────────────────

  get "/admin/oauth_catalog" do
    with {:ok, conn, user} <- check_auth(conn) do
      DmhAi.Handlers.AdminOAuthCatalog.list(conn, user)
    end
  end

  post "/admin/oauth_catalog" do
    with {:ok, conn, user} <- check_auth(conn) do
      DmhAi.Handlers.AdminOAuthCatalog.create(conn, user)
    end
  end

  put "/admin/oauth_catalog/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      DmhAi.Handlers.AdminOAuthCatalog.update(conn, user, id)
    end
  end

  delete "/admin/oauth_catalog/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      DmhAi.Handlers.AdminOAuthCatalog.delete(conn, user, id)
    end
  end

  get "/admin/wiki-seeds" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminSeeds.list(conn, user)
    end
  end

  post "/admin/wiki-seeds" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminSeeds.create(conn, user)
    end
  end

  delete "/admin/wiki-seeds/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminSeeds.delete(conn, user, id)
    end
  end

  post "/admin/wiki-seeds/:id/run" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminSeeds.run_one(conn, user, id)
    end
  end

  post "/admin/wiki-seeds/run-all" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminSeeds.run_all(conn, user)
    end
  end

  # ── MCP Catalog (specs/mcp.md §Phase E) ───────────────────────────────

  get "/admin/mcp-catalog" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminMcpCatalog.list(conn, user)
    end
  end

  post "/admin/mcp-catalog" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminMcpCatalog.create(conn, user)
    end
  end

  put "/admin/mcp-catalog/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminMcpCatalog.update(conn, user, id)
    end
  end

  delete "/admin/mcp-catalog/:id" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminMcpCatalog.delete(conn, user, id)
    end
  end

  post "/admin/mcp-catalog/:id/enable" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminMcpCatalog.enable(conn, user, id)
    end
  end

  post "/admin/mcp-catalog/:id/disable" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminMcpCatalog.disable(conn, user, id)
    end
  end

  post "/admin/mcp-catalog/import" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminMcpCatalog.import_many(conn, user)
    end
  end

  post "/admin/pools/import" do
    with {:ok, conn, user} <- check_auth(conn) do
      AdminPools.import_many(conn, user)
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

  get "/sessions/:session_id/tasks" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_session_tasks(conn, user, session_id)
    end
  end

  # POST /tasks/:task_id/cancel — sidebar cancel for a single task.
  # Session-level interrupts go through mid-chain user-message splice
  # (the user sends a new chat message to redirect the assistant); this
  # endpoint is for explicit per-task cancellation from the sidebar.
  post "/tasks/:task_id/cancel" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.cancel_task(conn, user, task_id)
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
    Data.oauth_callback(conn)
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

  get "/assets/:session_id/:file_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_asset(conn, user, session_id, file_id)
    end
  end

  # Per-session browser_navigate per-step screenshot. Serves PNGs from
  # `<session_workspace>/.browser/<file_name>`. Owned by the runtime
  # (Browser.Loop writes via the daemon), not the model — so unlike
  # the wider workspace tree (intentionally not served by /assets),
  # this narrow path IS exposed for the FE thumbnail render.
  #
  # Explicit `else` arm — when `check_auth` 401s, it returns
  # `{:error, conn}` (the 401 already-sent). Without unwrapping that
  # tuple here, Plug.Router rejects the handler's return value with
  # `expected dispatch/2 to return a Plug.Conn` and crashes the
  # request. The `<img>` tag can't carry an Authorization header so
  # this route hits the 401 branch anytime the FE forgets to use the
  # apiFetch+blob pattern.
  get "/sessions/:session_id/browser-screenshot/:file_name" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_browser_screenshot(conn, user, session_id, file_name)
    else
      {:error, conn} -> conn
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

  # GET /auth/me/browser-consent — return current consent state +
  # canonical text/hash for FE display.
  get "/auth/me/browser-consent" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.get_browser_consent(conn, user)
    end
  end

  # POST /auth/me/browser-consent — record acceptance. Body:
  # `{"text_hash": "<sha256 hex>"}`. The hash MUST equal the current
  # canonical hash; mismatch is rejected (the FE was showing stale text).
  post "/auth/me/browser-consent" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.post_browser_consent(conn, user)
    end
  end

  # DELETE /auth/me/browser-consent — revoke. Nulls both columns; the
  # next browser_navigate invocation will re-prompt.
  delete "/auth/me/browser-consent" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.delete_browser_consent(conn, user)
    end
  end

  # GET /me/preferences — return the per-user preferences blob (FE-
  # serialised, defaults applied). Visible to every authenticated
  # user, NOT admin-gated — these are personal toggles, not global
  # runtime config (which lives in /admin/settings).
  get "/me/preferences" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.get_my_preferences(conn, user)
    end
  end

  # PUT /me/preferences — replace one or more preference keys. Body
  # is a JSON map of `{key: value}`; keys not in the schema are
  # rejected, types are validated. Same all-users gate as the GET.
  put "/me/preferences" do
    with {:ok, conn, user} <- check_auth(conn) do
      Auth.put_my_preferences(conn, user)
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

  # Cancel all running tasks for a session (used by "Clear session")
  post "/sessions/:session_id/cancel-workers" do
    with {:ok, conn, user} <- check_auth(conn) do
      UserAgent.cancel_session_tasks(user.id, session_id)
      send_resp(conn, 200, Jason.encode!(%{ok: true}))
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

  # ─── Catch-all ────────────────────────────────────────────────────────────────

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  # ─── Auth helper ──────────────────────────────────────────────────────────────

  # Returns {:ok, conn, user} or sends 401 and returns the halted conn.
  # The `with` pattern match on {:ok, ...} means halted conn falls through
  # and becomes the return value of the `with` block (Elixir with semantics:
  # when no else clause, the non-matching term is returned as-is).
  defp check_auth(conn) do
    case AuthPlug.get_auth_user(conn) do
      nil ->
        conn =
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))

        {:error, conn}

      user ->
        {:ok, conn, user}
    end
  end

  # Loopback-only gate for /ai_pools and any other host-local
  # convenience endpoints. Trusts conn.remote_ip directly — does NOT
  # consult X-Forwarded-For, since a forwarded header is operator-
  # controlled at the proxy level and we must NOT let an external
  # client spoof loopback access. Behind a reverse proxy the operator
  # is expected to filter /ai_pools at the proxy layer (or just not
  # forward it).
  defp loopback?(%Plug.Conn{remote_ip: {127, _, _, _}}), do: true
  defp loopback?(%Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp loopback?(_), do: false

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
