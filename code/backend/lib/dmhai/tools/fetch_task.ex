# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.FetchTask do
  @moduledoc """
  Stitched, resume-friendly view of a task. Returns metadata plus a
  chronological replay of the task's prior work, assembled from three
  sources (see architecture.md §Task state continuity across chains):

    1. **archive** — verbatim turns in `task_turn_archive`, written when
       `ContextEngine.compact!` summarised the oldest slice of
       `session.messages` or when `tool_history` retention evicted
       chains tagged with this task_num. Survives compaction.
    2. **live** — current `session.messages` entries tagged with this
       task's `task_num`, with `ts > latest_archived_ts` so archive
       and live don't overlap.
    3. **tool_bodies** — `tool_history` entries still in the retention
       window, tagged with this task_num. Give the model its own prior
       tool outputs verbatim.

  Takes `task_num: integer`.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.{ContextEngine, SessionProgress, Tasks, TaskTurnArchive, ToolHistory, UserAgentMessages}

  # Cap for the session_progress activity-log tail (preserved label +
  # status; raw content lives in tool_bodies).
  @activity_tail_limit 20

  # Cap for each content-bearing field to prevent the tool_result from
  # exploding the next LLM call's context.
  @content_preview_chars 600

  @impl true
  def name, do: "fetch_task"

  @impl true
  def description,
    do:
      "Load a task's full context — metadata, attachments, prior " <>
        "conversation (both archived from earlier chains and currently live), " <>
        "and prior tool outputs. Use when the anchor named a task whose " <>
        "details aren't in your current context (e.g. after many periodic " <>
        "pickups interleaved), OR when you need to recall what a done task " <>
        "produced before deciding whether to redo it."

  @impl true
  def execute(args, ctx) do
    task_num   = coerce_num(args["task_num"])
    session_id = Map.get(ctx, :session_id)

    with :ok <- require_num(task_num),
         :ok <- require_session(session_id),
         {:ok, task_id} <- Tasks.resolve_num(session_id, task_num),
         %{} = task     <- Tasks.get(task_id) do
      archive           = TaskTurnArchive.fetch_for_task(task_id)
      latest_archive_ts = TaskTurnArchive.latest_archived_ts(task_id)

      live_conv = UserAgentMessages.messages_for_task_num(session_id, task_num, latest_archive_ts)
      tool_bodies = ToolHistory.load_for_task_num(session_id, task_num)

      activity =
        task_id
        |> SessionProgress.fetch_for_task()
        |> Enum.take(-@activity_tail_limit)
        |> Enum.map(fn r ->
          %{kind: r.kind, status: r.status, label: r.label, ts: r.ts}
        end)

      {:ok,
       %{
         task_num:      task_num,
         task_title:    task.task_title,
         task_type:     task.task_type,
         intvl_sec:     task.intvl_sec,
         task_status:   task.task_status,
         task_spec:     task.task_spec,
         task_result:   task.task_result,
         time_to_pickup: task.time_to_pickup,
         language:      task.language,
         attachments:   task_attachments(task),
         created_at:    task.created_at,
         updated_at:    task.updated_at,
         activity_log:  activity,
         archive:       truncate_msgs(archive),
         live:          truncate_msgs(live_conv),
         tool_bodies:   tool_bodies
       }}
    else
      {:error, :not_found} ->
        {:error, "fetch_task: no task (#{task_num}) exists in this session."}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, "fetch_task: internal lookup failed for task (#{task_num})"}
    end
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          task_num: %{
            type: "integer",
            description: "The per-session task number `(N)` to fetch."
          }
        },
        required: ["task_num"]
      }
    }
  end

  # ── private ────────────────────────────────────────────────────────

  defp coerce_num(n) when is_integer(n), do: n
  defp coerce_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _        -> nil
    end
  end
  defp coerce_num(_), do: nil

  defp require_num(n) when is_integer(n) and n > 0, do: :ok
  defp require_num(_), do: {:error, "fetch_task requires a positive integer `task_num`"}

  defp require_session(sid) when is_binary(sid) and sid != "", do: :ok
  defp require_session(_), do: {:error, "fetch_task called without a session context"}

  # Structured attachments column is authoritative. Fall back to a
  # regex parse of task_spec when the column is empty.
  defp task_attachments(task) do
    case Map.get(task, :attachments) do
      list when is_list(list) and list != [] -> list
      _                                       -> ContextEngine.extract_attachments(task.task_spec)
    end
  end

  # Cap each message's `content` to keep the stitched response from
  # exploding. Preview length intentionally generous for user/assistant
  # narration; tool bodies have their own retention logic upstream.
  defp truncate_msgs(msgs) when is_list(msgs) do
    Enum.map(msgs, fn m ->
      case m[:content] || m["content"] do
        s when is_binary(s) and byte_size(s) > @content_preview_chars ->
          Map.put(m, :content, String.slice(s, 0, @content_preview_chars) <> "…")
        _ ->
          m
      end
    end)
  end
  defp truncate_msgs(_), do: []
end
