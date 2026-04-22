# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.UpdateTask do
  @moduledoc """
  Mutate fields of an existing task. The assistant calls this to:
    - Move a task through its lifecycle: pending → ongoing → done /
      paused / cancelled.
    - Rewrite a task's description when the user redirects mid-run
      (replaces fork-on-adjust: no separate row, just update in place).
    - Change a periodic task's interval.

  `status='done'` triggers `Tasks.mark_done/2` which auto-reschedules
  periodic tasks (status→pending, time_to_pickup=now+intvl_sec, timer
  armed via TaskRuntime).
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Tasks
  require Logger

  @valid_statuses ~w(pending ongoing paused done cancelled)

  @impl true
  def name, do: "update_task"

  @impl true
  def description,
    do:
      "Update an existing task's status, description, or interval. " <>
        "status='ongoing' when you start working on it; 'done' when finished " <>
        "(periodic tasks auto-reschedule); 'paused' for a temporary halt; " <>
        "'cancelled' for permanent termination. Pass task_spec to rewrite " <>
        "the description in place (e.g. user redirected the task). Pass " <>
        "intvl_sec to change a periodic task's interval."

  @impl true
  def execute(args, _ctx) do
    task_id = args["task_id"]

    with :ok                    <- require_task_id(task_id),
         %{} = task             <- Tasks.get(task_id) || :not_found,
         {:ok, attachments}     <- resolve_attachments(args),
         :ok                    <- apply_status(task_id, args["status"], args["task_result"]),
         :ok                    <- apply_spec_and_attachments(task, args["task_spec"], attachments),
         :ok                    <- apply_intvl(task_id, args["intvl_sec"]) do

      Logger.info("[UpdateTask] task=#{task_id} status=#{inspect(args["status"])} " <>
                  "spec?=#{args["task_spec"] not in [nil, ""]} " <>
                  "attachments?=#{attachments != :unchanged} " <>
                  "intvl?=#{args["intvl_sec"] != nil}")
      {:ok, %{task_id: task_id, ok: true}}
    else
      :not_found       -> {:error, "update_task: no task with task_id=#{inspect(task_id)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_task_id(t) when is_binary(t) and t != "", do: :ok
  defp require_task_id(_), do: {:error, "update_task requires a non-empty 'task_id'"}

  # Attachments resolution: if the `attachments` key is absent → :unchanged.
  # If present (even as []) → validate and treat as replacement list.
  defp resolve_attachments(args) do
    case Map.fetch(args, "attachments") do
      :error -> {:ok, :unchanged}
      {:ok, raw} ->
        case Dmhai.Agent.AttachmentPaths.validate(raw) do
          {:ok, list}      -> {:ok, list}
          {:error, _} = e  -> e
        end
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
          task_id: %{type: "string", description: "The task_id to update."},
          status: %{
            type: "string",
            enum: @valid_statuses,
            description:
              "New status. 'done' triggers auto-reschedule for periodic tasks. " <>
                "'ongoing' when you start working. 'paused'/'cancelled' as appropriate."
          },
          task_result: %{
            type: "string",
            description: "Required when status='done'. The compiled result shown in the task row."
          },
          task_spec: %{
            type: "string",
            description: "Rewrite the task description in place (e.g. after a user redirect)."
          },
          intvl_sec: %{
            type: "integer",
            description: "New interval in seconds for a periodic task (must be > 0)."
          },
          attachments: %{
            type: "array",
            items: %{type: "string"},
            description:
              "Replace the task's attachment list. Each path must start with " <>
                "'workspace/' or 'data/'. Omit the field entirely to leave " <>
                "attachments unchanged; pass [] to clear them."
          }
        },
        required: ["task_id"]
      }
    }
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp apply_status(_task_id, nil, _),          do: :ok
  defp apply_status(task_id, "ongoing", _)    , do: (Tasks.mark_ongoing(task_id); :ok)
  defp apply_status(task_id, "paused", _)     , do: (Tasks.mark_paused(task_id); :ok)
  defp apply_status(task_id, "cancelled", _)  , do: (Tasks.mark_cancelled(task_id); :ok)
  defp apply_status(task_id, "pending", _)    , do: (Tasks.mark_pending(task_id); :ok)
  defp apply_status(task_id, "done", result) do
    if (result || "") |> to_string() |> String.trim() == "" do
      {:error, "update_task(status='done') requires a non-empty 'task_result' — compile the final answer for the task"}
    else
      Tasks.mark_done(task_id, to_string(result))
      :ok
    end
  end
  defp apply_status(_, other, _), do:
    {:error, "update_task: invalid status=#{inspect(other)}; must be one of #{inspect(@valid_statuses)}"}

  # Combined spec + attachments apply: either may be present, neither, or
  # both. When attachments change, we always re-run the normalisation over
  # the effective task_spec (new or existing).
  defp apply_spec_and_attachments(task, new_spec, :unchanged) do
    case new_spec do
      nil -> :ok
      ""  -> :ok
      s when is_binary(s) ->
        # Re-apply existing attachments during the spec rewrite so 📎 lines
        # don't get dropped accidentally when the assistant rewrites the
        # description text without re-supplying attachments.
        existing = Dmhai.Agent.ContextEngine.extract_attachments(task.task_spec)
        Tasks.update_spec(task.task_id, Dmhai.Agent.AttachmentPaths.normalise_spec(s, existing))
        :ok
      other ->
        {:error, "update_task: invalid task_spec=#{inspect(other)}"}
    end
  end
  defp apply_spec_and_attachments(task, new_spec, attachments) when is_list(attachments) do
    base =
      case new_spec do
        nil                 -> task.task_spec || ""
        ""                  -> task.task_spec || ""
        s when is_binary(s) -> s
        other               -> throw({:bad_spec, other})
      end

    Tasks.update_spec(task.task_id, Dmhai.Agent.AttachmentPaths.normalise_spec(base, attachments))
    :ok
  catch
    {:bad_spec, other} -> {:error, "update_task: invalid task_spec=#{inspect(other)}"}
  end

  defp apply_intvl(_task_id, nil), do: :ok
  defp apply_intvl(task_id, intvl) when is_integer(intvl) and intvl > 0 do
    Tasks.update_intvl(task_id, intvl)
    :ok
  end
  defp apply_intvl(task_id, intvl) when is_binary(intvl) do
    case Integer.parse(intvl) do
      {n, _} when n > 0 -> apply_intvl(task_id, n)
      _                 -> {:error, "update_task: invalid intvl_sec=#{inspect(intvl)}"}
    end
  end
  defp apply_intvl(_, other), do: {:error, "update_task: invalid intvl_sec=#{inspect(other)}"}
end
