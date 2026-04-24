# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.PauseTask do
  @moduledoc """
  Temporarily halt a task. For periodic tasks, cancels the armed pickup
  timer so the scheduler won't fire the next cycle. The task can be
  resumed later via `pickup_task`.

  Only called when the user explicitly asks to pause ("pause the joke
  task", "hold off on X"). Accepts `ongoing` and `pending` tasks — the
  two non-terminal, non-paused states.

  Takes `task_num: integer`.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Tasks
  require Logger

  @impl true
  def name, do: "pause_task"

  @impl true
  def description,
    do:
      "Pause a task — flip status to 'paused'. For periodic tasks this " <>
        "also cancels the next-cycle pickup timer (it won't fire until you " <>
        "pickup_task again). Use ONLY when the user explicitly asks to " <>
        "pause (\"hold off\", \"pause X\"). Don't pause on your own initiative."

  @impl true
  def execute(args, ctx) do
    task_num   = coerce_num(args["task_num"])
    session_id = Map.get(ctx, :session_id)

    with :ok <- require_num(task_num),
         :ok <- require_session(session_id),
         {:ok, task_id} <- Tasks.resolve_num(session_id, task_num),
         %{} = task     <- Tasks.get(task_id),
         :ok            <- require_pausable(task, task_num) do
      Tasks.mark_paused(task_id)
      Logger.info("[PauseTask] task=(#{task_num})[#{task_id}] from=#{task.task_status} → paused")
      {:ok, %{task_num: task_num, ok: true}}
    else
      {:error, :not_found} ->
        {:error, "pause_task: no task (#{task_num}) exists in this session."}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, "pause_task: internal lookup failed for task (#{task_num})"}
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
            description: "The per-session task number `(N)` to pause. Must be in 'ongoing' or 'pending' state."
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
  defp require_num(_), do: {:error, "pause_task requires a positive integer `task_num`"}

  defp require_session(sid) when is_binary(sid) and sid != "", do: :ok
  defp require_session(_), do: {:error, "pause_task called without a session context"}

  defp require_pausable(%{task_status: s}, _n) when s in ["ongoing", "pending"], do: :ok
  defp require_pausable(%{task_status: "paused"}, n),
    do: {:error, "pause_task: task (#{n}) is already paused — no action needed."}
  defp require_pausable(%{task_status: s}, n),
    do:
      {:error,
       "pause_task: cannot pause task (#{n}) in '#{s}' state. Only 'ongoing' " <>
         "or 'pending' tasks can be paused. Terminal tasks (done/cancelled) are " <>
         "already finalized; use `create_task` for new work."}
end
