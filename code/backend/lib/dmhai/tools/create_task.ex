# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.CreateTask do
  @moduledoc """
  Create a task in the current session's task list. The assistant calls
  this when the user asks for something that's worth tracking (ongoing
  work, periodic monitoring, anything bigger than a one-line reply).

  Returns a map with `task_id` so subsequent turns can reference it. The
  task row starts at `status='pending'` with `time_to_pickup=now` for
  both types — the assistant's current turn can pick it up immediately.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Tasks
  require Logger

  @impl true
  def name, do: "create_task"

  @impl true
  def description,
    do:
      "Create a task in the current session's task list. Use for work worth " <>
        "tracking: research, file operations, multi-step activities, AND any " <>
        "periodic task (monitor CPU every N sec, daily reports). For periodic " <>
        "tasks, set task_type='periodic' and intvl_sec>0. Returns {task_id} so " <>
        "you can reference it in update_task later."

  @impl true
  def execute(args, ctx) do
    user_id    = Map.get(ctx, :user_id)
    session_id = Map.get(ctx, :session_id)

    with :ok                       <- require_ctx(user_id, session_id),
         :ok                       <- require_non_empty(args["task_title"], "task_title"),
         :ok                       <- require_non_empty(args["task_spec"], "task_spec"),
         {:ok, task_type}          <- normalise_type(args["task_type"]),
         {:ok, intvl_sec}          <- normalise_intvl(task_type, args["intvl_sec"]),
         {:ok, attachments}        <- Dmhai.Agent.AttachmentPaths.validate(args["attachments"]) do

      normalised_spec = Dmhai.Agent.AttachmentPaths.normalise_spec(args["task_spec"], attachments)

      task_id =
        Tasks.insert(
          user_id:    user_id,
          session_id: session_id,
          task_type:   task_type,
          intvl_sec:  intvl_sec,
          task_title:  args["task_title"],
          task_spec:   normalised_spec,
          # Start as 'ongoing' — the model just created this because it's
          # about to execute it in this same turn. 'pending' is reserved for
          # periodic tasks awaiting their next cycle and for tasks resurrected
          # via update_task(status: "pending").
          task_status: "ongoing",
          language:   normalise_lang(args["language"])
        )

      Logger.info("[CreateTask] task=#{task_id} type=#{task_type} intvl=#{intvl_sec} attachments=#{length(attachments)}")
      {:ok, %{task_id: task_id, task_title: args["task_title"], task_type: task_type}}
    end
  end

  defp require_ctx(nil, _), do: {:error, "create_task called without user_id in context — runtime misconfiguration"}
  defp require_ctx(_, nil), do: {:error, "create_task called without session_id in context — runtime misconfiguration"}
  defp require_ctx(_, _),    do: :ok

  defp require_non_empty(v, field) do
    if is_binary(v) and String.trim(v) != "", do: :ok,
    else: {:error, "create_task requires a non-empty '#{field}'"}
  end

  defp normalise_intvl(task_type, raw) do
    n = parse_int(raw, 0)
    cond do
      task_type == "periodic" and n <= 0 ->
        {:error, "create_task(task_type='periodic') requires intvl_sec > 0"}
      true ->
        {:ok, n}
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
          task_title: %{
            type: "string",
            description: "Short 2-6 word title in the user's language. Shown in the task list."
          },
          task_spec: %{
            type: "string",
            description:
              "The task description — verbatim user message (including any " <>
                "📎-prefixed attachment paths). Do not rephrase or summarise."
          },
          task_type: %{
            type: "string",
            enum: ["one_off", "periodic"],
            description: "'one_off' for a single execution, 'periodic' for recurring."
          },
          intvl_sec: %{
            type: "integer",
            description:
              "For periodic tasks: interval in seconds between cycles " <>
                "(e.g. 3600 = hourly). Must be > 0 for periodic. Ignored for one_off."
          },
          language: %{
            type: "string",
            description: "ISO 639-1 code of the user's language (e.g. 'en', 'vi', 'es', 'fr', 'ja')."
          },
          attachments: %{
            type: "array",
            items: %{type: "string"},
            description:
              "File paths this task should operate on. Each must start with " <>
                "'workspace/' or 'data/'. Look at the user message for lines " <>
                "starting with '📎 ' — those are the uploaded paths; route each " <>
                "to the task that needs it. The system canonicalises task_spec " <>
                "by appending `📎 <path>` lines — DO NOT embed them in task_spec yourself."
          }
        },
        required: ["task_title", "task_spec", "task_type", "language"]
      }
    }
  end

  defp normalise_type("periodic"),  do: {:ok, "periodic"}
  defp normalise_type("one_off"),  do: {:ok, "one_off"}
  defp normalise_type(nil),          do: {:ok, "one_off"}
  defp normalise_type(other), do:
    {:error, "create_task task_type=#{inspect(other)} must be 'one_off' or 'periodic'"}

  defp parse_int(v, _default) when is_integer(v), do: v
  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _      -> default
    end
  end
  defp parse_int(_, default), do: default

  defp normalise_lang(nil), do: "en"
  defp normalise_lang(""),  do: "en"
  defp normalise_lang(v) when is_binary(v) do
    code = v |> String.downcase() |> String.trim() |> String.split(~r/[_\-]/) |> List.first()
    if is_binary(code) and String.length(code) in 2..3, do: code, else: "en"
  end
  defp normalise_lang(_), do: "en"
end
