# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Tasks do
  @moduledoc """
  DB helpers for the `tasks` table — per-session record of assistant tasks
  (one_off or periodic). Rows are created by the assistant via
  `create_task` and mutated via the verb API (`pickup_task`,
  `complete_task`, `pause_task`, `cancel_task`) as the session loop runs.

  `Tasks.mark_done/2` is the **single rescheduling path** for periodic
  tasks: on done it auto-reschedules (status=pending, time_to_pickup
  bumped) and arms a TaskRuntime timer. The session loop does not need to
  think about rescheduling separately.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @select_cols """
  task_id, user_id, session_id, task_num, task_type, intvl_sec, task_title,
  task_spec, task_status, task_result, time_to_pickup,
  language, attachments, back_to_when_done_task_num, created_at, updated_at
  """

  @doc """
  Insert a fresh task row. Returns the task_id.
  One_off: time_to_pickup defaults to now (immediate pickup).
  Periodic: time_to_pickup defaults to now (first cycle is immediate).
  `task_num` is a per-session monotonic integer starting at 1, used as
  the user-visible "(N)" label in the task sidebar and task-list block.
  """
  def insert(attrs) do
    task_id   = attrs[:task_id] || generate_id()
    session_id = attrs[:session_id]
    now       = System.os_time(:millisecond)
    task_num  = next_task_num(session_id)

    attachments_json = encode_attachments(attrs[:attachments])

    query!(Repo, """
    INSERT INTO tasks (task_id, user_id, session_id, task_num, task_type, intvl_sec,
                       task_title, task_spec, task_status, time_to_pickup,
                       language, attachments, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      task_id,
      attrs[:user_id],
      session_id,
      task_num,
      attrs[:task_type] || "one_off",
      attrs[:intvl_sec] || 0,
      attrs[:task_title] || "",
      attrs[:task_spec] || "",
      attrs[:task_status] || "pending",
      attrs[:time_to_pickup] || now,
      attrs[:language] || "en",
      attachments_json,
      now, now
    ])

    task_id
  end

  @doc "Replace a task's attachments (JSON array on disk)."
  def update_attachments(task_id, attachments) when is_list(attachments) do
    now = System.os_time(:millisecond)
    query!(Repo, "UPDATE tasks SET attachments=?, updated_at=? WHERE task_id=?",
           [encode_attachments(attachments), now, task_id])
    :ok
  end

  # Accepts a list of validated path strings → JSON. `nil` / non-list →
  # stored as NULL so we can cleanly distinguish "no attachments set"
  # from "explicitly empty".
  defp encode_attachments(list) when is_list(list) and list != [], do: Jason.encode!(list)
  defp encode_attachments([]), do: Jason.encode!([])
  defp encode_attachments(_), do: nil

  # Next per-session task_num = max(existing) + 1, starting at 1. Gaps
  # from deleted rows are accepted — numbering is stable per row, so
  # (1), (2), (4) after a delete of (3) is fine; less surprising to the
  # user than renumbering on the fly.
  defp next_task_num(nil), do: 1
  defp next_task_num(session_id) do
    r = query!(Repo,
      "SELECT COALESCE(MAX(task_num), 0) + 1 FROM tasks WHERE session_id=?",
      [session_id])
    case r.rows do
      [[n]] when is_integer(n) -> n
      _ -> 1
    end
  end

  def get(task_id) do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE task_id=?", [task_id])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  @doc """
  Look up a task by `(session_id, task_num)` — the user- and model-facing
  `(N)` pair. Returns the task map or `nil`. Used at the tool-handler
  boundary to translate the integer `task_num` verbs take in their
  schema into the cryptic `task_id` the rest of the BE uses internally.
  See architecture.md §Task lifecycle §Identity.
  """
  @spec lookup_by_num(String.t(), integer()) :: map() | nil
  def lookup_by_num(session_id, task_num) when is_binary(session_id) and is_integer(task_num) do
    r = query!(Repo,
      "SELECT #{@select_cols} FROM tasks WHERE session_id=? AND task_num=?",
      [session_id, task_num])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end
  def lookup_by_num(_, _), do: nil

  @doc """
  Resolve `(session_id, task_num)` to its internal `task_id`. Returns
  `{:ok, task_id}` or `{:error, :not_found}`. Preferred over
  `lookup_by_num/2` at tool-handler entries that only need the id to
  pass to other Tasks/* functions.
  """
  @spec resolve_num(String.t(), integer()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve_num(session_id, task_num) do
    case lookup_by_num(session_id, task_num) do
      nil               -> {:error, :not_found}
      %{task_id: tid}   -> {:ok, tid}
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
        # Periodic re-arm is not a terminal transition — keep any
        # MCP services attached so the next firing reuses them.
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

        # Terminal: drop every MCP service attachment so the per-turn
        # tool catalog reverts on the next chain.
        Dmhai.MCP.Registry.detach_all_for_task(task_id)
    end

    # Flush this task's entries from the rolling tool_history window
    # into task_turn_archive — completed work stops paying LLM
    # context-rent on subsequent chains. fetch_task(N) still
    # surfaces the data from the archive when needed. See
    # architecture.md §Tool-result retention.
    if task do
      Dmhai.Agent.ToolHistory.flush_for_task(task.session_id, task.task_num)
    end
  end

  def mark_cancelled(task_id, task_result \\ nil) do
    task = get(task_id)
    now  = System.os_time(:millisecond)

    if is_binary(task_result) and task_result != "" do
      query!(Repo, """
      UPDATE tasks SET task_status='cancelled',
                      task_result=?,
                      time_to_pickup=NULL,
                      updated_at=?
      WHERE task_id=?
      """, [task_result, now, task_id])
    else
      query!(Repo, """
      UPDATE tasks SET task_status='cancelled',
                      time_to_pickup=NULL,
                      updated_at=?
      WHERE task_id=?
      """, [now, task_id])
    end

    Dmhai.Agent.TaskRuntime.cancel_pickup(task_id)

    # Terminal: drop every MCP service attachment for this task so
    # the per-turn tool catalog reverts on the next chain.
    Dmhai.MCP.Registry.detach_all_for_task(task_id)

    # Flush this task's tool_history entries into task_turn_archive
    # so the cancelled task stops shipping its tool results to the
    # LLM on subsequent chains. See architecture.md §Tool-result retention.
    if task do
      Dmhai.Agent.ToolHistory.flush_for_task(task.session_id, task.task_num)
    end
  end

  def mark_paused(task_id) do
    task = get(task_id)
    now  = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET task_status='paused',
                    updated_at=?
    WHERE task_id=?
    """, [now, task_id])
    Dmhai.Agent.TaskRuntime.cancel_pickup(task_id)

    # Flush this task's tool_history entries into task_turn_archive
    # so a paused task stops shipping its tool results to the LLM
    # on every subsequent chain. fetch_task(N) recovers them on
    # resume. See architecture.md §Tool-result retention.
    if task do
      Dmhai.Agent.ToolHistory.flush_for_task(task.session_id, task.task_num)
    end
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
  def update_title(task_id, new_title) when is_binary(new_title) and new_title != "" do
    now = System.os_time(:millisecond)
    query!(Repo, "UPDATE tasks SET task_title=?, updated_at=? WHERE task_id=?",
           [new_title, now, task_id])
    :ok
  end

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
  True when the session has at least one periodic task armed for a
  FUTURE pickup. Unlike `fetch_next_due/2` (which filters to
  `time_to_pickup <= now`), this returns true even during the 28-second
  "between-firings" lull of a 30s periodic cycle. Drives the
  `is_working` flag in `/sessions/:id/poll` so the FE keeps the fast
  500 ms poll cadence while a periodic is in rotation — otherwise it
  falls back to the 5 s idle cadence, adding up to 5 s of lag between
  a joke landing in the DB and the user seeing it.
  """
  @spec has_pending_periodic_for_session(String.t()) :: boolean()
  def has_pending_periodic_for_session(session_id) when is_binary(session_id) do
    r = query!(Repo, """
    SELECT 1
    FROM tasks
    WHERE session_id=?
      AND task_type='periodic'
      AND task_status='pending'
      AND time_to_pickup IS NOT NULL
    LIMIT 1
    """, [session_id])
    r.rows != []
  end

  @doc """
  Return the single ACTIVE periodic task for a session (non-terminal —
  `pending` | `ongoing` | `paused`), or `nil` if none exists. "Active"
  here is broader than `has_pending_periodic_for_session/1`'s "armed for
  future pickup" check: we also count an `ongoing` periodic (a pickup
  currently mid-turn) and a `paused` one (explicitly suspended by the
  user), because the one-periodic-per-session policy must hold
  regardless of which active state the existing task is in.

  Used by the Police single-periodic gate to produce a nudge that
  names `(task_num)` + `task_title` of the existing task, so the model
  can relay that to the user verbatim ("we already have task (N) …").

  Returns the first match by `created_at ASC` so the "existing" task is
  the oldest surviving one — stable across repeated polls.
  """
  @spec session_active_periodic(String.t()) :: map() | nil
  def session_active_periodic(session_id) when is_binary(session_id) do
    r = query!(Repo, """
    SELECT #{@select_cols}
    FROM tasks
    WHERE session_id=?
      AND task_type='periodic'
      AND task_status IN ('pending', 'ongoing', 'paused')
    ORDER BY created_at ASC
    LIMIT 1
    """, [session_id])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  @doc """
  Tasks that were ongoing when the app went down — on boot we revert them
  to pending so the next session turn can pick up where the log left off.
  """
  def fetch_orphaned_ongoing do
    r = query!(Repo, "SELECT #{@select_cols} FROM tasks WHERE task_status='ongoing'", [])
    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  Subset of `fetch_orphaned_ongoing/0` scoped to periodic tasks only.
  Used by `TaskRuntime.rehydrate/0` — periodic ongoing tasks MUST be
  reverted at boot because their cycle's `complete_task` didn't fire,
  but one_off ongoing tasks can legitimately persist across restarts
  (the assistant may have ended a chain with a clarifying question
  and is waiting for the user's reply). See architecture.md §Boot
  rehydration.
  """
  def fetch_orphaned_ongoing_periodic do
    r = query!(Repo,
      "SELECT #{@select_cols} FROM tasks WHERE task_status='ongoing' AND task_type='periodic'",
      [])
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
  details (or `pickup_task(task_id)` to reopen a done task for rework).
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

  @doc """
  Set the anchor back-reference on a task — "when I (this task)
  complete/cancel/pause, the chain's runtime anchor returns to
  `back_num`." Called at `pickup_task` time when the incoming pickup's
  task differs from the previous anchor.

  Idempotent: passing the same value leaves the row unchanged (just
  bumps `updated_at`). Passing `nil` clears any existing back-ref
  (useful at `complete_task` time to avoid stale references on
  subsequent re-pickups).
  """
  @spec set_back_ref(String.t(), integer() | nil) :: :ok
  def set_back_ref(task_id, back_num) when is_binary(task_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE tasks SET back_to_when_done_task_num=?, updated_at=?
    WHERE task_id=?
    """, [back_num, now, task_id])
    :ok
  end

  @doc """
  Return true if ANY periodic task in this session is currently in
  `ongoing` status. Used by `TaskRuntime` to gate periodic pickup
  firings: if a periodic is already running (prior cycle hasn't
  closed), skip the new timer — prevents overlapping periodic silent
  chains in the same session. See architecture.md §Scheduler — don't
  stack periodic pickups.
  """
  @spec session_has_ongoing_periodic?(String.t()) :: boolean()
  def session_has_ongoing_periodic?(session_id) do
    r = query!(Repo, """
    SELECT COUNT(*) FROM tasks
    WHERE session_id=? AND task_type='periodic' AND task_status='ongoing'
    """, [session_id])

    case r.rows do
      [[n]] when is_integer(n) -> n > 0
      _ -> false
    end
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
    task_id, user_id, session_id, task_num, task_type, intvl_sec, task_title, task_spec,
    task_status, task_result, time_to_pickup, language, attachments_json,
    back_to_when_done_task_num, created_at, updated_at
  ]) do
    %{
      task_id: task_id,
      user_id: user_id,
      session_id: session_id,
      task_num: task_num,
      task_type: task_type,
      intvl_sec: intvl_sec,
      task_title: task_title,
      task_spec: task_spec,
      task_status: task_status,
      task_result: task_result,
      time_to_pickup: time_to_pickup,
      language: language || "en",
      attachments: decode_attachments(attachments_json),
      back_to_when_done_task_num: back_to_when_done_task_num,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  # Decode the JSON array column. `nil` / empty / malformed JSON all
  # return `[]` — never crash the caller.
  defp decode_attachments(nil), do: []
  defp decode_attachments(""),  do: []
  defp decode_attachments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
  defp decode_attachments(_), do: []

  defp generate_id do
    :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
  end
end
