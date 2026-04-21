# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Router do
  use Plug.Router
  import Plug.Conn
  alias Dmhai.AuthPlug
  alias Dmhai.Handlers.Auth
  alias Dmhai.Handlers.Data
  alias Dmhai.Handlers.Media
  alias Dmhai.Handlers.Proxy
  alias Dmhai.Handlers.Tools
  alias Dmhai.Handlers.AgentChat
  alias Dmhai.Agent.UserAgent
  alias Dmhai.Agent.MasterBuffer

  plug Dmhai.Plugs.BlockScanners
  plug Dmhai.Plugs.SecurityHeaders
  plug Plug.Static, at: "/", from: "/app/static", gzip: false,
    headers: %{"cache-control" => "no-store"}
  plug Dmhai.Plugs.RateLimit
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

  # GET /registry — no auth required
  get "/registry" do
    Proxy.get_registry(conn)
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

  get "/notifications" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_notifications(conn, user)
    end
  end

  get "/assets/:session_id/:file_id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_asset(conn, user, session_id, file_id)
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

  get "/reserve-task-id" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.get_reserved_task_id(conn, user)
    end
  end

  post "/upload-task-attachment" do
    with {:ok, conn, user} <- check_auth(conn) do
      Data.post_task_attachment(conn, user)
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

  post "/cloud-api/*glob" do
    with {:ok, conn, user} <- check_auth(conn) do
      sub = Enum.join(glob, "/")
      Proxy.post_cloud_api(conn, user, sub)
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

  # Cancel all running workers and flush master_buffer for a session (used by "Clear session")
  post "/sessions/:session_id/cancel-workers" do
    with {:ok, conn, user} <- check_auth(conn) do
      UserAgent.cancel_session_workers(user.id, session_id)
      MasterBuffer.delete_for_session(session_id)
      send_resp(conn, 200, Jason.encode!(%{ok: true}))
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
end
