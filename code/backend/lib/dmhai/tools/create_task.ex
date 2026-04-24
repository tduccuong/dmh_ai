# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.CreateTask do
  @moduledoc """
  Register a task in the current session's task list AND immediately
  start work on it:

      create_task → <execution tools> → complete_task
                   ↑
                   auto-picks up: status jumps straight to `ongoing`,
                   and the runtime anchor flips to the new task_num.
                   No separate `pickup_task` call needed for brand-new
                   tasks. `pickup_task` remains the verb for RESUMING
                   a task that was previously done / paused / cancelled.

  The collapse — previously `create_task` (→ pending) + `pickup_task`
  (→ ongoing) as two LLM roundtrips — was the single biggest cost per
  fresh chain (~8 k input tokens of framework re-shipped). Folding
  them saves one full LLM call on every new-user-ask opener.

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
      "Register a new task AND immediately start work on it. The task is " <>
        "created with status='ongoing' and becomes the current anchor — " <>
        "your very next call can be an execution tool (run_script, " <>
        "web_search, ...). **Do NOT call pickup_task after create_task** — " <>
        "that would be redundant (the task is already ongoing). Use for " <>
        "work worth tracking: research, file ops, multi-step activities, " <>
        "AND any periodic task (monitor CPU every N sec, daily reports). " <>
        "For periodic tasks, set task_type='periodic' and intvl_sec>0. " <>
        "Returns {task_num}. When done, call complete_task(task_num, " <>
        "task_result)."

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
          # Phase 3 lever 2b: auto-pickup on create. The task starts
          # at `ongoing` — the model can run execution tools
          # immediately without a separate `pickup_task` call.
          # `pickup_task` is now exclusively for RESUMING previously
          # done/paused/cancelled tasks. See architecture.md §Task
          # lifecycle and `maybe_mutate_anchor/4` in `user_agent.ex`
          # for the matching anchor-advance behaviour.
          task_status: "ongoing",
          language:   normalise_lang(args["language"])
        )

      # Phase 3: look up the per-session `task_num` that Tasks.insert just
      # allocated and return THAT to the model — `task_num` is the only
      # identifier surfaced to model/user. `task_id` is still included
      # for tool-chain introspection but prompt+UI only show `(N)`.
      task = Tasks.get(task_id)
      task_num = task && task.task_num

      Logger.info("[CreateTask] task=(#{inspect(task_num)})[#{task_id}] type=#{task_type} intvl=#{intvl_sec} attachments=#{length(attachments)}")

      # Phase 3 lever 2b: return a SELF-DESCRIBING result. Weak models
      # anchor far more on the immediate tool result than on the system
      # prompt (which is far away in the context). `status: "ongoing"`
      # + `do_not` is deliberately PROHIBITIVE ONLY — earlier versions
      # also carried a positive hint ("call run_script / web_search
      # directly") which over-prescribed the path: 14 B-class models
      # took it as "next call MUST be run_script" and skipped natural
      # intermediate tools (lookup_credential, read_file, extract_content),
      # folding credential lookup INTO the bash script as if it were a
      # shell command. Leaving the positive direction unstated lets the
      # model pick its next tool the natural way.
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
