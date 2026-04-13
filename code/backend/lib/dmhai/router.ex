defmodule Dmhai.Router do
  use Plug.Router
  import Plug.Conn
  alias Dmhai.AuthPlug
  alias Dmhai.Handlers.Auth
  alias Dmhai.Handlers.Data
  alias Dmhai.Handlers.Proxy

  plug Plug.Head
  plug :match
  plug :dispatch

  # ─── No-auth GET routes ──────────────────────────────────────────────────────

  get "/auth/me" do
    Auth.get_me(conn)
  end

  # GET /local-api/* — no auth required
  get "/local-api/*glob" do
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
