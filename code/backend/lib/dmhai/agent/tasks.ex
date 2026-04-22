# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Tasks do
  @moduledoc """
  DB helpers for the `tasks` table — per-session record of assistant tasks
  (one_off or periodic). Rows are created by the assistant via
  `create_task` and mutated via `update_task` as the session loop runs.

  `Tasks.mark_done/2` is the **single rescheduling path** for periodic
  tasks: on done it auto-reschedules (status=pending, time_to_pickup
  bumped) and arms a TaskRuntime timer. The session loop does not need to
  think about rescheduling separately.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @select_cols """
  task_id, user_id, session_id, task_type, intvl_sec, task_title,
  task_spec, task_status, task_result, time_to_pickup,
  language, created_at, updated_at
  """

  @doc """
  Insert a fresh task row. Returns the task_id.
  One_off: time_to_pickup defaults to now (immediate pickup).
  Periodic: time_to_pickup defaults to now (first cycle is immediate).
  """
  def insert(attrs) do
    task_id = attrs[:task_id] || generate_id()
    now     = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO tasks (task_id, user_id, session_id, task_type, intvl_sec,
                       task_title, task_spec, task_status, time_to_pickup,
                       language, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      task_id,
      attrs[:user_id],
      attrs[:session_id],
      attrs[:task_type] || "one_off",
      attrs[:intvl_sec] || 0,
      attrs[:task_title] || "",
      attrs[:task_spec] || "",
      attrs[:task_status] || "pending",
      attrs[:time_to_pickup] || now,
      attrs[:language] || "en",
      now, now
    ])

    task_id
  end

  def get(task_id) do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE task_id=?", [task_id])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  @doc "Mark a task ongoing when the session turn starts working on it."
  def mark_ongoing(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='ongoing', updated_at=?
    WHERE task_id=?
    """, [now, task_id])
  end

  @doc """
  Terminal success. For one_off: status→done. For periodic: status→pending
  with time_to_pickup bumped by intvl_sec. TaskRuntime.schedule_pickup is
  called to arm the next timer.
  """
  def mark_done(task_id, result) do
    task = get(task_id)
    now  = System.os_time(:millisecond)

    case task && task.task_type do
      "periodic" ->
        next_at = now + (task.intvl_sec || 0) * 1_000
        query!(Repo, """
        UPDATE tasks SET task_status='pending',
                        task_result=?,
                        time_to_pickup=?,
                        updated_at=?
        WHERE task_id=?
        """, [result || "", next_at, now, task_id])
        Dmhai.Agent.TaskRuntime.schedule_pickup(task_id, next_at)

      _ ->
        query!(Repo, """
        UPDATE tasks SET task_status='done',
                        task_result=?,
                        time_to_pickup=NULL,
                        updated_at=?
        WHERE task_id=?
        """, [result || "", now, task_id])
    end
  end

  def mark_cancelled(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='cancelled',
                    time_to_pickup=NULL,
                    updated_at=?
    WHERE task_id=?
    """, [now, task_id])
    Dmhai.Agent.TaskRuntime.cancel_pickup(task_id)
  end

  def mark_paused(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='paused',
                    updated_at=?
    WHERE task_id=?
    """, [now, task_id])
    Dmhai.Agent.TaskRuntime.cancel_pickup(task_id)
  end

  def mark_pending(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='pending',
                    updated_at=?
    WHERE task_id=?
    """, [now, task_id])
  end

  @doc "Update the task's spec text in place (used for mid-run adjustment)."
  def update_spec(task_id, new_spec) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_spec=?, updated_at=?
    WHERE task_id=?
    """, [new_spec, now, task_id])
  end

  @doc "Update the interval for a periodic task."
  def update_intvl(task_id, intvl_sec) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET intvl_sec=?, task_type='periodic', updated_at=?
    WHERE task_id=?
    """, [intvl_sec, now, task_id])
  end

  @doc """
  Tasks whose pickup time has arrived. Used by boot rehydration and any
  future code that wants to scan-on-wake instead of timer-driven.
  """
  def fetch_due(now_ms \\ nil) do
    now_ms = now_ms || System.os_time(:millisecond)
    r = query!(Repo, """
    SELECT #{@select_cols}
    FROM tasks
    WHERE task_status='pending'
      AND time_to_pickup IS NOT NULL
      AND time_to_pickup <= ?
    """, [now_ms])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  Return the single oldest pending task (lowest `time_to_pickup`) for a
  session that is ready to pick up now. Used by the UserAgent's auto-chain
  loop: after a turn completes it calls this, and if a row comes back it
  self-sends `{:task_due, task_id}` so the next turn picks it up.

  Only `pending` status is considered — `ongoing` means the model is
  actively working on it (or was, before a crash; rehydration reverts those
  to pending) and shouldn't be double-dispatched. Future-scheduled pickups
  (`time_to_pickup > now`) are handled by `TaskRuntime` timers, not here.
  """
  @spec fetch_next_due(String.t(), integer() | nil) :: map() | nil
  def fetch_next_due(session_id, now_ms \\ nil) do
    now_ms = now_ms || System.os_time(:millisecond)

    r = query!(Repo, """
    SELECT #{@select_cols}
    FROM tasks
    WHERE session_id=?
      AND task_status='pending'
      AND time_to_pickup IS NOT NULL
      AND time_to_pickup <= ?
    ORDER BY time_to_pickup ASC
    LIMIT 1
    """, [session_id, now_ms])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  @doc """
  Pending periodic tasks with an armed future pickup — re-armed by
  TaskRuntime on boot.
  """
  def fetch_pending_periodic do
    r = query!(Repo, """
    SELECT #{@select_cols}
    FROM tasks
    WHERE task_type='periodic'
      AND task_status='pending'
      AND time_to_pickup IS NOT NULL
    """, [])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  Tasks that were ongoing when the app went down — on boot we revert them
  to pending so the next session turn can pick up where the log left off.
  """
  def fetch_orphaned_ongoing do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE task_status='ongoing'", [])
    Enum.map(r.rows, &row_to_map/1)
  end

  def list_for_session(session_id) do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE session_id=? ORDER BY created_at DESC", [session_id])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc "Active (non-terminal) tasks for a session — used for the [Active tasks] context block."
  def active_for_session(session_id) do
    r = query!(Repo, """
    SELECT #{@select_cols} FROM tasks
    WHERE session_id=? AND task_status IN ('pending', 'ongoing', 'paused')
    ORDER BY created_at ASC
    """, [session_id])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  Recent terminal tasks for a session (done or cancelled), newest first.
  Used to render the flat `### done` sub-section of the task-list block —
  the assistant sees them by id+title only and can call `fetch_task` for
  details (or `update_task(status: "pending")` to redo).
  """
  def recent_done_for_session(session_id, limit \\ 20) do
    r = query!(Repo, """
    SELECT #{@select_cols} FROM tasks
    WHERE session_id=? AND task_status IN ('done', 'cancelled')
    ORDER BY updated_at DESC
    LIMIT ?
    """, [session_id, limit])
    Enum.map(r.rows, &row_to_map/1)
  end

  def delete_for_session(session_id) do
    query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
    :ok
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
    task_status, task_result, time_to_pickup, language, created_at, updated_at
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
      time_to_pickup: time_to_pickup,
      language: language || "en",
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
  end
end
