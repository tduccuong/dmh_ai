# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.SessionProgress do
  @moduledoc """
  DB helpers for the `session_progress` table — per-session activity log
  emitted by the Assistant session loop during task execution.

  Rows are written by the session turn (not by the LLM) and rendered in
  the chat window chronologically with subtle styling. They are **never**
  injected into the LLM's context — `session.messages` is the authoritative
  chat log; this table is pure UI + audit.

  kinds:
    - 'tool'     — one row per tool invocation. Written with status='pending'
                   before execution, mutated to status='done' after. label
                   is a one-line "<tool>(<args_preview>)".
    - 'thinking' — model-provided reasoning excerpt.
    - 'summary'  — on-demand status summary (from the summariser called by
                   the session loop when the user asks for a status check).

  ctx shape:
      %{
        session_id: String.t(),
        user_id:    String.t(),
        task_id:    String.t() | nil   # nil for direct-response turns
      }
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @max_label_chars 4_000

  @doc """
  Insert a progress row. Returns `{:ok, row}` where `row` is the map the
  FE will receive over the SSE `{"progress": ...}` frame (id, kind, status,
  label, task_id, ts). Callers use `row.id` later with `mark_tool_done/1`
  to flip a pending tool row to done.

  opts:
    - `:status` — 'pending' | 'done' (tool rows only)
  """
  @spec append(map(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def append(ctx, kind, label, opts \\ []) do
    status = Keyword.get(opts, :status)
    now    = System.os_time(:millisecond)

    session_id = ctx[:session_id] || ctx["session_id"]
    user_id    = ctx[:user_id]    || ctx["user_id"]
    task_id    = ctx[:task_id]    || ctx["task_id"]
    stored_label = truncate(label)

    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO session_progress
        (session_id, user_id, task_id, kind, status, label, ts)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      RETURNING id
      """, [session_id, user_id, task_id, kind, status, stored_label, now])

    {:ok,
     %{
       id: id,
       session_id: session_id,
       user_id: user_id,
       task_id: task_id,
       kind: kind,
       status: status,
       label: stored_label,
       ts: now
     }}
  end

  @doc "Convenience: write a 'tool' row with status='pending'. Returns {:ok, row}."
  @spec append_tool_pending(map(), String.t()) :: {:ok, map()}
  def append_tool_pending(ctx, label),
    do: append(ctx, "tool", label, status: "pending")

  @doc """
  Flip a tool row (previously appended with status='pending') to status='done'.
  The row's original `ts` is preserved — it represents chronological position
  in the chat timeline. The flip is an in-place mutation, not a new row.
  """
  @spec mark_tool_done(integer()) :: :ok
  def mark_tool_done(id) when is_integer(id) do
    query!(Repo, "UPDATE session_progress SET status='done' WHERE id=?", [id])
    :ok
  end

  @doc "Convenience: write a 'thinking' row."
  @spec append_thinking(map(), String.t()) :: {:ok, integer()}
  def append_thinking(ctx, label), do: append(ctx, "thinking", label)

  @doc "Convenience: write a 'summary' row (from the on-demand summariser)."
  @spec append_summary(map(), String.t()) :: {:ok, integer()}
  def append_summary(ctx, label), do: append(ctx, "summary", label)

  @doc """
  Fetch all rows for a task, ordered by id ASC. Used by the on-demand
  summariser to read the task's activity log.
  """
  @spec fetch_for_task(String.t()) :: [map()]
  def fetch_for_task(task_id) do
    r = query!(Repo, """
    SELECT id, session_id, user_id, task_id, kind, status, label, ts
    FROM session_progress
    WHERE task_id=?
    ORDER BY id ASC
    """, [task_id])

    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  FE cursor: fetch all progress rows for a session after a given integer id.
  Client polls with `since` = id of the last row it rendered.
  """
  @spec fetch_for_session(String.t(), integer()) :: [map()]
  def fetch_for_session(session_id, since_id \\ 0) do
    r = query!(Repo, """
    SELECT id, session_id, user_id, task_id, kind, status, label, ts
    FROM session_progress
    WHERE session_id=? AND id > ?
    ORDER BY id ASC
    """, [session_id, since_id])

    Enum.map(r.rows, &row_to_map/1)
  end

  # Cap stored label so a single runaway tool output can't blow up the DB.
  defp truncate(nil), do: nil
  defp truncate(content) when is_binary(content) do
    if String.length(content) > @max_label_chars do
      String.slice(content, 0, @max_label_chars) <> " … [truncated]"
    else
      content
    end
  end
  defp truncate(other), do: inspect(other)

  defp row_to_map([id, session_id, user_id, task_id, kind, status, label, ts]) do
    %{
      id: id,
      session_id: session_id,
      user_id: user_id,
      task_id: task_id,
      kind: kind,
      status: status,
      label: label,
      ts: ts
    }
  end
end
