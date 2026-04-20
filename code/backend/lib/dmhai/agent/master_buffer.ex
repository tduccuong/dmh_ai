# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.MasterBuffer do
  @moduledoc """
  Notification bus used by JobRuntime to ping the frontend polling loop.

  Two notification kinds:
  - Sentinel (append_notification/3): content="", signals the FE to reload the session.
  - Progress (append_progress_notification/4): content=progress_text, signals the FE to
    display a status-phrase update without reloading the session.

  The FE distinguishes by checking whether `content` is non-empty.

  NOTE: the table still has a `worker_id` column from the old schema but
  nothing writes to it any more. It is left in place to avoid a SQLite
  column migration; can be dropped in a future DB cleanup.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Write a consumed notification-only entry — a sentinel that tells the
  frontend polling loop "something happened in this session, reload".
  """
  def append_notification(session_id, user_id, summary) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO master_buffer (session_id, user_id, content, summary, consumed, created_at) VALUES (?,?,?,?,1,?)",
      [session_id, user_id, "", summary, now])
  end

  @doc """
  Write a progress-status notification — carries the 2-sentence status text so
  the frontend can display it as a status phrase without reloading the session.
  """
  def append_progress_notification(session_id, user_id, progress_text, summary) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO master_buffer (session_id, user_id, content, summary, consumed, created_at) VALUES (?,?,?,?,1,?)",
      [session_id, user_id, progress_text, summary, now])
  end

  @doc "Fetch notification rows for a user across all sessions since `since_ms`."
  def fetch_notifications(user_id, since_ms) do
    result =
      query!(Repo,
        """
        SELECT mb.id, mb.session_id, mb.summary, mb.created_at, mb.content
        FROM master_buffer mb
        WHERE mb.user_id=? AND mb.created_at > ? AND mb.summary IS NOT NULL
        ORDER BY mb.created_at ASC
        """,
        [user_id, since_ms])

    Enum.map(result.rows, fn [id, session_id, summary, created_at, content] ->
      %{id: id, session_id: session_id, summary: summary, created_at: created_at, content: content || ""}
    end)
  end

  @doc "Purge notifications for a session (called on session delete)."
  def delete_for_session(session_id) do
    query!(Repo, "DELETE FROM master_buffer WHERE session_id=?", [session_id])
    :ok
  end
end
