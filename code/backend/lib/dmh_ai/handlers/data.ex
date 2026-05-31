# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data do
  @moduledoc """
  Façade for `/sessions/*`, `/assets/*`, `/video-descriptions/*`,
  `/image-descriptions/*`, `/upload-session-attachment`, `/log` and
  `/sessions/:id/token-stats`.

  The router calls this module directly — every public function
  declared here is the routable surface. The actual implementations
  live in sub-modules under `__MODULE__.{Sessions, SessionProgress,
  Descriptions, Assets, FormSubmission, TokenStats, Settings}`; this
  shell only owns:

  * `json/3` — the generic JSON-response helper every sub-module uses.
  * `post_log/1` — small standalone endpoint with no natural sub-module.
  * `log/1` — thin pass-through to `DmhAi.SysLog`.

  Everything else is `defdelegate`-routed so the public surface is
  unchanged.
  """

  import Plug.Conn

  alias __MODULE__.{
    Assets,
    Descriptions,
    FormSubmission,
    Sessions,
    SessionProgress,
    TokenStats
  }

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # POST /log
  def post_log(conn) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    msg = d["msg"] || ""
    log(msg)
    json(conn, 200, %{ok: true})
  end

  defp log(msg), do: DmhAi.SysLog.log(msg)

  # ─── Routable surface ──────────────────────────────────────────────────
  # Each delegate keeps the function on `DmhAi.Handlers.Data` so the
  # router (and any test) keeps resolving it on the top-level module.

  # Sessions
  defdelegate get_sessions(conn, user), to: Sessions
  defdelegate get_current_session(conn, user), to: Sessions
  defdelegate get_session(conn, user, session_id), to: Sessions
  defdelegate stop_session(conn, user, session_id), to: Sessions
  defdelegate post_create_session(conn, user), to: Sessions
  defdelegate put_current_session(conn, user), to: Sessions
  defdelegate post_name_session(conn, user, session_id), to: Sessions
  defdelegate put_session(conn, user, session_id), to: Sessions
  defdelegate delete_session(conn, user, session_id), to: Sessions

  # Session progress + polling
  defdelegate get_session_progress(conn, user, session_id), to: SessionProgress
  defdelegate poll_session(conn, user, session_id), to: SessionProgress

  # Descriptions
  defdelegate get_video_descriptions(conn, user, session_id), to: Descriptions
  defdelegate get_image_descriptions(conn, user, session_id), to: Descriptions
  defdelegate post_video_description(conn, user), to: Descriptions
  defdelegate post_image_description(conn, user), to: Descriptions
  defdelegate delete_video_descriptions(conn, user, session_id), to: Descriptions
  defdelegate delete_image_descriptions(conn, user, session_id), to: Descriptions

  # Assets
  defdelegate get_asset(conn, user, session_id, rest), to: Assets
  defdelegate post_asset(conn, user), to: Assets
  defdelegate post_session_attachment(conn, user), to: Assets

  # Form submission
  defdelegate submit_input(conn, user, session_id, token), to: FormSubmission

  # Token stats (admin)
  defdelegate get_token_stats(conn, user, session_id), to: TokenStats
end
