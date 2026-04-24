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
  FE would receive over the poll delta (id, kind, status, label, task_id,
  ts). Callers use `row.id` later with `mark_tool_done/1` to flip a
  pending tool row to done.

  opts:
    - `:status` — 'pending' | 'done' (tool rows only)
    - `:hidden` — when true, row is persisted but filtered out of
                   `fetch_for_session/2`. Use for internal-only rows
                   (Police rejections, routine cleanup flips) that the
                   user shouldn't see in their chat timeline.
  """
  @spec append(map(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def append(ctx, kind, label, opts \\ []) do
    status = Keyword.get(opts, :status)
    hidden = if Keyword.get(opts, :hidden, false), do: 1, else: 0
    now    = System.os_time(:millisecond)

    session_id = ctx[:session_id] || ctx["session_id"]
    user_id    = ctx[:user_id]    || ctx["user_id"]
    task_id    = ctx[:task_id]    || ctx["task_id"]
    stored_label = truncate(label)

    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO session_progress
        (session_id, user_id, task_id, kind, status, label, hidden, ts)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      RETURNING id
      """, [session_id, user_id, task_id, kind, status, stored_label, hidden, now])

    {:ok,
     %{
       id: id,
       session_id: session_id,
       user_id: user_id,
       task_id: task_id,
       kind: kind,
       status: status,
       label: stored_label,
       hidden: hidden == 1,
       ts: now
     }}
  end

  @doc "Convenience: write a 'tool' row with status='pending'. Returns {:ok, row}."
  @spec append_tool_pending(map(), String.t()) :: {:ok, map()}
  def append_tool_pending(ctx, label),
    do: append(ctx, "tool", label, status: "pending")

  @doc """
  Flip a tool row (appended with status='pending') to status='done'.
  The row's original `ts` is preserved — it represents chronological position
  in the chat timeline. The flip is an in-place mutation, not a new row.
  """
  @spec mark_tool_done(integer()) :: :ok
  def mark_tool_done(id) when is_integer(id) do
    query!(Repo, "UPDATE session_progress SET status='done' WHERE id=?", [id])
    :ok
  end

  @doc """
  Remove a progress row. Used when a tool call returned `{:error, ...}`
  (e.g. validation guard, Police rejection) so the rejected attempt
  doesn't leave a ghost row in the chat timeline — the model's retry
  produces a fresh row that will end up as the only visible entry.
  """
  @spec delete(integer()) :: :ok
  def delete(id) when is_integer(id) do
    query!(Repo, "DELETE FROM session_progress WHERE id=?", [id])
    :ok
  end

  @doc """
  Delete every row still in `status='pending'` for a given session.
  Called from `UserAgent.cancel_current_task/1` after `Process.exit(:kill)`
  so zombie rows don't persist — the killed task can't run its own
  `mark_tool_done` / `delete` cleanup in `execute_tools`, which leaves
  the row forever at `status='pending'` in the DB. `fetch_for_session/2`
  re-returns every pending row on every poll (for live sub_label
  updates on in-flight tools), so leaving zombies keeps the FE rotating
  through a dead tool's URLs indefinitely.

  Returns `:ok` regardless of how many rows were affected.
  """
  @spec delete_pending_for_session(String.t()) :: :ok
  def delete_pending_for_session(session_id) when is_binary(session_id) do
    query!(Repo,
      "DELETE FROM session_progress WHERE session_id=? AND status='pending'",
      [session_id])
    :ok
  end

  # Cap the sub_labels array so a long-running tool can't grow it without
  # bound. Each new append also trims the head; FE renders round-robin so
  # the oldest entries fall off naturally.
  @sub_labels_cap 20

  @doc """
  Append a label to the `sub_labels` JSON array of a pending tool row.
  Used by tools whose execution has parallel or multi-step internals
  (web_search's SearXNG fan-out, URL fetches, JinaReader fallback; OCR
  chunk calls) — gives the FE enough signal to rotate a lively indicator
  while the tool is running. No-op when `id` is nil (caller has no row).

  Atomic via SQLite's `json_insert` — safe when called concurrently by
  parallel fetch tasks. Trims to the last `@sub_labels_cap` entries.
  """
  @spec append_sub_label(integer() | nil, String.t()) :: :ok
  def append_sub_label(nil, _label), do: :ok
  def append_sub_label(id, label) when is_integer(id) and is_binary(label) do
    try do
      # json_insert appends at '$[#]'; then extract last @sub_labels_cap elements
      # via a bounded slice. SQLite's json() functions are transaction-safe so
      # concurrent callers never lose appends.
      query!(Repo, """
      UPDATE session_progress
      SET sub_labels = (
        SELECT CASE
          WHEN json_array_length(arr) <= ? THEN arr
          ELSE (
            SELECT json_group_array(value)
            FROM json_each(arr)
            WHERE json_each.key >= json_array_length(arr) - ?
          )
        END
        FROM (SELECT json_insert(COALESCE(sub_labels, '[]'), '$[#]', ?) AS arr)
      )
      WHERE id = ?
      """, [@sub_labels_cap, @sub_labels_cap, label, id])
    rescue
      e -> require Logger; Logger.warning("[SessionProgress] append_sub_label failed: #{Exception.message(e)}")
    end
    :ok
  end
  def append_sub_label(_, _), do: :ok

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
    SELECT id, session_id, user_id, task_id, kind, status, label, sub_labels, ts
    FROM session_progress
    WHERE task_id=?
    ORDER BY id ASC
    """, [task_id])

    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  FE cursor: fetch all progress rows for a session after a given integer id.
  Client polls with `since` = id of the last row it rendered.

  Rows with `hidden = 1` are filtered out here so the FE timeline never
  shows them. They're still in the DB (admin / audit can reach them via
  direct SQL).
  """
  @spec fetch_for_session(String.t(), integer()) :: [map()]
  def fetch_for_session(session_id, since_id \\ 0) do
    # Returns:
    #   - rows with id > since_id (standard delta-load cursor), PLUS
    #   - any row still in status='pending' regardless of id, so the FE
    #     picks up sub_labels appended to an already-rendered pending tool
    #     row (e.g. web_search's parallel fetches emit sub-activity after
    #     the row was first seen).
    # The FE upserts by id, so re-returning a pending row is harmless —
    # it just refreshes sub_labels on the existing cached entry.
    r = query!(Repo, """
    SELECT id, session_id, user_id, task_id, kind, status, label, sub_labels, ts
    FROM session_progress
    WHERE session_id=? AND hidden = 0
      AND (id > ? OR status='pending')
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

  defp row_to_map([id, session_id, user_id, task_id, kind, status, label, sub_labels_json, ts]) do
    sub_labels =
      case sub_labels_json do
        nil  -> []
        ""   -> []
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, list} when is_list(list) -> list
            _                               -> []
          end
      end

    %{
      id: id,
      session_id: session_id,
      user_id: user_id,
      task_id: task_id,
      kind: kind,
      status: status,
      label: label,
      sub_labels: sub_labels,
      ts: ts
    }
  end
end
