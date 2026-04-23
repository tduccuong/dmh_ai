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
      "Update an existing task's status, title, description, or interval. " <>
        "status='ongoing' when you start working on it; 'done' when finished " <>
        "(periodic tasks auto-reschedule); 'paused' for a temporary halt; " <>
        "'cancelled' for permanent termination. When finalizing with " <>
        "status='done', also refine task_title to a short one-sentence " <>
        "summary of the outcome so the user can recall the task later. " <>
        "Pass task_spec to rewrite the description in place (e.g. user " <>
        "redirected the task). Pass intvl_sec to change a periodic task's " <>
        "interval."

  @impl true
  def execute(args, _ctx) do
    task_id = args["task_id"]

    with :ok                    <- require_task_id(task_id),
         %{} = task             <- Tasks.get(task_id) || :not_found,
         {:ok, attachments}     <- resolve_attachments(args),
         :ok                    <- apply_status(task_id, args["status"], args["task_result"]),
         :ok                    <- apply_spec_and_attachments(task, args["task_spec"], attachments),
         :ok                    <- apply_title(task_id, args["task_title"]),
         :ok                    <- apply_intvl(task_id, args["intvl_sec"]) do

      Logger.info("[UpdateTask] task=#{task_id} status=#{inspect(args["status"])} " <>
                  "spec?=#{args["task_spec"] not in [nil, ""]} " <>
                  "title?=#{args["task_title"] not in [nil, ""]} " <>
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
          task_title: %{
            type: "string",
            description:
              "Rewrite the task title. Most useful when finalizing with " <>
                "status='done': the initial title was chosen from a short " <>
                "user message and is usually vague — refine it to ONE short " <>
                "sentence (≲ 60 chars) that captures the outcome in the " <>
                "user's language, so they can recall the task weeks later."
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
      # Strip any context-build-time marker the model may have copied in
      # from its input verbatim; see §Attachment routing.
      cleaned_result = Dmhai.Agent.AttachmentPaths.strip_transient_markers(to_string(result))
      Tasks.mark_done(task_id, cleaned_result)
      :ok
    end
  end
  defp apply_status(_, other, _), do:
    {:error, "update_task: invalid status=#{inspect(other)}; must be one of #{inspect(@valid_statuses)}"}

  # Combined spec + attachments apply: either may be present, neither, or
  # both. When attachments change, we always re-run the normalisation over
  # the effective task_spec (new or existing).
  # Spec and attachments are independent now — spec is pure prose in its
  # own column, attachments live in tasks.attachments (JSON array). Each
  # is written separately.
  defp apply_spec_and_attachments(task, new_spec, attachments_arg) do
    with :ok <- apply_spec(task, new_spec),
         :ok <- apply_attachments(task, attachments_arg) do
      :ok
    end
  end

  defp apply_spec(_task, nil), do: :ok
  defp apply_spec(_task, ""),  do: :ok
  defp apply_spec(task, s) when is_binary(s) do
    cleaned = Dmhai.Agent.AttachmentPaths.clean_spec(s)
    with :ok <- require_non_empty_post_normalise(cleaned) do
      Tasks.update_spec(task.task_id, cleaned)
      :ok
    end
  end
  defp apply_spec(_task, other),
    do: {:error, "update_task: invalid task_spec=#{inspect(other)}"}

  defp apply_attachments(_task, :unchanged), do: :ok
  defp apply_attachments(task, list) when is_list(list) do
    Tasks.update_attachments(task.task_id, list)
    :ok
  end
  defp apply_attachments(_task, other),
    do: {:error, "update_task: invalid attachments=#{inspect(other)}"}

  # Mirror of create_task's guard — same root cause (model packs attachments
  # into task_spec while leaving `attachments` empty), same nudge.
  defp require_non_empty_post_normalise(spec) do
    if is_binary(spec) and String.trim(spec) != "" do
      :ok
    else
      {:error,
       "update_task: task_spec is empty after normalisation. You likely passed " <>
         "only a `📎 <path>` line as the spec — but file paths belong in the " <>
         "`attachments` argument, not task_spec. Put the user's verbatim " <>
         "question/request text in task_spec."}
    end
  end

  # Refine the task title — primary use-case is when `status='done'` to
  # replace the vague creation-time title with a richer one-line summary
  # based on the final answer. Strips any transient `[newly attached]`
  # marker the model may have copied from its input context.
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
  defp apply_title(_, other), do:
    {:error, "update_task: invalid task_title=#{inspect(other)}"}

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
