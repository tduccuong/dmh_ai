# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.CompleteTask do
  @moduledoc """
  Close a task with a result summary.

    * `one_off` → status flips to `done`, `time_to_pickup` cleared.
    * `periodic` → status flips to `pending`, `time_to_pickup = now +
      intvl_sec`, `TaskRuntime.schedule_pickup` re-arms the next cycle's
      timer. For periodics, "complete" means "this pickup is complete;
      reschedule the next one."

  Optional `task_title` refines the stored title at close — lets the
  model replace the vague creation-time title ("Research X") with a
  concrete outcome-focused summary ("Found 3 candidates with quote
  comparison").

  Takes `task_num: integer`. BE resolves via `Tasks.resolve_num/2`.
  See architecture.md §Task lifecycle §Identity.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Tasks
  require Logger

  @impl true
  def name, do: "complete_task"

  @impl true
  def description,
    do:
      "Close a task with its final result. one_off → 'done' terminally. " <>
        "periodic → reschedules next pickup. Required: `task_result` " <>
        "(one-line for sidebar). Optional: `task_title` (refine on close)."

  @impl true
  def execute(args, ctx) do
    task_num   = coerce_num(args["task_num"])
    session_id = Map.get(ctx, :session_id)

    with :ok <- require_num(task_num),
         :ok <- require_session(session_id),
         {:ok, task_id}  <- Tasks.resolve_num(session_id, task_num),
         %{} = task      <- Tasks.get(task_id),
         :ok             <- require_not_terminal(task, task_num),
         {:ok, result}   <- require_task_result(args["task_result"]),
         :ok             <- apply_title(task_id, args["task_title"]) do
      Tasks.mark_done(task_id, result)
      Logger.info("[CompleteTask] task=(#{task_num})[#{task_id}] type=#{task.task_type} result_len=#{String.length(result)}")
      {:ok, %{task_num: task_num, ok: true}}
    else
      {:error, :not_found} ->
        {:error,
         "complete_task: no task (#{task_num}) exists in this session."}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, "complete_task: internal lookup failed for task (#{task_num})"}
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
            description: "The per-session task number `(N)` to close. Must be non-terminal."
          },
          task_result: %{
            type: "string",
            description: "One-line summary of the outcome in the user's language. Shown in the sidebar so the user can recall what the task delivered."
          },
          task_title: %{
            type: "string",
            description: "OPTIONAL title refinement (≲ 60 chars, user's language). Use on one_off close when the creation-time title was vague — replace it with an outcome-focused sentence."
          }
        },
        required: ["task_num", "task_result"]
      }
    }
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp coerce_num(n) when is_integer(n), do: n
  defp coerce_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _        -> nil
    end
  end
  defp coerce_num(_), do: nil

  defp require_num(n) when is_integer(n) and n > 0, do: :ok
  defp require_num(_), do: {:error, "complete_task requires a positive integer `task_num`"}

  defp require_session(sid) when is_binary(sid) and sid != "", do: :ok
  defp require_session(_), do: {:error, "complete_task called without a session context"}

  defp require_not_terminal(%{task_status: s}, n) when s in ["done", "cancelled"] do
    {:error,
     "complete_task: task (#{n}) is already '#{s}'. Cannot re-complete a terminal task. " <>
       "If the user is asking for more work, call `pickup_task(task_num: #{n})` to reopen " <>
       "it (ongoing again) or `create_task` for a new row."}
  end
  defp require_not_terminal(_, _), do: :ok

  defp require_task_result(r) when is_binary(r) do
    cleaned = Dmhai.Agent.AttachmentPaths.strip_transient_markers(r) |> String.trim()
    if cleaned == "" do
      {:error, "complete_task: 'task_result' must be a non-empty summary of the outcome"}
    else
      {:ok, cleaned}
    end
  end
  defp require_task_result(_),
    do: {:error, "complete_task requires a non-empty 'task_result'"}

  defp apply_title(_task_id, nil), do: :ok
  defp apply_title(_task_id, ""),  do: :ok
  defp apply_title(task_id, title) when is_binary(title) do
    cleaned = Dmhai.Agent.AttachmentPaths.strip_transient_markers(title) |> String.trim()
    if cleaned == "" do
      :ok
    else
      Tasks.update_title(task_id, cleaned)
      :ok
    end
  end
  defp apply_title(_, other),
    do: {:error, "complete_task: invalid task_title=#{inspect(other)}"}
end
