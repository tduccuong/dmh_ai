# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.FetchTask do
  @moduledoc """
  Fetch full details for a task — description, status, result, attachments,
  and the tail of its activity log.

  Used when the Task-list block's summary isn't enough (e.g. the user asks
  "what was task X about?", or the assistant wants to inspect a done task
  before deciding whether to redo it).
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.{ContextEngine, SessionProgress, Tasks}

  @activity_tail_limit 20

  @impl true
  def name, do: "fetch_task"

  @impl true
  def description,
    do:
      "Fetch full details for a task by id — description, status, result, " <>
        "attachments, and the last #{@activity_tail_limit} activity-log " <>
        "entries. Use when the Task-list block's summary isn't enough " <>
        "(e.g. user asks 'what was task X about?', or you want to see " <>
        "what a done task produced before redoing it)."

  @impl true
  def execute(%{"task_id" => tid}, _ctx) when is_binary(tid) and tid != "" do
    case Tasks.get(tid) do
      nil ->
        {:error, "fetch_task: no task with task_id=#{inspect(tid)}"}

      task ->
        activity =
          tid
          |> SessionProgress.fetch_for_task()
          |> Enum.take(-@activity_tail_limit)
          |> Enum.map(fn r ->
            %{kind: r.kind, status: r.status, label: r.label, ts: r.ts}
          end)

        {:ok,
         %{
           task_id:        task.task_id,
           task_title:     task.task_title,
           task_type:      task.task_type,
           intvl_sec:      task.intvl_sec,
           task_status:    task.task_status,
           task_spec:      task.task_spec,
           task_result:    task.task_result,
           time_to_pickup: task.time_to_pickup,
           language:       task.language,
           attachments:    task_attachments(task),
           created_at:     task.created_at,
           updated_at:     task.updated_at,
           recent_activity: activity
         }}
    end
  end

  def execute(_args, _ctx), do: {:error, "fetch_task requires a non-empty 'task_id' argument"}

  # Structured attachments column is authoritative. Legacy rows
  # (pre-migration) fall back to regex-parsed-from-spec so existing
  # tasks keep working during the transition.
  defp task_attachments(task) do
    case Map.get(task, :attachments) do
      list when is_list(list) and list != [] -> list
      _                                       -> ContextEngine.extract_attachments(task.task_spec)
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
          task_id: %{type: "string", description: "The task_id to fetch."}
        },
        required: ["task_id"]
      }
    }
  end
end
