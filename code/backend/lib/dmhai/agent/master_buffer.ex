# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.MasterBuffer do
  @moduledoc """
  Read/write interface for the `master_buffer` table.

  Workers write full results + short summaries here.
  The runtime reads unconsumed entries and injects them into the
  Master Agent's next LLM call.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Append a worker result to the buffer.

  - `content`   — full result text (injected into Master LLM call)
  - `summary`   — short one-liner for frontend notification
  - `worker_id` — optional worker ID for per-job query support
  """
  def append(session_id, user_id, content, summary \\ nil, worker_id \\ nil) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO master_buffer (session_id, user_id, content, summary, worker_id, created_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, content, summary, worker_id, now])
  end

  @doc """
  Fetch all unconsumed entries for a session, ordered chronologically.
  Returns a list of `%{id, content, summary, created_at}` maps.
  """
  def fetch_unconsumed(session_id) do
    result =
      query!(Repo,
        "SELECT id, content, summary, created_at, worker_id FROM master_buffer WHERE session_id=? AND consumed=0 ORDER BY created_at ASC",
        [session_id])

    Enum.map(result.rows, fn [id, content, summary, created_at, worker_id] ->
      %{id: id, content: content, summary: summary, created_at: created_at, worker_id: worker_id}
    end)
  end

  @doc """
  Mark entries as consumed so they aren't injected again.
  Accepts a list of entry IDs.
  """
  def mark_consumed(ids) when is_list(ids) and ids != [] do
    placeholders = Enum.map_join(ids, ",", fn _ -> "?" end)
    query!(Repo, "UPDATE master_buffer SET consumed=1 WHERE id IN (#{placeholders})", ids)
  end

  def mark_consumed([]), do: :ok

  @doc """
  Write a consumed notification-only entry.

  Visible to `fetch_notifications` (triggers frontend reload) but skipped by
  `fetch_unconsumed` (consumed=1, so master LLM won't inject it again).
  Call this *after* the master has already written its response to the session.
  """
  def append_notification(session_id, user_id, summary) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO master_buffer (session_id, user_id, content, summary, consumed, created_at) VALUES (?,?,?,?,1,?)",
      [session_id, user_id, "", summary, now])
  end

  @doc """
  Fetch the most recent `limit` entries for a specific worker job (any consumed state).
  Returns a list of `%{id, content, summary, created_at}` in chronological order.
  """
  def fetch_for_worker(session_id, worker_id, limit \\ 20) do
    result =
      query!(Repo,
        "SELECT id, content, summary, created_at FROM master_buffer WHERE session_id=? AND worker_id=? ORDER BY created_at DESC LIMIT ?",
        [session_id, worker_id, limit])

    result.rows
    |> Enum.map(fn [id, content, summary, created_at] ->
      %{id: id, content: content, summary: summary, created_at: created_at}
    end)
    |> Enum.reverse()
  end

  @doc """
  Fetch unconsumed summaries for a user across all sessions (for notification polling).
  Returns entries since `since_ms` (unix millis).
  """
  def delete_for_session(session_id) do
    query!(Repo, "DELETE FROM master_buffer WHERE session_id=?", [session_id])
    :ok
  end

  def fetch_notifications(user_id, since_ms) do
    result =
      query!(Repo,
        """
        SELECT mb.id, mb.session_id, mb.summary, mb.created_at
        FROM master_buffer mb
        WHERE mb.user_id=? AND mb.created_at > ? AND mb.summary IS NOT NULL
        ORDER BY mb.created_at ASC
        """,
        [user_id, since_ms])

    Enum.map(result.rows, fn [id, session_id, summary, created_at] ->
      %{id: id, session_id: session_id, summary: summary, created_at: created_at}
    end)
  end
end
