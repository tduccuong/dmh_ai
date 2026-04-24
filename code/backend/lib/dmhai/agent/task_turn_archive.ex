# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.TaskTurnArchive do
  @moduledoc """
  Per-task, append-only raw archive of messages aged out of the master
  session context by `ContextEngine.compact!` or evicted from
  `tool_history`'s retention window.

  Lets `fetch_task(task_num)` return a verbatim replay of the task's
  prior work regardless of how many unrelated chains (e.g. periodic
  pickups) interleaved in the session. See architecture.md §Task state
  continuity across chains for the full design.

  Write hooks:
    * `ContextEngine.compact!/3` — before summarising the
      `to_summarize` slice, groups its messages by their `task_num`
      tag and calls `append_raw/3` per group.
    * `Dmhai.Agent.ToolHistory` retention — when a turn rolls out of
      the retention window, if the turn was tagged with a `task_num`,
      its `tool_call` / `tool_result` messages are archived here.

  Read hook:
    * `Dmhai.Tools.FetchTask` — `fetch_for_task/1` returns the archive
      chronologically; the tool stitches archive + live session
      messages + live tool_history into one response for the model.

  No summarisation on the archive side; preservation is verbatim. If a
  single task accumulates a very large archive, a future task-scoped
  compaction pass can trim — not needed for v1.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Append a list of messages verbatim to the archive under `task_id`.
  Each message may be either atom-keyed or string-keyed (both shapes
  exist in the codebase — LLM input uses atoms, DB-read uses strings).
  Messages without an `:ts` / `"ts"` are archived with a 0 placeholder
  so ordering still works by insert order.
  """
  @spec append_raw(String.t(), String.t(), [map()]) :: :ok
  def append_raw(task_id, session_id, messages)
      when is_binary(task_id) and is_binary(session_id) and is_list(messages) do
    now = System.os_time(:millisecond)

    try do
      Enum.each(messages, fn msg ->
        role         = msg[:role] || msg["role"]
        content      = msg[:content] || msg["content"]
        tool_calls   = msg[:tool_calls] || msg["tool_calls"]
        tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]
        original_ts  = msg[:ts] || msg["ts"] || 0

        tool_calls_json =
          case tool_calls do
            list when is_list(list) and list != [] -> Jason.encode!(list)
            _                                       -> nil
          end

        query!(Repo, """
        INSERT INTO task_turn_archive
          (task_id, session_id, original_ts, role, content,
           tool_calls, tool_call_id, archived_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [task_id, session_id, original_ts, to_string(role || ""),
              content, tool_calls_json, tool_call_id, now])
      end)

      prune(task_id)
      :ok
    rescue
      e ->
        Logger.error("[TaskTurnArchive] append_raw failed task=#{task_id}: #{Exception.message(e)}")
        :error
    end
  end

  def append_raw(_task_id, _session_id, []), do: :ok
  def append_raw(_task_id, _session_id, _messages), do: :error

  # Sliding-window eviction. After every append we check whether the
  # task's archive exceeds either configured cap (rows OR bytes) and
  # drop the oldest rows until BOTH caps are satisfied. Bytes are
  # measured by SUM(LENGTH(content)) — sum of payloads only. No LLM
  # summarisation; eviction is pure drop.
  defp prune(task_id) do
    row_cap  = Dmhai.Agent.AgentSettings.task_archive_row_cap()
    byte_cap = Dmhai.Agent.AgentSettings.task_archive_byte_cap()

    case fetch_rows_with_bytes(task_id) do
      [] ->
        :ok

      rows ->
        to_keep = pick_to_keep(rows, row_cap, byte_cap)
        delete_old(task_id, to_keep)
    end
  rescue
    e -> Logger.warning("[TaskTurnArchive] prune failed task=#{task_id}: #{Exception.message(e)}")
  end

  # Rows sorted newest → oldest with their content byte size.
  defp fetch_rows_with_bytes(task_id) do
    %{rows: rows} = query!(Repo, """
    SELECT id, COALESCE(LENGTH(content), 0)
      FROM task_turn_archive
     WHERE task_id=?
     ORDER BY id DESC
    """, [task_id])

    Enum.map(rows, fn [id, bytes] -> {id, bytes || 0} end)
  end

  # Greedily keep newest rows until either cap is reached. Returns the
  # list of ids to keep. Everything older is deleted.
  defp pick_to_keep(rows, row_cap, byte_cap) do
    rows
    |> Enum.reduce_while({[], 0, 0}, fn {id, bytes}, {kept, kept_count, kept_bytes} ->
      new_count = kept_count + 1
      new_bytes = kept_bytes + bytes

      cond do
        new_count > row_cap   -> {:halt, {kept, kept_count, kept_bytes}}
        new_bytes > byte_cap and kept_count > 0 -> {:halt, {kept, kept_count, kept_bytes}}
        true -> {:cont, {[id | kept], new_count, new_bytes}}
      end
    end)
    |> elem(0)
  end

  defp delete_old(_task_id, []), do: :ok
  defp delete_old(task_id, to_keep) do
    # Delete every row for this task whose id is NOT in `to_keep`.
    # SQLite doesn't love giant IN-lists for huge archives but we've
    # capped to ≤ row_cap entries retained, so the list stays bounded.
    min_keep = Enum.min(to_keep)

    query!(Repo,
      "DELETE FROM task_turn_archive WHERE task_id=? AND id < ?",
      [task_id, min_keep])

    :ok
  end

  @doc """
  Fetch all archived entries for a task in chronological order
  (`original_ts` ASC). Returns a list of message maps shaped to match
  the LLM-context layout:

      %{role, content, ts, tool_calls?, tool_call_id?}

  so the caller can concatenate with live messages and pass the whole
  thing back to the model as-is.
  """
  @spec fetch_for_task(String.t()) :: [map()]
  def fetch_for_task(task_id) when is_binary(task_id) do
    try do
      %{rows: rows} = query!(Repo, """
      SELECT role, content, tool_calls, tool_call_id, original_ts
        FROM task_turn_archive
       WHERE task_id=?
       ORDER BY original_ts ASC, id ASC
      """, [task_id])

      Enum.map(rows, fn [role, content, tool_calls_json, tool_call_id, ts] ->
        base = %{role: role, content: content, ts: ts}

        base =
          case tool_calls_json do
            s when is_binary(s) and s != "" ->
              Map.put(base, :tool_calls, safe_decode(s))
            _ ->
              base
          end

        if is_binary(tool_call_id) and tool_call_id != "" do
          Map.put(base, :tool_call_id, tool_call_id)
        else
          base
        end
      end)
    rescue
      e ->
        Logger.error("[TaskTurnArchive] fetch_for_task failed task=#{task_id}: #{Exception.message(e)}")
        []
    end
  end

  @doc """
  Return the latest `original_ts` across all archive rows for a task,
  or 0 if the archive is empty. Used by `fetch_task` to filter live
  session messages (take only those with ts > floor) so archive and
  live don't overlap.
  """
  @spec latest_archived_ts(String.t()) :: integer()
  def latest_archived_ts(task_id) when is_binary(task_id) do
    case query!(Repo,
           "SELECT COALESCE(MAX(original_ts), 0) FROM task_turn_archive WHERE task_id=?",
           [task_id]) do
      %{rows: [[n]]} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp safe_decode(json) do
    case Jason.decode(json) do
      {:ok, v} -> v
      _        -> []
    end
  end
end
