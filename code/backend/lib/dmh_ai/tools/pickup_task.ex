# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.PickupTask do
  @moduledoc """
  Resume an existing task with its prior context.

  Flips the task's status to `ongoing` AND returns the task's prior work
  inside a `<requested_task_content number="N">` envelope. The envelope
  branches on whether the task's content is still in the live LLM
  thread, has been compacted out to `task_chain_archive`, or both:

    * **Live present, no archive** — pointer line only (the model
      already has the task's turns above in `messages`).
    * **No live, archive only** — full archive transcript in
      chronological order, natural-conversation form.
    * **Both** — pointer line for the live portion, archive transcript
      for the older compacted-out turns. By construction the archive
      and live portions are disjoint (compaction MOVES messages from
      live into archive), so no dedup detection is needed.

  Tool-result bodies NEVER appear in the envelope. The tool_call shells
  (`[assistant→tool_name] {args}`) do — that's the procedural shape the
  model needs. The assistant's surrounding text already summarised what
  each call returned. See architecture.md §Task state continuity
  across chains §Tool-result eviction at task close.

  Idempotent: calling on an already-`ongoing` task is a no-op flip but
  still returns the envelope. Permissive: accepts `pending`, `paused`,
  `done`, `cancelled` and reopens them. Only failure is "no task (N) in
  this session."

  Takes `task_num: integer` (the per-session `(N)` the user and model
  see). BE resolves to the internal `task_id` via `Tasks.resolve_num/2`
  before any DB mutation.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.{AgentSettings, Tasks, TaskChainArchive, UserAgentMessages}
  require Logger

  @impl true
  def name, do: "pickup_task"

  @impl true
  def description,
    do:
      "Resume an existing task. Flips its status to 'ongoing' AND returns the " <>
        "task's prior work in a <requested_task_content> envelope so you can " <>
        "continue without re-deriving. Use this — not create_task — when the " <>
        "user's request is a follow-up to a closed task in the Task list."

  @impl true
  def execute(args, ctx) do
    task_num   = coerce_num(args["task_num"])
    session_id = Map.get(ctx, :session_id)

    with :ok <- require_num(task_num),
         :ok <- require_session(session_id),
         {:ok, task_id} <- Tasks.resolve_num(session_id, task_num),
         %{} = task     <- Tasks.get(task_id) do
      from_status = task.task_status

      if from_status != "ongoing" do
        Tasks.mark_ongoing(task_id)
        Logger.info("[PickupTask] task=(#{task_num})[#{task_id}] from=#{from_status} → ongoing")
      end

      have_live    = UserAgentMessages.messages_for_task_num(session_id, task_num, 0) != []
      archive_msgs = TaskChainArchive.fetch_for_task(task_id)
      have_archive = archive_msgs != []

      envelope = render_envelope(task, task_num, have_live, archive_msgs, have_archive)

      # Return the envelope as a raw string — `format_tool_result/1`
      # passes binaries through verbatim so the model sees the
      # `<requested_task_content>…</requested_task_content>` block
      # directly, not wrapped in JSON. See architecture.md §Tool
      # result formatting + rule #10.
      {:ok, envelope}
    else
      {:error, :not_found} ->
        {:error,
         "pickup_task: no task (#{task_num}) exists in this session. " <>
           "Check the Task list block for the valid `(N)` numbers, " <>
           "or call `create_task` first if this is a new ask."}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, "pickup_task: internal lookup failed for task (#{task_num})"}
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
            description: "The per-session task number `(N)` to resume."
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

  # ── envelope rendering ─────────────────────────────────────────────

  defp render_envelope(task, task_num, have_live, archive_msgs, have_archive) do
    title       = task.task_title || "(untitled)"
    task_result = task.task_result
    pointer     = if have_live, do: pointer_line(task_num), else: nil
    transcript  = if have_archive, do: render_transcript(archive_msgs), else: nil

    body =
      [pointer, transcript, "Last task_result: #{format_result(task_result)}."]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    """
    <requested_task_content number="#{task_num}">
    Task (#{task_num}) "#{title}".

    #{body}
    </requested_task_content>
    """
    |> String.trim_trailing()
  end

  defp pointer_line(task_num),
    do:
      "Recent turns are in your conversation thread above — scan messages " <>
        "prefixed [task (#{task_num})] and pick up from there."

  defp render_transcript(archive_msgs) do
    args_cap  = AgentSettings.task_resume_args_cap()
    entry_cap = AgentSettings.task_resume_max_archive_entries()

    # Drop tool-result rows (closed-task tool bodies are evicted globally
    # — see architecture.md §Tool-result eviction at task close). The
    # assistant rows' `tool_calls` field still carries the call shells,
    # which we render inline as `[assistant→name] {args}` lines.
    rendered_lines =
      archive_msgs
      |> Enum.reject(&(Map.get(&1, :role) == "tool"))
      |> Enum.take(-entry_cap)
      |> Enum.flat_map(&render_message(&1, args_cap))

    intro =
      "Older turns that were compacted out of your live thread follow in " <>
        "chronological order. Tool calls are shown by name+args; tool " <>
        "results are omitted."

    intro <> "\n\n" <> Enum.join(rendered_lines, "\n\n")
  end

  defp render_message(msg, args_cap) do
    role    = Map.get(msg, :role) || ""
    content = Map.get(msg, :content) || ""
    tcs     = Map.get(msg, :tool_calls) || []

    text_line =
      case String.trim(content) do
        "" -> nil
        t  -> "[#{role}] #{t}"
      end

    tool_lines =
      Enum.map(tcs, fn tc ->
        fn_map = Map.get(tc, "function") || Map.get(tc, :function) || %{}
        name   = Map.get(fn_map, "name") || Map.get(fn_map, :name) || "?"
        args   = Map.get(fn_map, "arguments") || Map.get(fn_map, :arguments)
        args_s = format_args(args, args_cap)
        "[assistant→#{name}] #{args_s}"
      end)

    [text_line | tool_lines] |> Enum.reject(&is_nil/1)
  end

  defp format_args(nil, _cap), do: "{}"
  defp format_args(args, cap) when is_map(args) do
    s = Jason.encode!(args)
    truncate(s, cap)
  end
  defp format_args(args, cap) when is_binary(args), do: truncate(args, cap)
  defp format_args(args, cap), do: args |> inspect() |> truncate(cap)

  defp truncate(s, cap) when is_binary(s) and byte_size(s) > cap,
    do: String.slice(s, 0, cap) <> "…"
  defp truncate(s, _cap), do: s

  defp format_result(nil),                 do: "null"
  defp format_result(""),                  do: "null"
  defp format_result(s) when is_binary(s), do: "\"" <> s <> "\""
  defp format_result(other),               do: inspect(other)
end
