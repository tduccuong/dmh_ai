# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Tasks do
  @moduledoc """
  DB helpers for the `tasks` table — the system of record for all
  background work (one-off resolver answers, one-off worker tasks,
  periodic worker tasks). Assistant inserts a row per classification;
  runtime scheduler reads/updates rows; workers read task_spec by id.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Insert a fresh task row. Returns the task_id.
  status defaults to 'pending'; caller bumps to 'running' when the worker starts.
  """
  def insert(attrs) do
    task_id = attrs[:task_id] || generate_id()
    now     = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO tasks (task_id, user_id, session_id, task_type, intvl_sec,
                       task_title, task_spec, task_status, language,
                       pipeline, origin,
                       created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      task_id,
      attrs[:user_id],
      attrs[:session_id],
      attrs[:task_type] || "one_off",
      attrs[:intvl_sec] || 0,
      attrs[:task_title] || "",
      attrs[:task_spec] || "",
      attrs[:task_status] || "pending",
      attrs[:language] || "en",
      attrs[:pipeline] || "assistant",
      attrs[:origin] || "assistant",
      now, now
    ])

    task_id
  end

  @select_cols """
  task_id, user_id, session_id, task_type, intvl_sec, task_title,
  task_spec, task_status, task_result,
  created_at, updated_at,
  last_run_started_at, last_run_completed_at,
  next_run_at, last_reported_status_id, current_worker_id,
  last_summarized_status_id, last_summarized_at, language,
  pipeline, origin
  """

  def get(task_id) do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE task_id=?", [task_id])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  def mark_running(task_id, worker_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='running',
                    current_worker_id=?,
                    last_run_started_at=?,
                    updated_at=?
    WHERE task_id=?
    """, [worker_id, now, now, task_id])
  end

  def mark_done(task_id, result) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='done',
                    task_result=?,
                    last_run_completed_at=?,
                    current_worker_id=NULL,
                    updated_at=?
    WHERE task_id=?
    """, [result, now, now, task_id])
  end

  def mark_blocked(task_id, reason) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='blocked',
                    task_result=?,
                    last_run_completed_at=?,
                    current_worker_id=NULL,
                    updated_at=?
    WHERE task_id=?
    """, [reason, now, now, task_id])
  end

  def mark_cancelled(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='cancelled',
                    current_worker_id=NULL,
                    updated_at=?
    WHERE task_id=?
    """, [now, task_id])
  end

  def mark_paused(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='paused',
                    current_worker_id=NULL,
                    updated_at=?
    WHERE task_id=?
    """, [now, task_id])
  end

  def mark_pending(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='pending',
                    updated_at=?
    WHERE task_id=?
    """, [now, task_id])
  end

  def set_periodic(task_id, intvl_sec) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_type='periodic', intvl_sec=?, updated_at=?
    WHERE task_id=?
    """, [intvl_sec, now, task_id])
  end

  def schedule_next_run(task_id, next_run_at) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET next_run_at=?, task_status='pending', updated_at=?
    WHERE task_id=?
    """, [next_run_at, now, task_id])
  end

  def advance_cursor(task_id, last_status_id) do
    query!(Repo, """
    UPDATE tasks SET last_reported_status_id=?, updated_at=?
    WHERE task_id=? AND (last_reported_status_id IS NULL OR last_reported_status_id < ?)
    """, [last_status_id, System.os_time(:millisecond), task_id, last_status_id])
  end

  def advance_summary_cursor(task_id, last_status_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET last_summarized_status_id=?, last_summarized_at=?, updated_at=?
    WHERE task_id=? AND (last_summarized_status_id IS NULL OR last_summarized_status_id < ?)
    """, [last_status_id, now, now, task_id, last_status_id])
  end

  @doc "Tasks that were running when the app went down — need cleanup on boot."
  def fetch_orphaned do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE task_status='running'", [])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc "Periodic tasks due for next run (next_run_at <= now) and not cancelled."
  def fetch_due_periodic(now_ms \\ nil) do
    now_ms = now_ms || System.os_time(:millisecond)
    r = query!(Repo, """
    SELECT #{@select_cols}
    FROM tasks
    WHERE task_type='periodic'
      AND task_status IN ('pending','done','blocked')
      AND next_run_at IS NOT NULL
      AND next_run_at <= ?
    """, [now_ms])
    Enum.map(r.rows, &row_to_map/1)
  end

  def list_for_session(session_id) do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE session_id=? ORDER BY created_at DESC", [session_id])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc "Active (not terminal) tasks for a session — used for context injection and session-level cancellation."
  def active_for_session(session_id) do
    r = query!(Repo, """
    SELECT #{@select_cols} FROM tasks
    WHERE session_id=? AND task_status IN ('pending', 'running', 'paused')
    """, [session_id])
    Enum.map(r.rows, &row_to_map/1)
  end

  def delete_for_session(session_id) do
    query!(Repo, "DELETE FROM worker_status WHERE task_id IN (SELECT task_id FROM tasks WHERE session_id=?)", [session_id])
    query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
    :ok
  end

  @doc "True when the given task_id is not yet taken — used to validate pre-allocated ids."
  def id_available?(task_id) do
    r = query!(Repo, "SELECT 1 FROM tasks WHERE task_id=?", [task_id])
    r.rows == []
  end

  @doc "Lookup user email by user_id. Falls back to user_id string on miss."
  def lookup_user_email(user_id) do
    case query!(Repo, "SELECT email FROM users WHERE id=?", [user_id]) do
      %{rows: [[email]]} when is_binary(email) -> email
      _ -> user_id
    end
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp row_to_map([
    task_id, user_id, session_id, task_type, intvl_sec, task_title, task_spec,
    task_status, task_result, created_at, updated_at, last_run_started_at,
    last_run_completed_at, next_run_at, last_reported_status_id, current_worker_id,
    last_summarized_status_id, last_summarized_at, language, pipeline, origin
  ]) do
    %{
      task_id: task_id,
      user_id: user_id,
      session_id: session_id,
      task_type: task_type,
      intvl_sec: intvl_sec,
      task_title: task_title,
      task_spec: task_spec,
      task_status: task_status,
      task_result: task_result,
      created_at: created_at,
      updated_at: updated_at,
      last_run_started_at: last_run_started_at,
      last_run_completed_at: last_run_completed_at,
      next_run_at: next_run_at,
      last_reported_status_id: last_reported_status_id || 0,
      current_worker_id: current_worker_id,
      last_summarized_status_id: last_summarized_status_id || 0,
      last_summarized_at: last_summarized_at || 0,
      language: language || "en",
      pipeline: pipeline || "assistant",
      origin:   origin   || "assistant"
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
  end
end
