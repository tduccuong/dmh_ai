# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.WorkerStatus do
  @moduledoc """
  DB helpers for the `worker_status` table — per-iteration progress
  rows written by the worker. The runtime scheduler polls this via a
  per-job cursor stored on the jobs row (`last_reported_status_id`).

  kinds:
    - 'thinking'    — model-provided reasoning text
    - 'tool_call'   — one row per tool call about to execute, content = "<name>(<args>)"
    - 'tool_result' — tool execution result (short preview)
    - 'final'       — signal(JOB_DONE|BLOCKED) terminal row
    - 'error'       — runtime-synthesized error (crash / orphaned detection)
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  def append(job_id, worker_id, kind, content, signal_status \\ nil) do
    now = System.os_time(:millisecond)
    content = truncate_content(content)

    query!(Repo, """
    INSERT INTO worker_status (job_id, worker_id, kind, content, signal_status, ts)
    VALUES (?, ?, ?, ?, ?, ?)
    """, [job_id, worker_id, kind, content, signal_status, now])
    :ok
  end

  def fetch_since(job_id, after_id) do
    r = query!(Repo, """
    SELECT id, job_id, worker_id, kind, content, signal_status, ts
    FROM worker_status
    WHERE job_id=? AND id > ?
    ORDER BY id ASC
    """, [job_id, after_id || 0])

    Enum.map(r.rows, &row_to_map/1)
  end

  def latest_final(job_id) do
    r = query!(Repo, """
    SELECT id, job_id, worker_id, kind, content, signal_status, ts
    FROM worker_status
    WHERE job_id=? AND kind='final'
    ORDER BY id DESC LIMIT 1
    """, [job_id])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  def list_recent(job_id, limit \\ 50) do
    r = query!(Repo, """
    SELECT id, job_id, worker_id, kind, content, signal_status, ts
    FROM worker_status
    WHERE job_id=?
    ORDER BY id DESC LIMIT ?
    """, [job_id, limit])

    r.rows |> Enum.map(&row_to_map/1) |> Enum.reverse()
  end

  # Cap stored content so a single runaway tool output can't blow up the DB.
  @max_content_chars 4_000
  defp truncate_content(nil), do: nil
  defp truncate_content(content) when is_binary(content) do
    if String.length(content) > @max_content_chars do
      String.slice(content, 0, @max_content_chars) <> " … [truncated]"
    else
      content
    end
  end
  defp truncate_content(other), do: inspect(other)

  defp row_to_map([id, job_id, worker_id, kind, content, signal_status, ts]) do
    %{
      id: id, job_id: job_id, worker_id: worker_id,
      kind: kind, content: content, signal_status: signal_status, ts: ts
    }
  end
end
