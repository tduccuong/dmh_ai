# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.CreateTask do
  @moduledoc """
  Register a task in the current session's task list AND immediately
  start work on it:

      create_task → <execution tools> → complete_task

  The task is inserted at status `ongoing` and becomes the current
  anchor; the model's next call can be an execution tool directly.
  `pickup_task` is reserved for resuming a task already in the list.

  Returns a map with `task_num` (the per-session `(N)` the model uses
  for subsequent verbs).
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.Tasks
  require Logger

  @impl true
  def name, do: "create_task"

  @impl true
  def description,
    do:
      "Register a new task AND immediately start work on it. The task " <>
        "is created with status='ongoing' and becomes the current " <>
        "anchor — your next call can be an execution tool directly. " <>
        "**Do NOT call pickup_task after create_task** (redundant). " <>
        "Use for any objective worth tracking (research, file ops, " <>
        "multi-step work). For periodic tasks: task_type='periodic' " <>
        "and intvl_sec>0. Returns {task_num}. Close with " <>
        "complete_task(task_num, task_result) when delivered."

  @impl true
  def execute(args, ctx) do
    user_id    = Map.get(ctx, :user_id)
    session_id = Map.get(ctx, :session_id)

    with :ok                       <- require_ctx(user_id, session_id),
         :ok                       <- require_non_empty(args["task_title"], "task_title"),
         :ok                       <- require_non_empty(args["task_spec"], "task_spec"),
         {:ok, task_type}          <- normalise_type(args["task_type"]),
         {:ok, intvl_sec}          <- normalise_intvl(task_type, args["intvl_sec"]),
         {:ok, attachments}        <- Dmhai.Agent.AttachmentPaths.validate(args["attachments"]),
         cleaned_spec              <- Dmhai.Agent.AttachmentPaths.clean_spec(args["task_spec"]),
         :ok                       <- require_non_empty_post_normalise(cleaned_spec) do

      cleaned_title    = Dmhai.Agent.AttachmentPaths.strip_transient_markers(args["task_title"])

      task_id =
        Tasks.insert(
          user_id:    user_id,
          session_id: session_id,
          task_type:   task_type,
          intvl_sec:  intvl_sec,
          task_title:  cleaned_title,
          task_spec:   cleaned_spec,
          attachments: attachments,
          # Auto-pickup on create: the task starts at `ongoing` so the
          # model can run execution tools immediately. See
          # `maybe_mutate_anchor/4` in `user_agent.ex` for the matching
          # anchor advance.
          task_status: "ongoing",
          language:   normalise_lang(args["language"])
        )

      # The model/user/UI only see `task_num`; `task_id` is the
      # BE-internal FK. See architecture.md §Task lifecycle §Identity.
      task = Tasks.get(task_id)
      task_num = task && task.task_num

      Logger.info("[CreateTask] task=(#{inspect(task_num)})[#{task_id}] type=#{task_type} intvl=#{intvl_sec} attachments=#{length(attachments)}")

      # The returned map is self-describing. Weak models anchor on the
      # immediate tool result more than on the distant system prompt,
      # so `status: "ongoing"` + a prohibitive `do_not` repeats the
      # anti-pickup instruction at the point of decision. Positive
      # direction is left unstated so the model picks the natural
      # next tool (lookup_credential, read_file, run_script, ...).
      {:ok,
       %{
         task_num: task_num,
         task_title: args["task_title"],
         task_type: task_type,
         status: "ongoing",
         do_not: "call pickup_task — task is already ongoing"
       }}
    end
  end

  defp require_ctx(nil, _), do: {:error, "create_task called without user_id in context — runtime misconfiguration"}
  defp require_ctx(_, nil), do: {:error, "create_task called without session_id in context — runtime misconfiguration"}
  defp require_ctx(_, _),    do: :ok

  defp require_non_empty(v, field) do
    if is_binary(v) and String.trim(v) != "", do: :ok,
    else: {:error, "create_task requires a non-empty '#{field}'"}
  end

  # Guard against the model packing attachment 📎 lines into task_spec
  # while leaving `attachments` empty — `normalise_spec/2` strips all 📎
  # lines because `attachments` is authoritative, so the result is "".
  # Reject with a nudge that steers the model to the correct argument
  # split instead of silently persisting an empty spec.
  defp require_non_empty_post_normalise(spec) do
    if is_binary(spec) and String.trim(spec) != "" do
      :ok
    else
      {:error,
       "create_task: task_spec is empty after normalisation. You likely passed " <>
         "only a `📎 <path>` line as the spec — but file paths belong in the " <>
         "`attachments` argument, not task_spec. Put the user's verbatim " <>
         "question/request text in task_spec, and pass paths like " <>
         "`attachments: [\"workspace/foo.pdf\"]`."}
    end
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
            description: "The user's verbatim request. Do not rephrase or summarise."
          },
          task_type: %{
            type: "string",
            enum: ["one_off", "periodic"],
            description: "'one_off' for a single execution, 'periodic' for recurring."
          },
          intvl_sec: %{
            type: "integer",
            description: "Interval in seconds between cycles for periodic tasks. Must be > 0 for periodic; ignored for one_off."
          },
          language: %{
            type: "string",
            description: "ISO 639-1 code of the user's language."
          },
          attachments: %{
            type: "array",
            items: %{type: "string"},
            description:
              "File paths this task should operate on. Each must start with " <>
                "'workspace/' or 'data/'. Extract them from the `📎 ` lines in " <>
                "the user's message. Do NOT embed `📎 ` lines in task_spec — " <>
                "pass them here; the runtime canonicalises task_spec from this " <>
                "list."
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
