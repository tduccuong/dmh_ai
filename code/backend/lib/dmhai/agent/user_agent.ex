# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.UserAgent do
  @idle_timeout :timer.minutes(30)

  @moduledoc """
  Per-user master agent (GenServer).

  Lifecycle
  ---------
  Started lazily by Dmhai.Agent.Supervisor.ensure_started/1 on first command.
  Shuts itself down after 30 minutes of idle.
  State that must survive restarts (workers in progress, platform state) is
  kept in-memory only for now — a crash means workers are lost and the agent
  restarts clean. Persistence can be added later.

  Execution paths
  ---------------
  1. Inline  — short/streaming tasks (answer, search, tool call).
               A Task runs under Dmhai.Agent.TaskSupervisor, sends
               {:chunk, text} / {:done, result} directly to reply_pid,
               then exits.  The GenServer monitors it and clears state on done.

  2. Worker  — long/async tasks (booking, file processing, monitoring).
               A Task runs under Dmhai.Agent.WorkerSupervisor.  The HTTP
               connection is already closed (ack was sent).  When the worker
               finishes it writes a new assistant message to the session in DB
               and fires MsgGateway.notify/2.
  """

  use GenServer
  require Logger

  alias Dmhai.Agent.{AgentSettings, Command, ContextEngine, LLM, ProfileExtractor, Supervisor, Tasks, TokenTracker, WebSearch}
  alias Dmhai.Web.Search, as: WebSearchEngine
  # WebSearch kept for synthesize_results used in build_web_context
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # ─── State ────────────────────────────────────────────────────────────────

  defstruct [
    :user_id,
    # current inline task: nil | {task_ref, reply_pid}
    current_task: nil,
    # per-platform opaque state (e.g. %{telegram: %{chat_id: "123"}})
    platform_state: %{}
  ]

  # ─── Client API ───────────────────────────────────────────────────────────

  @doc "Route a Command to the user's agent, starting it if needed."
  @spec dispatch(String.t(), Command.t()) :: :ok | {:error, term()}
  def dispatch(user_id, %Command{} = command) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, {:dispatch, command}, :infinity)
    end
  end

  @doc "Cancel all active tasks for a specific session (called on session delete)."
  @spec cancel_session_workers(String.t(), String.t()) :: :ok
  def cancel_session_workers(_user_id, session_id) do
    session_id
    |> Tasks.active_for_session()
    |> Enum.each(fn task -> Dmhai.Agent.TaskRuntime.cancel_task(task.task_id) end)
    :ok
  end

  @doc "Store platform-specific state (e.g. Telegram chat_id) in the agent."
  @spec set_platform_state(String.t(), atom(), map()) :: :ok
  def set_platform_state(user_id, platform, state) when is_atom(platform) do
    case Registry.lookup(Dmhai.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.cast(pid, {:set_platform_state, platform, state})
      [] -> :ok
    end
  end

  @doc "Read platform-specific state. Returns nil if agent not running."
  @spec get_platform_state(String.t(), atom()) :: map() | nil
  def get_platform_state(user_id, platform) do
    case Registry.lookup(Dmhai.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, {:get_platform_state, platform})
      [] -> nil
    end
  end

  # ─── GenServer callbacks ───────────────────────────────────────────────────

  def start_link(user_id) do
    GenServer.start_link(__MODULE__, user_id, name: via(user_id))
  end

  @impl true
  def init(user_id) do
    Logger.info("[UserAgent] started user=#{user_id}")
    # Boot rehydration (orphan detection, due-periodic spawn) is delegated to
    # Dmhai.Agent.TaskRuntime which runs at app startup and manages the scheduler.
    {:ok, %__MODULE__{user_id: user_id}, @idle_timeout}
  end

  # Dispatch a command
  @impl true
  def handle_call({:dispatch, %Command{type: :interrupt}}, _from, state) do
    state = cancel_current_task(state)
    {:reply, :ok, state, @idle_timeout}
  end

  def handle_call({:dispatch, %Command{} = command}, _from, state) do
    if state.current_task do
      # Already busy — tell the reply_pid directly and refuse
      send(command.reply_pid, {:error, :busy})
      {:reply, {:error, :busy}, state, @idle_timeout}
    else
      task =
        Task.Supervisor.async_nolink(Dmhai.Agent.TaskSupervisor, fn ->
          run_command(command, state)
        end)

      {:reply, :ok, %{state | current_task: {task.ref, command.reply_pid}},
       @idle_timeout}
    end
  end

  # Platform state
  def handle_call({:get_platform_state, platform}, _from, state) do
    {:reply, Map.get(state.platform_state, platform), state, @idle_timeout}
  end

  @impl true
  def handle_cast({:set_platform_state, platform, pstate}, state) do
    {:noreply, %{state | platform_state: Map.put(state.platform_state, platform, pstate)},
     @idle_timeout}
  end

  # Inline task completed normally — {ref, result} message from Task
  @impl true
  def handle_info({ref, _result}, %{current_task: {ref, _}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  # Stray {ref, _result} from tasks we no longer track — swallow.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state, @idle_timeout}
  end

  # Inline task crashed
  def handle_info({:DOWN, ref, :task, _pid, reason}, %{current_task: {ref, reply_pid}} = state) do
    Logger.error("[UserAgent] inline task crashed user=#{state.user_id} reason=#{inspect(reason)}")
    send(reply_pid, {:error, "Internal error — please try again"})
    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  # Stray DOWN — swallow. (Was used for the old worker tracking; TaskRuntime owns workers now.)
  def handle_info({:DOWN, _ref, _type, _pid, _reason}, state) do
    {:noreply, state, @idle_timeout}
  end

  # Idle timeout — shut down cleanly
  def handle_info(:timeout, state) do
    Logger.info("[UserAgent] idle timeout, stopping user=#{state.user_id}")
    {:stop, :normal, state}
  end

  # ─── Private helpers ───────────────────────────────────────────────────────

  defp via(user_id) do
    {:via, Registry, {Dmhai.Agent.Registry, user_id}}
  end

  defp cancel_current_task(%{current_task: nil} = state), do: state

  defp cancel_current_task(%{current_task: {_ref, reply_pid}} = state) do
    send(reply_pid, {:error, :interrupted})
    %{state | current_task: nil}
  end

  # Append a message map to the session's messages JSON column in DB.
  defp append_session_message(session_id, user_id, message) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                      [session_id, user_id])

      case result.rows do
        [[msgs_json]] ->
          msgs = Jason.decode!(msgs_json || "[]")
          updated = Jason.encode!(msgs ++ [message])
          now = System.os_time(:millisecond)
          query!(Repo, "UPDATE sessions SET messages=?, updated_at=? WHERE id=?",
                 [updated, now, session_id])

        _ ->
          Logger.warning("[UserAgent] session not found id=#{session_id}")
      end
    rescue
      e -> Logger.error("[UserAgent] append_session_message failed: #{Exception.message(e)}")
    end
  end


  # ─── Command execution (inline task) ──────────────────────────────────────

  @doc false
  # Runs inside a Task under TaskSupervisor.
  # Routes to Confidant or Assistant pipeline based on session mode.
  defp run_command(%Command{reply_pid: reply_pid, session_id: session_id} = command, state) do
    user_id = state.user_id

    case load_session(session_id, user_id) do
      {:ok, _session_model, session_data} ->
        mode = session_data["mode"] || "confidant"

        case mode do
          "assistant" -> run_assistant(command, state, session_data)
          _           -> run_confidant(command, state, session_data)
        end

      {:error, reason} ->
        send(reply_pid, {:error, reason})
    end
  end

  # ─── Confidant pipeline ─────────────────────────────────────────────────
  # Synchronous: detect web search → maybe fetch → master responds.

  defp run_confidant(%Command{reply_pid: reply_pid, session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.confidant_model()

    web_context =
      if command.content != "" do
        user_msgs = extract_user_messages(session_data)
        case WebSearchEngine.search(command.content, user_msgs, :confidant, reply_pid: reply_pid) do
          :no_search -> nil
          result     -> build_web_context(command.content, result, reply_pid)
        end
      else
        nil
      end

    profile            = load_user_profile(user_id)
    image_descriptions = load_image_descriptions(session_id)
    video_descriptions = load_video_descriptions(session_id)

    # Use pre-computed description when available; fall back to raw images for the Confidant LLM call.
    images = effective_images(command, image_descriptions, video_descriptions)

    llm_messages =
      ContextEngine.build_confidant_messages(session_data,
        profile:            profile,
        has_video:          images != [] and command.has_video,
        images:             images,
        files:              command.files,
        image_descriptions: image_descriptions,
        video_descriptions: video_descriptions,
        web_context:        web_context
      )

    Dmhai.SysLog.log("[CONFIDANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)} web_search=#{web_context != nil}")
    Dmhai.SysLog.log("[CONFIDANT] sending #{length(llm_messages)} msgs to model=#{model}\n  #{log_llm_messages(llm_messages)}")

    on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
    trace     = %{origin: "confidant", path: "UserAgent.run_confidant", role: "ConfidantMaster", phase: "single-turn"}
    case LLM.stream(model, llm_messages, reply_pid, on_tokens: on_tokens, trace: trace) do
      {:ok, full_text} when full_text != "" ->
        Dmhai.SysLog.log("[CONFIDANT] response(#{String.length(full_text)} chars): #{String.slice(full_text, 0, 300)}")
        append_session_message(session_id, user_id, %{
          role: "assistant",
          content: full_text,
          ts: System.os_time(:millisecond)
        })

        send(reply_pid, {:done, %{content: full_text}})

        Task.start(fn -> maybe_compact(session_id, user_id) end)

        Task.start(fn ->
          ProfileExtractor.extract_and_merge(command.content, full_text, user_id)
        end)

      {:ok, ""} ->
        send(reply_pid, {:error, "No response received. Please try again."})

      {:error, reason} ->
        Dmhai.SysLog.log("[CONFIDANT] ERROR: #{inspect(reason)}")
        send(reply_pid, {:error, "LLM error: #{inspect(reason)}"})
    end
  end

  # ─── Assistant pipeline ─────────────────────────────────────────────────
  # Master creates plan → worker executes → master_buffer → master reports.

  defp run_assistant(%Command{reply_pid: reply_pid, session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.assistant_model()

    profile = load_user_profile(user_id)

    # Inject active tasks for this session so the Assistant can answer
    # status/cancel/set-periodic queries using real task_ids.
    session_jobs = Tasks.list_for_session(session_id)
    combined_buffer =
      case Enum.filter(session_jobs, fn j -> j.task_status in ["pending", "running", "paused"] end) do
        [] -> nil
        active ->
          lines =
            Enum.map_join(active, "\n", fn j ->
              "- task_id: #{j.task_id}, title: #{j.task_title}, type: #{j.task_type}, status: #{j.task_status}"
            end)
          "[Active tasks for this session]\n#{lines}"
      end

    # Pass only the current message's raw images so the master can classify intent
    # (e.g. recognise an image-analysis request). Image descriptions from previous
    # messages are intentionally excluded — the master is a classifier, not an
    # answerer, and descriptions in its system prompt cause it to answer directly
    # instead of handing off to a worker.
    images = command.images

    # Detect language from URL-stripped prose so the master can't be misled by
    # URL domains (e.g. "summarize this: https://vnexpress.net/..." → "en").
    # Returns nil on UNKNOWN so the master falls back to its own detection.
    detected_language = detect_content_language(command.content)

    llm_messages =
      ContextEngine.build_assistant_messages(session_data,
        profile:        profile,
        has_video:      images != [] and command.has_video,
        images:         images,
        files:          command.files,
        buffer_context: combined_buffer,
        language:       detected_language
      )

    tools = [
      handoff_to_worker_json_schema_def(),
      set_periodic_for_task_json_schema_def(),
      pause_task_json_schema_def(),
      resume_task_json_schema_def(),
      cancel_task_json_schema_def(),
      read_task_status_json_schema_def()
    ]

    Dmhai.SysLog.log("[ASSISTANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)}")
    Dmhai.SysLog.log("[ASSISTANT] sending #{length(llm_messages)} msgs to model=#{model}\n  #{log_llm_messages(llm_messages)}")

    on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
    trace     = %{origin: "assistant", path: "UserAgent.run_assistant", role: "AssistantMaster", phase: "classify"}
    # Pass self() so master reasoning/text does not stream to the user when a tool call is made.
    # For the rare text-only fallback, we forward full_text manually below.
    case LLM.stream(model, llm_messages, self(), tools: tools, on_tokens: on_tokens, trace: trace) do
      {:ok, {:tool_calls, calls}} ->
        call_names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
        Dmhai.SysLog.log("[ASSISTANT] tool_calls=[#{call_names}]")
        handle_tool_calls(calls, command, state, session_data)

      {:ok, full_text} when full_text != "" ->
        # Fallback — master should always call a tool, but handle gracefully if it doesn't.
        # Since we passed self() above, chunks went to the Task mailbox; forward them here.
        Logger.warning("[UserAgent] master returned text without tool call, presenting directly")
        Dmhai.SysLog.log("[ASSISTANT] text fallback (#{String.length(full_text)} chars): #{String.slice(full_text, 0, 200)}")
        append_session_message(session_id, user_id, %{
          role: "assistant",
          content: full_text,
          ts: System.os_time(:millisecond)
        })
        send(reply_pid, {:chunk, full_text})
        send(reply_pid, {:done, %{content: full_text}})
        Task.start(fn -> maybe_compact(session_id, user_id) end)

      {:ok, ""} ->
        send(reply_pid, {:error, "No response received. Please try again."})

      {:error, reason} ->
        Dmhai.SysLog.log("[ASSISTANT] ERROR: #{inspect(reason)}")
        send(reply_pid, {:error, "LLM error: #{inspect(reason)}"})
    end
  end

  defp handle_tool_calls(calls, command, state, session_data) do
    tool_name =
      Enum.find_value(calls, nil, fn call -> get_in(call, ["function", "name"]) end)

    case tool_name do
      "handoff_to_worker"      -> handle_handoff_to_worker(calls, command, state, session_data)
      "set_periodic_for_task"   -> handle_set_periodic(calls, command, state)
      "pause_task"              -> handle_pause_task(calls, command, state)
      "resume_task"             -> handle_resume_task(calls, command, state)
      "cancel_task"             -> handle_cancel_task(calls, command, state)
      "read_task_status"        -> handle_read_task_status(calls, command, state)
      _                        ->
        Logger.warning("[UserAgent] unknown Assistant tool call: #{inspect(tool_name)}")
        send(command.reply_pid, {:error, "Unknown tool: #{inspect(tool_name)}"})
    end
  end

  # ── Assistant tool handlers (task-based flow) ──────────────────────────────

  # The Assistant chose the Worker path. Insert a task row and spawn a worker
  # bound to that task_id. The TaskRuntime watches worker_status for completion.
  defp handle_handoff_to_worker(calls, command, state, session_data) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    user_id = state.user_id

    task_desc  = assistant_arg(calls, "handoff_to_worker", "task")      || "Task requested by user"
    task_title  = assistant_arg(calls, "handoff_to_worker", "task_title") || short_title(task_desc)
    intvl_str  = assistant_arg(calls, "handoff_to_worker", "intvl_sec")
    intvl_sec  = parse_int(intvl_str, 0)
    task_type   = if intvl_sec > 0, do: "periodic", else: "one_off"
    ack        = assistant_arg(calls, "handoff_to_worker", "ack") || "Working on it — I'll report back."
    language   = normalise_lang(assistant_arg(calls, "handoff_to_worker", "language"))
    origin     = session_origin(session_data)

    # Build the attachment section for the task_spec.
    # Path 1 (normal): FE pre-allocated a task_id and uploaded files to the task workspace.
    #   → wait for those files and inject workspace/<name> paths.
    # Path 2 (fallback): reservation failed and the FE sent inline base64 images.
    #   → save them to the session data_dir and inject data/<name> paths.
    # In both cases the task_spec contains ONLY file paths — never inline descriptions.
    pre_task_id       = command.task_id
    attachment_names = command.attachment_names

    media_context =
      cond do
        pre_task_id && attachment_names != [] ->
          email     = Tasks.lookup_user_email(user_id)
          workspace = Dmhai.Constants.task_workspace_dir(email, session_id, origin, pre_task_id)
          case wait_for_attachments(workspace, attachment_names) do
            :ok      -> build_attachment_section("workspace", attachment_names)
            :timeout -> build_attachment_section("workspace", attachment_names) <>
                        "\n[Warning: some attachments may not have uploaded in time — worker will handle missing files gracefully]"
          end

        command.images != [] ->
          email    = Tasks.lookup_user_email(user_id)
          data_dir = Dmhai.Constants.session_data_dir(email, session_id)
          File.mkdir_p(data_dir)
          saved = save_inline_images(command.images, command.image_names, data_dir)
          Logger.warning("[UserAgent] FE did not pre-upload #{length(saved)} image(s); saved to data_dir as fallback")
          build_attachment_section("data", saved)

        true ->
          nil
      end

    full_task =
      if media_context, do: task_desc <> "\n\n" <> media_context, else: task_desc

    task_id =
      Tasks.insert(
        task_id:     pre_task_id,
        user_id:    user_id,
        session_id: session_id,
        task_type:   task_type,
        intvl_sec:  intvl_sec,
        task_title:  task_title,
        task_spec:   full_task,
        task_status: "pending",
        language:   language,
        pipeline:   "assistant",
        origin:     origin
      )

    Logger.info("[UserAgent] worker task=#{task_id} type=#{task_type} intvl=#{intvl_sec} title=#{task_title}")

    # Delegate to TaskRuntime to spawn the worker + start watchdog/poller.
    Dmhai.Agent.TaskRuntime.start_task(task_id)

    append_session_message(session_id, user_id, %{
      role: "assistant",
      content: ack,
      ts: System.os_time(:millisecond)
    })

    send(reply_pid, {:chunk, ack})
    send(reply_pid, {:done, %{task_created: true}})
  end

  # Poll until all expected attachment files exist in the task workspace.
  # Uploads are fast (scaled-down files) so this typically resolves before
  # the LLM even responds. Logs a warning and continues on timeout rather
  # than blocking the task indefinitely.
  @attachment_wait_timeout_ms 30_000
  @attachment_poll_ms 200

  defp wait_for_attachments(workspace, names) do
    deadline = System.os_time(:millisecond) + @attachment_wait_timeout_ms
    do_wait_attachments(workspace, names, deadline)
  end

  defp do_wait_attachments(workspace, names, deadline) do
    missing = Enum.reject(names, &File.exists?(Path.join(workspace, &1)))

    cond do
      missing == [] ->
        :ok

      System.os_time(:millisecond) >= deadline ->
        Logger.warning("[UserAgent] attachment wait timed out; missing: #{inspect(missing)}")
        :timeout

      true ->
        Process.sleep(@attachment_poll_ms)
        do_wait_attachments(workspace, names, deadline)
    end
  end

  defp build_attachment_section(prefix, names) do
    lines = Enum.map_join(names, "\n", fn name -> "- #{prefix}/#{name}" end)
    "[Attached files — use extract_content on these paths as needed]\n#{lines}"
  end

  defp save_inline_images(images, names, data_dir) do
    images
    |> Enum.with_index()
    |> Enum.flat_map(fn {b64, i} ->
      name = Enum.at(names, i) || "image_#{i + 1}.jpg"
      path = Path.join(data_dir, name)
      case Base.decode64(b64, ignore: :whitespace) do
        {:ok, bin} ->
          File.write!(path, bin)
          [name]
        :error ->
          Logger.warning("[UserAgent] could not decode inline image #{name} — skipping")
          []
      end
    end)
  end

  defp handle_set_periodic(calls, command, _state) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    task_id    = assistant_arg(calls, "set_periodic_for_task", "task_id")
    intvl_str = assistant_arg(calls, "set_periodic_for_task", "intvl_sec")
    ack       = assistant_arg(calls, "set_periodic_for_task", "ack") || "Scheduled."
    intvl_sec = parse_int(intvl_str, 0)
    task       = task_id && Tasks.get(task_id)
    lang      = (task && task.language) || "en"

    msg =
      cond do
        task_id in [nil, ""] -> Dmhai.I18n.t("no_task_id", lang)
        intvl_sec <= 0      -> Dmhai.I18n.t("bad_interval", lang)
        is_nil(task)         -> Dmhai.I18n.t("no_such_task", lang)
        true ->
          Tasks.set_periodic(task_id, intvl_sec)
          ack
      end

    user_id = (task && task.user_id) || "system"
    append_session_message(session_id, user_id, %{
      role: "assistant",
      content: msg,
      ts: System.os_time(:millisecond)
    })

    send(reply_pid, {:chunk, msg})
    send(reply_pid, {:done, %{}})
  end

  defp handle_cancel_task(calls, command, _state) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    task_id = assistant_arg(calls, "cancel_task", "task_id")
    ack    = assistant_arg(calls, "cancel_task", "ack") || "Job cancelled."
    task    = task_id && Tasks.get(task_id)
    lang   = (task && task.language) || "en"

    msg =
      case task do
        nil  -> Dmhai.I18n.t("no_such_task", lang)
        _job ->
          Dmhai.Agent.TaskRuntime.cancel_task(task_id)
          ack
      end

    user_id = task && task.user_id

    if user_id do
      append_session_message(session_id, user_id, %{
        role: "assistant",
        content: msg,
        ts: System.os_time(:millisecond)
      })
    end

    send(reply_pid, {:chunk, msg})
    send(reply_pid, {:done, %{}})
  end

  defp handle_pause_task(calls, command, _state) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    task_id = assistant_arg(calls, "pause_task", "task_id")
    ack    = assistant_arg(calls, "pause_task", "ack")
    task    = task_id && Tasks.get(task_id)
    lang   = (task && task.language) || "en"

    msg =
      case task do
        nil  -> Dmhai.I18n.t("no_such_task", lang)
        _job ->
          Dmhai.Agent.TaskRuntime.pause_task(task_id)
          ack || Dmhai.I18n.t("task_paused", lang, %{title: task.task_title})
      end

    user_id = task && task.user_id

    if user_id do
      append_session_message(session_id, user_id, %{
        role: "assistant",
        content: msg,
        ts: System.os_time(:millisecond)
      })
    end

    send(reply_pid, {:chunk, msg})
    send(reply_pid, {:done, %{}})
  end

  defp handle_resume_task(calls, command, _state) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    task_id = assistant_arg(calls, "resume_task", "task_id")
    ack    = assistant_arg(calls, "resume_task", "ack")
    task    = task_id && Tasks.get(task_id)
    lang   = (task && task.language) || "en"

    msg =
      case task do
        nil  -> Dmhai.I18n.t("no_such_task", lang)
        _job ->
          Dmhai.Agent.TaskRuntime.resume_task(task_id)
          ack || Dmhai.I18n.t("task_resumed", lang, %{title: task.task_title})
      end

    user_id = task && task.user_id

    if user_id do
      append_session_message(session_id, user_id, %{
        role: "assistant",
        content: msg,
        ts: System.os_time(:millisecond)
      })
    end

    send(reply_pid, {:chunk, msg})
    send(reply_pid, {:done, %{}})
  end

  # User explicitly asked about a task — reuse the same summarizer path as the
  # runtime's unsolicited push. force: true so we always produce output (even
  # "no new activity since the last update"). The summarizer appends a
  # progress message to the session AND pings the notification bus, so the
  # frontend reloads and renders.
  defp handle_read_task_status(calls, command, _state) do
    %Command{reply_pid: reply_pid} = command
    task_id = assistant_arg(calls, "read_task_status", "task_id")

    case task_id && Tasks.get(task_id) do
      nil ->
        msg = Dmhai.I18n.t("task_not_found", "en", %{id: inspect(task_id)})
        send(reply_pid, {:chunk, msg})
        send(reply_pid, {:done, %{content: msg}})

      task ->
        lang = task.language || "en"
        # Terminal/quiescent tasks: render stored result directly, no LLM call.
        case task.task_status do
          status when status in ["done", "blocked", "cancelled", "paused"] ->
            status_label = Dmhai.I18n.t("status_#{status}", lang)
            result_text  = task.task_result || Dmhai.I18n.t("no_result", lang)
            body = Dmhai.I18n.t("task_status_rendered", lang, %{
              title: task.task_title,
              status: status_label,
              result: result_text
            })
            send(reply_pid, {:chunk, body})
            send(reply_pid, {:done, %{content: body}})

          _ ->
            # Running/pending — delta-only summary via the shared summarizer.
            Task.start(fn ->
              case Dmhai.Agent.TaskRuntime.summarize_and_announce(task_id, force: true) do
                {:ok, text} ->
                  send(reply_pid, {:chunk, text})
                  send(reply_pid, {:done, %{content: text}})

                {:skipped, text} ->
                  send(reply_pid, {:chunk, text})
                  send(reply_pid, {:done, %{content: text}})

                {:error, reason} ->
                  send(reply_pid, {:error, "Could not summarize: #{inspect(reason)}"})
              end
            end)
        end
    end
  end

  # ── Assistant tool schemas ────────────────────────────────────────────────

  defp handoff_to_worker_json_schema_def do
    %{
      name: "handoff_to_worker",
      description:
        "Hand off a task to a background worker. Use for: research, file operations, " <>
          "calculations, multi-step work, AND any periodic task (monitor CPU every N sec, " <>
          "daily research, recurring reports). For periodic tasks, set intvl_sec > 0 " <>
          "(the worker itself never sees the interval — the runtime schedules re-runs). " <>
          "The worker has tools: bash, web fetch/search, file io, calculator, date/time, media/doc parsers. " <>
          "It signals completion via task_signal(TASK_DONE|TASK_BLOCKED).",
      parameters: %{
        type: "object",
        properties: %{
          task_title: %{
            type: "string",
            description: "A short (2-6 word) title for the task, in the user's language."
          },
          task: %{
            type: "string",
            description:
              "The verbatim user message — copy it exactly as written. " <>
                "Do NOT rephrase, summarise, or interpret. " <>
                "Attached file paths (if any) are appended automatically by the system. " <>
                "For periodic tasks, do NOT mention the schedule — the worker runs as a one-off each cycle."
          },
          intvl_sec: %{
            type: "integer",
            description:
              "Interval in seconds between runs for a periodic task. " <>
                "Set to 0 for one-off. Examples: 10 = every 10 s, 3600 = hourly, 86400 = daily."
          },
          ack: %{
            type: "string",
            description: "Brief acknowledgment shown to the user while the task runs. In the user's language."
          },
          language: %{
            type: "string",
            description: "ISO 639-1 code of the user's language (e.g. 'en', 'vi', 'es', 'fr', 'ja', 'zh', 'de')."
          }
        },
        required: ["task_title", "task", "ack", "language"]
      }
    }
  end

  defp set_periodic_for_task_json_schema_def do
    %{
      name: "set_periodic_for_task",
      description:
        "Turn an existing task into a periodic one (or update its interval). Use when the user says " <>
          "something like 'run this every hour' or 'repeat daily' about a task that's already running.",
      parameters: %{
        type: "object",
        properties: %{
          task_id:    %{type: "string", description: "The task_id to update."},
          intvl_sec: %{type: "integer", description: "New interval in seconds (> 0)."},
          ack:       %{type: "string", description: "Confirmation shown to the user."}
        },
        required: ["task_id", "intvl_sec", "ack"]
      }
    }
  end

  defp pause_task_json_schema_def do
    %{
      name: "pause_task",
      description:
        "Temporarily pause a running or pending task. The worker is stopped but task data is " <>
          "preserved — the task can be resumed later with resume_job. Use for 'pause X', 'hold X', 'stop X for now'.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string", description: "The task_id to pause."},
          ack:    %{type: "string", description: "Confirmation shown to the user, in their language."}
        },
        required: ["task_id", "ack"]
      }
    }
  end

  defp resume_task_json_schema_def do
    %{
      name: "resume_task",
      description:
        "Resume a previously paused task. The worker restarts from the beginning of its task spec. " <>
          "Use for 'resume X', 'continue X', 'restart X'.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string", description: "The task_id to resume."},
          ack:    %{type: "string", description: "Confirmation shown to the user, in their language."}
        },
        required: ["task_id", "ack"]
      }
    }
  end

  defp cancel_task_json_schema_def do
    %{
      name: "cancel_task",
      description:
        "Permanently cancel a task by id. Stops any in-flight worker and prevents future runs. " <>
          "Cannot be undone. Use for 'stop X', 'cancel X', 'kill X'.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string", description: "The task_id to cancel."},
          ack:    %{type: "string", description: "Confirmation shown to the user."}
        },
        required: ["task_id", "ack"]
      }
    }
  end

  defp read_task_status_json_schema_def do
    %{
      name: "read_task_status",
      description:
        "Fetch status + recent progress for a task. Use when the user asks " <>
          "'how is X going?' / 'what happened to Y?' / 'show me the report'.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string", description: "The task_id to query."}
        },
        required: ["task_id"]
      }
    }
  end

  # ── small helpers ─────────────────────────────────────────────────────────

  defp assistant_arg(calls, tool_name, key) do
    Enum.find_value(calls, nil, fn call ->
      if get_in(call, ["function", "name"]) == tool_name do
        args = get_in(call, ["function", "arguments"]) || %{}
        args =
          case args do
            a when is_map(a)    -> a
            a when is_binary(a) -> (case Jason.decode(a) do {:ok, m} -> m; _ -> %{} end)
          end
        args[key]
      end
    end)
  end

  defp parse_int(v, _default) when is_integer(v), do: v
  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _      -> default
    end
  end
  defp parse_int(_, default), do: default

  # Derive the session's origin ("assistant" | "confidant") from its mode.
  # Used to bucket tasks into the correct filesystem subtree regardless of
  # which handoff pipeline (resolver/worker) executed them.
  defp session_origin(session_data) do
    case session_data && session_data["mode"] do
      "confidant" -> "confidant"
      _           -> "assistant"
    end
  end

  # Normalise an LLM-supplied language field down to a 2-letter lowercase code.
  # Rejects junk (empty, nil, more than a few chars). Falls back to "en".
  defp normalise_lang(nil), do: "en"
  defp normalise_lang(""), do: "en"
  defp normalise_lang(v) when is_binary(v) do
    code =
      v
      |> String.downcase()
      |> String.trim()
      |> String.split(~r/[_\-]/)
      |> List.first()

    if is_binary(code) and String.length(code) in 2..3, do: code, else: "en"
  end
  defp normalise_lang(_), do: "en"

  # ── Language detection ────────────────────────────────────────────────────

  # Strip http(s) URLs from text, then ask a tiny LLM to identify the language.
  # Returns an ISO 639-1 code (e.g. "en", "vi") or nil when the model returns
  # UNKNOWN — nil means the master will fall back to its own detection.
  @url_strip_regex ~r{https?://\S+}

  defp detect_content_language(content) when is_binary(content) and content != "" do
    stripped = Regex.replace(@url_strip_regex, content, "") |> String.trim()
    words    = String.split(stripped, ~r/\s+/, trim: true)

    if stripped == "" or length(words) < 5 do
      nil
    else
      model = AgentSettings.language_detector_model()

      prompt =
        "Detect the language of the following text.\n" <>
          "Reply with ONLY the ISO 639-1 two-letter code (e.g. en, vi, es, fr, ja, zh, de, ko, pt, it).\n" <>
          "If you cannot determine the language, reply with UNKNOWN.\n" <>
          "Do not include any explanation, punctuation, or extra words — just the code.\n\n" <>
          "Text: #{stripped}"

      try do
        trace = %{origin: "assistant", path: "UserAgent.detect_content_language", role: "LanguageDetector", phase: "detect"}
        case LLM.call(model, [%{role: "user", content: prompt}],
               options: %{temperature: 0, num_predict: 10},
               trace: trace
             ) do
          {:ok, response} -> parse_language_code(response)
          {:error, _}     -> nil
        end
      rescue
        _ -> nil
      end
    end
  end

  defp detect_content_language(_), do: nil

  defp parse_language_code(response) do
    code =
      response
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z]/, "")

    cond do
      code == "unknown"                    -> nil
      String.length(code) in 2..3         -> code
      true                                 -> nil
    end
  end

  defp short_title(nil), do: "Untitled task"
  defp short_title(""),  do: "Untitled task"
  defp short_title(content) do
    content
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(6)
    |> Enum.join(" ")
  end

  # Load session model + full session data (messages + context + mode) from DB.
  # Returns {:ok, model, %{"messages" => [...], "context" => %{...}, "mode" => "confidant"|"assistant"}}
  defp load_session(session_id, user_id) do
    try do
      result =
        query!(Repo, "SELECT model, messages, context, mode FROM sessions WHERE id=? AND user_id=?",
               [session_id, user_id])

      case result.rows do
        [[model, msgs_json, ctx_json, mode]] ->
          messages = Jason.decode!(msgs_json || "[]")

          context =
            case Jason.decode(ctx_json || "{}") do
              {:ok, m} when is_map(m) -> m
              _                       -> %{}
            end

          {:ok, model || "", %{"messages" => messages, "context" => context, "mode" => mode || "confidant"}}

        _ ->
          {:error, "Session not found"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ─── Helpers for pipeline context ─────────────────────────────────────────

  # Extract last few messages as plain text for web search detection context.
  # Extract last 10 user messages (300 chars each) for search query generation.
  defp extract_user_messages(session_data) do
    messages = session_data["messages"] || []

    messages
    |> Enum.filter(fn m -> m["role"] == "user" end)
    |> Enum.take(-10)
    |> Enum.map(fn m -> String.slice(m["content"] || "", 0, 300) end)
  end

  defp build_web_context(_content, %{snippets: [], pages: []}, _reply_pid), do: nil

  defp build_web_context(_content, result_map, reply_pid) do
    raw = format_raw_results(result_map)

    if raw == "" do
      nil
    else
      if String.length(raw) > AgentSettings.synthesis_threshold() do
        send(reply_pid, {:status, "🧠 Synthesizing results..."})

        case WebSearch.synthesize_results(raw) do
          {:ok, synthesis} when is_binary(synthesis) and synthesis != "" ->
            Logger.info("[UserAgent] synthesis ok chars=#{String.length(synthesis)}")
            synthesis

          _ ->
            Logger.info("[UserAgent] synthesis failed, truncating raw results")
            String.slice(raw, 0, AgentSettings.synthesis_fallback_chars())
        end
      else
        raw
      end
    end
  end

  # Format search results as a numbered list matching the original formatSearchResults.
  # For each result: prefers fetched page content, falls back to SearXNG snippet.
  defp format_raw_results(%{snippets: snippets, pages: pages}) do
    pages_by_url = Map.new(pages, fn p -> {p.url, p.content} end)

    snippets
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {s, i} ->
      content = Map.get(pages_by_url, s.url) || s.snippet

      if content != "" do
        ["#{i}. #{s.title}\n#{content}"]
      else
        []
      end
    end)
    |> Enum.join("\n\n")
  end

  # Load stored photo descriptions for a session (keeps context across reloads).
  defp load_image_descriptions(session_id) do
    try do
      result = query!(Repo, "SELECT name, description FROM image_descriptions WHERE session_id=?",
                      [session_id])
      Enum.map(result.rows, fn [name, desc] -> %{name: name, description: desc} end)
    rescue
      _ -> []
    end
  end

  # Load stored video descriptions for a session (keeps context across reloads).
  defp load_video_descriptions(session_id) do
    try do
      result = query!(Repo, "SELECT name, description FROM video_descriptions WHERE session_id=?",
                      [session_id])
      Enum.map(result.rows, fn [name, desc] -> %{name: name, description: desc} end)
    rescue
      _ -> []
    end
  end

  # Route to the appropriate describer based on media type.
  # When a pre-computed description exists in DB, pass empty images to master
  # (the description is injected via the system prompt instead).
  # When no description exists yet, pass raw images directly so master can answer.
  defp effective_images(command, image_descriptions, video_descriptions) do
    cond do
      command.images == [] ->
        []

      command.has_video ->
        video_name = List.first(command.image_names) || "video"
        if Enum.any?(video_descriptions, &(&1.name == video_name)), do: [], else: command.images

      true ->
        all_described? = Enum.all?(command.image_names, fn name ->
          Enum.any?(image_descriptions, &(&1.name == name))
        end)
        if all_described?, do: [], else: command.images
    end
  end

  # Load the user's profile text from the users table.
  defp load_user_profile(user_id) do
    try do
      result = query!(Repo, "SELECT profile FROM users WHERE id=?", [user_id])

      case result.rows do
        [[profile] | _] -> profile || ""
        _               -> ""
      end
    rescue
      _ -> ""
    end
  end


  # Reload session data after a response and compact if thresholds are exceeded.
  # Runs in a background Task — failures are logged but do not affect the user.
  defp maybe_compact(session_id, user_id) do
    try do
      result =
        query!(Repo, "SELECT messages, context FROM sessions WHERE id=? AND user_id=?",
               [session_id, user_id])

      case result.rows do
        [[msgs_json, ctx_json]] ->
          context =
            case Jason.decode(ctx_json || "{}") do
              {:ok, m} when is_map(m) -> m
              _                       -> %{}
            end

          session_data = %{
            "messages" => Jason.decode!(msgs_json || "[]"),
            "context"  => context
          }

          if ContextEngine.should_compact?(session_data) do
            Logger.info("[UserAgent] compaction triggered session=#{session_id}")
            ContextEngine.compact!(session_id, user_id, session_data)
          end

        _ ->
          :ok
      end
    rescue
      e -> Logger.error("[UserAgent] maybe_compact failed: #{Exception.message(e)}")
    end
  end

  defp log_llm_messages(messages) do
    non_sys = Enum.reject(messages, fn m -> (m[:role] || m["role"]) == "system" end)
    parts = Enum.map(non_sys, fn m ->
      role    = m[:role]       || m["role"]       || "?"
      content = m[:content]    || m["content"]    || ""
      calls   = m[:tool_calls] || m["tool_calls"] || []
      if is_list(calls) and calls != [] do
        names = Enum.map_join(calls, ",", fn c -> get_in(c, ["function", "name"]) || "?" end)
        "[#{role}→#{names}]"
      else
        snippet = content |> to_string() |> String.slice(0, 100) |> String.replace("\n", "↵")
        "[#{role}]#{snippet}"
      end
    end)
    result = Enum.join(parts, " | ")
    if String.length(result) > 1000, do: String.slice(result, 0, 1000) <> "…", else: result
  end
end
