# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Jobs do
  @moduledoc """
  DB helpers for the `jobs` table — the system of record for all
  background work (one-off resolver answers, one-off worker tasks,
  periodic worker tasks). Assistant inserts a row per classification;
  runtime scheduler reads/updates rows; workers read job_spec by id.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Insert a fresh job row. Returns the job_id.
  status defaults to 'pending'; caller bumps to 'running' when the worker starts.
  """
  def insert(attrs) do
    job_id = attrs[:job_id] || generate_id()
    now    = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO jobs (job_id, user_id, session_id, job_type, intvl_sec,
                      job_title, job_spec, job_status, language,
                      pipeline, origin,
                      created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      job_id,
      attrs[:user_id],
      attrs[:session_id],
      attrs[:job_type] || "one_off",
      attrs[:intvl_sec] || 0,
      attrs[:job_title] || "",
      attrs[:job_spec] || "",
      attrs[:job_status] || "pending",
      attrs[:language] || "en",
      attrs[:pipeline] || "assistant",
      attrs[:origin] || "assistant",
      now, now
    ])

    job_id
  end

  @select_cols """
  job_id, user_id, session_id, job_type, intvl_sec, job_title,
  job_spec, job_status, job_result,
  created_at, updated_at,
  last_run_started_at, last_run_completed_at,
  next_run_at, last_reported_status_id, current_worker_id,
  last_summarized_status_id, last_summarized_at, language,
  pipeline, origin
  """

  def get(job_id) do
    r = query!(Repo, "SELECT #{@select_cols} FROM jobs WHERE job_id=?", [job_id])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  def mark_running(job_id, worker_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE jobs SET job_status='running',
                    current_worker_id=?,
                    last_run_started_at=?,
                    updated_at=?
    WHERE job_id=?
    """, [worker_id, now, now, job_id])
  end

  def mark_done(job_id, result) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE jobs SET job_status='done',
                    job_result=?,
                    last_run_completed_at=?,
                    current_worker_id=NULL,
                    updated_at=?
    WHERE job_id=?
    """, [result, now, now, job_id])
  end

  def mark_blocked(job_id, reason) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE jobs SET job_status='blocked',
                    job_result=?,
                    last_run_completed_at=?,
                    current_worker_id=NULL,
                    updated_at=?
    WHERE job_id=?
    """, [reason, now, now, job_id])
  end

  def mark_cancelled(job_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE jobs SET job_status='cancelled',
                    current_worker_id=NULL,
                    updated_at=?
    WHERE job_id=?
    """, [now, job_id])
  end

  def set_periodic(job_id, intvl_sec) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE jobs SET job_type='periodic', intvl_sec=?, updated_at=?
    WHERE job_id=?
    """, [intvl_sec, now, job_id])
  end

  def schedule_next_run(job_id, next_run_at) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE jobs SET next_run_at=?, job_status='pending', updated_at=?
    WHERE job_id=?
    """, [next_run_at, now, job_id])
  end

  def advance_cursor(job_id, last_status_id) do
    query!(Repo, """
    UPDATE jobs SET last_reported_status_id=?, updated_at=?
    WHERE job_id=? AND (last_reported_status_id IS NULL OR last_reported_status_id < ?)
    """, [last_status_id, System.os_time(:millisecond), job_id, last_status_id])
  end

  def advance_summary_cursor(job_id, last_status_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE jobs SET last_summarized_status_id=?, last_summarized_at=?, updated_at=?
    WHERE job_id=? AND (last_summarized_status_id IS NULL OR last_summarized_status_id < ?)
    """, [last_status_id, now, now, job_id, last_status_id])
  end

  @doc "Jobs that were running when the app went down — need cleanup on boot."
  def fetch_orphaned do
    r = query!(Repo, "SELECT #{@select_cols} FROM jobs WHERE job_status='running'", [])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc "Periodic jobs due for next run (next_run_at <= now) and not cancelled."
  def fetch_due_periodic(now_ms \\ nil) do
    now_ms = now_ms || System.os_time(:millisecond)
    r = query!(Repo, """
    SELECT #{@select_cols}
    FROM jobs
    WHERE job_type='periodic'
      AND job_status IN ('pending','done','blocked')
      AND next_run_at IS NOT NULL
      AND next_run_at <= ?
    """, [now_ms])
    Enum.map(r.rows, &row_to_map/1)
  end

  def list_for_session(session_id) do
    r = query!(Repo, "SELECT #{@select_cols} FROM jobs WHERE session_id=? ORDER BY created_at DESC", [session_id])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc "Active (not terminal) jobs for a session — used for cancellation on session delete."
  def active_for_session(session_id) do
    r = query!(Repo, """
    SELECT #{@select_cols} FROM jobs
    WHERE session_id=? AND job_status IN ('pending', 'running')
    """, [session_id])
    Enum.map(r.rows, &row_to_map/1)
  end

  def delete_for_session(session_id) do
    query!(Repo, "DELETE FROM worker_status WHERE job_id IN (SELECT job_id FROM jobs WHERE session_id=?)", [session_id])
    query!(Repo, "DELETE FROM jobs WHERE session_id=?", [session_id])
    :ok
  end

  @doc "True when the given job_id is not yet taken — used to validate pre-allocated ids."
  def id_available?(job_id) do
    r = query!(Repo, "SELECT 1 FROM jobs WHERE job_id=?", [job_id])
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
    job_id, user_id, session_id, job_type, intvl_sec, job_title, job_spec,
    job_status, job_result, created_at, updated_at, last_run_started_at,
    last_run_completed_at, next_run_at, last_reported_status_id, current_worker_id,
    last_summarized_status_id, last_summarized_at, language, pipeline, origin
  ]) do
    %{
      job_id: job_id,
      user_id: user_id,
      session_id: session_id,
      job_type: job_type,
      intvl_sec: intvl_sec,
      job_title: job_title,
      job_spec: job_spec,
      job_status: job_status,
      job_result: job_result,
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
