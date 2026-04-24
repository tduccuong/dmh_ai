# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.CancelTask do
  @moduledoc """
  Terminally abort a task. For periodic tasks, cancels the armed pickup
  timer. Unlike `pause_task`, cancellation is permanent — a cancelled
  task shows up in the `recent` bucket of the task sidebar; further
  work on the same subject requires a fresh `create_task`.

  Called on explicit user request to stop ("stop X", "cancel task N",
  "never mind X"). Model should NOT call this as a workaround for
  other issues (e.g. "the task is stuck, let me cancel and create a
  new one" — use `pickup_task` to resume, or ask the user).

  Takes `task_num: integer`.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Tasks
  require Logger

  @impl true
  def name, do: "cancel_task"

  @impl true
  def description,
    do:
      "Cancel a task permanently — flip status to 'cancelled', cancel any " <>
        "armed periodic pickup timer. Use ONLY when the user explicitly " <>
        "asks to stop/cancel a task. Don't auto-cancel to work around other " <>
        "issues; if the user asked for something new, use create_task for " <>
        "the new work and leave the existing task alone (or ask the user " <>
        "if they want it cancelled)."

  @impl true
  def execute(args, ctx) do
    task_num   = coerce_num(args["task_num"])
    session_id = Map.get(ctx, :session_id)

    with :ok <- require_num(task_num),
         :ok <- require_session(session_id),
         {:ok, task_id} <- Tasks.resolve_num(session_id, task_num),
         %{} = task     <- Tasks.get(task_id),
         :ok            <- require_not_terminal(task, task_num) do
      reason = normalise_reason(args["reason"])
      Tasks.mark_cancelled(task_id, reason)
      Logger.info("[CancelTask] task=(#{task_num})[#{task_id}] from=#{task.task_status} → cancelled reason=#{inspect(reason)}")
      {:ok, %{task_num: task_num, ok: true}}
    else
      {:error, :not_found} ->
        {:error, "cancel_task: no task (#{task_num}) exists in this session."}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, "cancel_task: internal lookup failed for task (#{task_num})"}
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
            description: "The per-session task number `(N)` to cancel. Must be non-terminal."
          },
          reason: %{
            type: "string",
            description:
              "OPTIONAL short reason shown in the task row's result column " <>
                "(e.g. \"user stopped\"). Defaults to a generic \"cancelled\" " <>
                "marker if omitted."
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
  defp require_num(_), do: {:error, "cancel_task requires a positive integer `task_num`"}

  defp require_session(sid) when is_binary(sid) and sid != "", do: :ok
  defp require_session(_), do: {:error, "cancel_task called without a session context"}

  defp require_not_terminal(%{task_status: s}, n) when s in ["done", "cancelled"],
    do:
      {:error,
       "cancel_task: task (#{n}) is already '#{s}' — nothing to cancel. " <>
         "If the user wants something new, use `create_task`."}
  defp require_not_terminal(_, _), do: :ok

  defp normalise_reason(r) when is_binary(r) do
    r = String.trim(r)
    if r == "", do: "Cancelled by user", else: r
  end
  defp normalise_reason(_), do: "Cancelled by user"
end
