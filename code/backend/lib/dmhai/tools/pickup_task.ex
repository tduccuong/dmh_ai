# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.PickupTask do
  @moduledoc """
  Flip a task to `ongoing` — signalling "I'm actively working on this now."

  Idempotent: if the task is already `ongoing`, returns ok without a DB
  write. Permissive: accepts `pending`, `paused`, `done`, `cancelled` and
  reopens them. The only failure is "no task (N) in this session."

  Phase 3: takes `task_num: integer` (the per-session `(N)` the user and
  model see). BE resolves to the internal cryptic `task_id` via
  `Tasks.resolve_num/2` before any DB mutation. See architecture.md
  §Task lifecycle §Identity.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Tasks
  require Logger

  @impl true
  def name, do: "pickup_task"

  @impl true
  def description,
    do:
      "RESUME an existing task from the Task list — flip it to " <>
        "status='ongoing'. **Do NOT call this right after create_task** — " <>
        "that's redundant, create_task already auto-picks up the new row. " <>
        "Use `pickup_task` for: (1) the user explicitly asks to resume / " <>
        "redo a previously done / paused / cancelled task (\"resume task " <>
        "2\", \"continue X\"); (2) you need to restore an ongoing task " <>
        "that was interrupted; (3) idempotent re-pickup when you want to " <>
        "emphasise which task you're on. Returns {task_num, ok: true}."

  @impl true
  def execute(args, ctx) do
    task_num   = coerce_num(args["task_num"])
    session_id = Map.get(ctx, :session_id)

    with :ok <- require_num(task_num),
         :ok <- require_session(session_id),
         {:ok, task_id} <- Tasks.resolve_num(session_id, task_num) do
      task = Tasks.get(task_id)

      if task && task.task_status == "ongoing" do
        Logger.info("[PickupTask] task=(#{task_num})[#{task_id}] already ongoing — no-op")
        {:ok, %{task_num: task_num, ok: true, was_already_ongoing: true}}
      else
        Tasks.mark_ongoing(task_id)
        from_status = task && task.task_status
        Logger.info("[PickupTask] task=(#{task_num})[#{task_id}] from=#{from_status} → ongoing")
        {:ok, %{task_num: task_num, ok: true}}
      end
    else
      {:error, :not_found} ->
        {:error,
         "pickup_task: no task (#{task_num}) exists in this session. " <>
           "Check the Task list block for the valid `(N)` numbers, " <>
           "or call `create_task` first if this is a new ask."}

      {:error, reason} ->
        {:error, reason}
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
            description:
              "The per-session task number `(N)` to pick up. Must be one " <>
                "that appears in the current session's Task list, or one " <>
                "that `create_task` returned earlier this chain."
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
  defp require_num(_), do: {:error, "pickup_task requires a positive integer `task_num`"}

  defp require_session(sid) when is_binary(sid) and sid != "", do: :ok
  defp require_session(_), do: {:error, "pickup_task called without a session context"}
end
