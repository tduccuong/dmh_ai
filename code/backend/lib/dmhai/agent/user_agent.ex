# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.UserAgent do
  @idle_timeout :timer.minutes(30)

  @moduledoc """
  Per-user agent (GenServer).

  Lifecycle
  ---------
  Started lazily by Dmhai.Agent.Supervisor.ensure_started/1 on first command.
  Shuts itself down after 30 minutes of idle.
  State that must survive restarts is kept in-memory only for now — a crash
  means in-flight inline tasks are lost and the agent restarts clean.
  Persistence can be added later.

  Strict path separation
  ----------------------
  The Assistant and Confidant paths do NOT share a dispatcher. Each mode has
  its own command type and its own dispatch message:

    {:dispatch_assistant, %AssistantCommand{}} → run_assistant/3
    {:dispatch_confidant, %ConfidantCommand{}} → run_confidant/3
    {:dispatch, :interrupt}                    → cancel_current_task/1
      (the only cross-path message — cancellation is mode-agnostic)

  The mode branch is taken by the HTTP handler *before* it builds a command,
  so a body field for one path can never reach the other. See
  specs/architecture.md §Request Lifecycle.

  Execution paths
  ---------------
  1. Inline         — short/streaming tasks (answer, search, tool call).
                      A Task runs under Dmhai.Agent.TaskSupervisor, sends
                      {:chunk, text} / {:done, result} directly to reply_pid,
                      then exits. The GenServer monitors it and clears state on done.

  2. Assistant Loop — long/async tasks (the Assistant classifier calls
                      `create_task`; a fresh loop runs under
                      Dmhai.Agent.AssistantLoopSupervisor). The HTTP connection
                      is already closed (ack was sent). When the loop finishes
                      it writes a new assistant message and fires
                      MsgGateway.notify/2.
  """

  use GenServer
  require Logger

  alias Dmhai.Agent.{AgentSettings, AssistantCommand, ConfidantCommand, ContextEngine,
                     LLM, ProfileExtractor, StreamBuffer, Supervisor, Tasks,
                     TokenTracker, WebSearch}
  alias Dmhai.Web.Search, as: WebSearchEngine
  # WebSearch kept for synthesize_results used in build_web_context
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # ─── State ────────────────────────────────────────────────────────────────

  defstruct [
    :user_id,
    # current inline task: nil | {task_ref, reply_pid, session_id}
    # session_id is retained so that on turn completion we can check
    # Tasks.fetch_next_due/1 and auto-chain the next pending task.
    current_task: nil,
    # per-platform opaque state (e.g. %{telegram: %{chat_id: "123"}})
    platform_state: %{}
  ]

  # ─── Client API ───────────────────────────────────────────────────────────

  @doc "Dispatch an AssistantCommand to the user's agent, starting it if needed."
  @spec dispatch_assistant(String.t(), AssistantCommand.t()) :: :ok | {:error, term()}
  def dispatch_assistant(user_id, %AssistantCommand{} = command) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, {:dispatch_assistant, command}, :infinity)
    end
  end

  @doc "Dispatch a ConfidantCommand to the user's agent, starting it if needed."
  @spec dispatch_confidant(String.t(), ConfidantCommand.t()) :: :ok | {:error, term()}
  def dispatch_confidant(user_id, %ConfidantCommand{} = command) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, {:dispatch_confidant, command}, :infinity)
    end
  end

  @doc "Interrupt the current inline task (mode-agnostic)."
  @spec interrupt(String.t()) :: :ok
  def interrupt(user_id) do
    case Registry.lookup(Dmhai.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, {:dispatch, :interrupt})
      []         -> :ok
    end
  end

  @doc "Cancel all active tasks for a specific session (called on session delete)."
  @spec cancel_session_tasks(String.t(), String.t()) :: :ok
  def cancel_session_tasks(_user_id, session_id) do
    session_id
    |> Tasks.active_for_session()
    |> Enum.each(fn task -> Tasks.mark_cancelled(task.task_id) end)
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

  # Dispatch — interrupt is the only message type that serves both paths.
  @impl true
  def handle_call({:dispatch, :interrupt}, _from, state) do
    state = cancel_current_task(state)
    {:reply, :ok, state, @idle_timeout}
  end

  # Assistant path — strictly separated from Confidant. Requires a loaded
  # session in "assistant" mode; mismatched mode is a handler bug and gets
  # refused here as a safety net.
  def handle_call({:dispatch_assistant, %AssistantCommand{} = command}, _from, state) do
    dispatch_run(command, state, fn session_data ->
      run_assistant(command, state, session_data)
    end, required_mode: "assistant")
  end

  def handle_call({:dispatch_confidant, %ConfidantCommand{} = command}, _from, state) do
    dispatch_run(command, state, fn session_data ->
      run_confidant(command, state, session_data)
    end, required_mode: "confidant")
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

  # Inline task completed normally — {ref, result} message from Task.
  # On completion, auto-chain: check if the same session has another
  # pending task with `time_to_pickup <= now`. If so, self-send
  # {:task_due, task_id} so the next turn runs silently for that task.
  @impl true
  def handle_info({ref, _result}, %{current_task: {ref, _reply_pid, session_id}} = state) do
    Process.demonitor(ref, [:flush])
    maybe_trigger_next_due(session_id)
    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  # Stray {ref, _result} from tasks we no longer track — swallow.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state, @idle_timeout}
  end

  # Inline task crashed
  def handle_info({:DOWN, ref, :task, _pid, reason}, %{current_task: {ref, reply_pid, _sid}} = state) do
    Logger.error("[UserAgent] inline task crashed user=#{state.user_id} reason=#{inspect(reason)}")
    send(reply_pid, {:error, "Internal error — please try again"})
    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  # Stray DOWN — swallow. (Was used for the old worker tracking; TaskRuntime owns workers now.)
  def handle_info({:DOWN, _ref, _type, _pid, _reason}, state) do
    {:noreply, state, @idle_timeout}
  end

  # Auto-chain pickup: either fired by TaskRuntime's periodic timer or
  # self-sent by `maybe_trigger_next_due/1` after the previous turn
  # completed. If the agent is idle, run a silent turn for this task —
  # no user waiting, so progress streams to a throwaway pid while
  # session_progress + the final assistant message persist to DB. FE
  # picks them up via polling.
  def handle_info({:task_due, task_id}, %{current_task: nil} = state) do
    case Tasks.get(task_id) do
      %{task_status: "pending", session_id: session_id} = task ->
        start_silent_turn(task, session_id, state)

      _ ->
        # Task disappeared, already done, or flipped to paused/cancelled.
        {:noreply, state, @idle_timeout}
    end
  end

  # Agent is busy — drop the message. The post-completion
  # `maybe_trigger_next_due/1` path will pick it up after the current
  # turn finishes, so we don't need to re-queue.
  def handle_info({:task_due, _task_id}, state) do
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

  defp cancel_current_task(%{current_task: {_ref, reply_pid, _sid}} = state) do
    send(reply_pid, {:error, :interrupted})
    %{state | current_task: nil}
  end

  # Post-turn hook: check for another pending task in the same session
  # whose pickup is due (time_to_pickup <= now). If found, self-send
  # {:task_due, task_id} so the agent picks it up automatically.
  defp maybe_trigger_next_due(session_id) do
    case Tasks.fetch_next_due(session_id) do
      nil -> :ok
      %{task_id: tid} -> send(self(), {:task_due, tid})
    end
  end

  # Start an auto-triggered turn for a task picked off the pending queue.
  # Output lands in DB (session_progress, sessions.messages, stream_buffer)
  # exactly as for a user-initiated turn; FE polling renders it.
  defp start_silent_turn(task, session_id, state) do
    task_id = task.task_id

    spawned =
      Task.Supervisor.async_nolink(Dmhai.Agent.TaskSupervisor, fn ->
        case load_session(session_id, state.user_id) do
          {:ok, _model, session_data} ->
            if (session_data["mode"] || "confidant") == "assistant" do
              run_assistant_silent(task, session_data, state.user_id)
            else
              Logger.warning("[UserAgent] skipping auto task-due for non-assistant session=#{session_id}")
            end

          {:error, reason} ->
            Logger.warning("[UserAgent] auto task-due load failed session=#{session_id} task=#{task_id} reason=#{inspect(reason)}")
        end
      end)

    # reply_pid has no purpose in fire-and-forget / polling architecture;
    # we still carry a dummy value in the state tuple for structural
    # consistency with user-initiated turns (see :handle_info({ref, _})).
    dummy_pid = spawn(fn -> :ok end)
    {:noreply, %{state | current_task: {spawned.ref, dummy_pid, session_id}}, @idle_timeout}
  end

  # Silent equivalent of run_assistant for auto-triggered task pickups.
  # Builds context like normal BUT appends a synthetic trailing user-role
  # message to the LLM context only (NOT persisted to session.messages)
  # that says "[Task due: …] — pick it up now". The model then responds
  # as it would to a real user ask. The final assistant text IS persisted
  # so next turn's LLM context carries the audit trail.
  defp run_assistant_silent(task, session_data, user_id) do
    model   = AgentSettings.assistant_model()
    profile = load_user_profile(user_id)
    email   = Tasks.lookup_user_email(user_id)
    session_id = task.session_id

    active_tasks = Tasks.active_for_session(session_id)
    recent_done  = Tasks.recent_done_for_session(session_id)

    llm_messages =
      ContextEngine.build_assistant_messages(session_data,
        profile:      profile,
        active_tasks: active_tasks,
        recent_done:  recent_done,
        files:        []
      )

    # Append synthetic "task due" instruction as the last user-role turn
    # so the model knows what to act on. Not persisted — it's an internal
    # prompt, not user input. The model's final assistant text IS persisted
    # via append_session_message below.
    synthetic = %{role: "user",
                  content: "[Task due: `#{task.task_id}` — #{task.task_title}] " <>
                           "Pick this task up now. Run whatever execution tools you need, " <>
                           "then call update_task(status: \"done\", task_result: ...) when finished."}

    llm_messages = llm_messages ++ [synthetic]

    data_dir      = Dmhai.Constants.session_data_dir(email, session_id)
    workspace_dir = Dmhai.Constants.session_workspace_dir(email, session_id)
    File.mkdir_p(data_dir)
    File.mkdir_p(workspace_dir)

    ctx = %{
      user_id:       user_id,
      user_email:    email,
      session_id:    session_id,
      session_root:  Dmhai.Constants.session_root(email, session_id),
      data_dir:      data_dir,
      workspace_dir: workspace_dir,
      log_trace:     AgentSettings.log_trace()
    }

    Dmhai.SysLog.log("[ASSISTANT:auto] user=#{user_id} session=#{session_id} task=#{task.task_id} title=#{String.slice(task.task_title || "", 0, 60)}")

    session_turn_loop(llm_messages, model, ctx, 0)

    Task.start(fn -> maybe_compact(session_id, user_id) end)
  end

  # Append a message map to the session's messages JSON column in DB.
  # Stamps the message's `ts` from the BE clock (overwriting any incoming
  # value) per CLAUDE.md rule #9 — the BE is the authority for every
  # persisted timestamp. Returns {:ok, ts_ms} so callers can echo the
  # timestamp back on the wire (e.g. in the final /agent/chat SSE frame).
  defp append_session_message(session_id, user_id, message) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                      [session_id, user_id])

      case result.rows do
        [[msgs_json]] ->
          msgs = Jason.decode!(msgs_json || "[]")
          now  = System.os_time(:millisecond)
          stamped = Map.put(message, :ts, now)
          updated = Jason.encode!(msgs ++ [stamped])
          query!(Repo, "UPDATE sessions SET messages=?, updated_at=? WHERE id=?",
                 [updated, now, session_id])
          {:ok, now}

        _ ->
          Logger.warning("[UserAgent] session not found id=#{session_id}")
          {:error, :session_not_found}
      end
    rescue
      e ->
        Logger.error("[UserAgent] append_session_message failed: #{Exception.message(e)}")
        {:error, :exception}
    end
  end


  # ─── Dispatch helper (inline task lifecycle) ──────────────────────────────
  #
  # Handles the common busy-check + Task.Supervisor.async_nolink spawn + session
  # load, then hands off to the mode-specific pipeline via `run_fn`. Each
  # dispatch_* handler supplies its own run_fn, so the two pipelines never
  # cross paths here.
  defp dispatch_run(command, state, run_fn, opts) do
    required_mode = Keyword.fetch!(opts, :required_mode)
    reply_pid     = command.reply_pid

    if state.current_task do
      send(reply_pid, {:error, :busy})
      {:reply, {:error, :busy}, state, @idle_timeout}
    else
      task =
        Task.Supervisor.async_nolink(Dmhai.Agent.TaskSupervisor, fn ->
          case load_session(command.session_id, state.user_id) do
            {:ok, _model, session_data} ->
              actual_mode = session_data["mode"] || "confidant"

              if actual_mode == required_mode do
                run_fn.(session_data)
              else
                # Shouldn't happen — the HTTP handler checks mode before
                # building the command. Refuse loudly if it does.
                Logger.error("[UserAgent] mode mismatch: session=#{actual_mode} dispatch=#{required_mode}")
                send(reply_pid, {:error, :mode_mismatch})
              end

            {:error, reason} ->
              send(reply_pid, {:error, reason})
          end
        end)

      {:reply, :ok, %{state | current_task: {task.ref, reply_pid, command.session_id}}, @idle_timeout}
    end
  end

  # ─── Confidant pipeline ─────────────────────────────────────────────────
  # Fire-and-forget: detect web search → maybe fetch → stream LLM tokens
  # into `sessions.stream_buffer`. FE polls the column for progressive text.

  defp run_confidant(%ConfidantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.confidant_model()

    web_context =
      if command.content != "" do
        user_msgs = extract_user_messages(session_data)
        # `reply_pid: nil` — web-search status lines (🔍, 📄) no longer go
        # over the wire; the FE sees the web-search's final context as
        # part of the LLM's answer and as session_progress rows elsewhere.
        case WebSearchEngine.search(command.content, user_msgs, :confidant, reply_pid: nil) do
          :no_search -> nil
          result     -> build_web_context(command.content, result, nil)
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

    # Stream collector: tokens from LLM.stream flow here, where they are
    # appended to the per-session stream_buffer column. FE polling reads
    # the column and renders progressive text.
    collector = spawn_stream_collector(session_id, user_id)

    on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
    trace     = %{origin: "confidant", path: "UserAgent.run_confidant", role: "ConfidantMaster", phase: "single-turn"}

    result = LLM.stream(model, llm_messages, collector, on_tokens: on_tokens, trace: trace)
    # Synchronously wait for the collector to drain any in-flight chunks
    # and exit — prevents its final `flush/1` from racing with our clear/2
    # below, which would leave a stale (possibly empty) buffer behind.
    stop_stream_collector(collector)

    case result do
      {:ok, full_text} when full_text != "" ->
        Dmhai.SysLog.log("[CONFIDANT] response(#{String.length(full_text)} chars): #{String.slice(full_text, 0, 300)}")
        {:ok, _assistant_ts} =
          append_session_message(session_id, user_id, %{role: "assistant", content: full_text})
        StreamBuffer.clear(session_id, user_id)

        Task.start(fn -> maybe_compact(session_id, user_id) end)

        Task.start(fn ->
          ProfileExtractor.extract_and_merge(command.content, full_text, user_id)
        end)

      {:ok, ""} ->
        StreamBuffer.clear(session_id, user_id)
        Dmhai.SysLog.log("[CONFIDANT] empty response — no message persisted")

      {:error, reason} ->
        StreamBuffer.clear(session_id, user_id)
        Dmhai.SysLog.log("[CONFIDANT] ERROR: #{inspect(reason)}")
    end
  end

  # Signal the collector to flush and exit, then block until it's gone so
  # the caller's subsequent StreamBuffer operations see a quiescent column.
  defp stop_stream_collector(collector) do
    ref = Process.monitor(collector)
    send(collector, :flush_and_stop)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  # Loop process that accumulates {:chunk, token} messages from LLM.stream
  # and periodically flushes to the sessions.stream_buffer column. The FE
  # polls that column and renders the partial text in the streaming
  # placeholder until the final message lands in session.messages.
  defp spawn_stream_collector(session_id, user_id) do
    spawn(fn -> stream_collector_loop(StreamBuffer.new(session_id, user_id)) end)
  end

  defp stream_collector_loop(buf) do
    receive do
      {:chunk, token} when is_binary(token) ->
        buf |> StreamBuffer.append(token) |> StreamBuffer.maybe_flush() |> stream_collector_loop()

      {:thinking, _} ->
        # Thinking text is not surfaced in the visible stream buffer —
        # the FE renders thinking in a separate `<details>` block
        # populated only after the final message lands. Drop silently.
        stream_collector_loop(buf)

      :flush_and_stop ->
        StreamBuffer.flush(buf)
        :ok

      _ ->
        stream_collector_loop(buf)
    after
      # Safety valve: if the producer dies without sending :flush_and_stop
      # we still commit whatever we have and exit.
      120_000 -> StreamBuffer.flush(buf)
    end
  end

  # ─── Assistant pipeline ─────────────────────────────────────────────────
  #
  # The conversational session sees the stored user message (which already
  # contains `📎 workspace/<name>` lines for any attachment — inlined at
  # /agent/chat entry) and decides what to do turn-by-turn. It does NOT
  # receive inline image bytes — pixels come via `extract_content` when
  # the model decides to read a particular attachment.

  # ─── Assistant pipeline — conversational session turn (#101) ─────────────
  #
  # One LLM handles the whole conversation: sees the task list + history +
  # current input and decides what to do turn-by-turn. No plan/exec/signal
  # protocol, no classifier/loop split.

  defp run_assistant(%AssistantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.assistant_model()
    profile = load_user_profile(user_id)
    email   = Tasks.lookup_user_email(user_id)

    active_tasks = Tasks.active_for_session(session_id)
    recent_done  = Tasks.recent_done_for_session(session_id)

    llm_messages =
      ContextEngine.build_assistant_messages(session_data,
        profile:      profile,
        active_tasks: active_tasks,
        recent_done:  recent_done,
        files:        command.files
      )

    data_dir      = Dmhai.Constants.session_data_dir(email, session_id)
    workspace_dir = Dmhai.Constants.session_workspace_dir(email, session_id)
    File.mkdir_p(data_dir)
    File.mkdir_p(workspace_dir)

    ctx = %{
      user_id:       user_id,
      user_email:    email,
      session_id:    session_id,
      session_root:  Dmhai.Constants.session_root(email, session_id),
      data_dir:      data_dir,
      workspace_dir: workspace_dir,
      log_trace:     AgentSettings.log_trace()
    }

    Dmhai.SysLog.log("[ASSISTANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)}")

    session_turn_loop(llm_messages, model, ctx, 0)

    Task.start(fn ->
      maybe_compact(session_id, user_id)
      ProfileExtractor.extract_and_merge(command.content, nil, user_id)
    end)
  end

  # One LLM turn. If the model emits tool calls, execute them (persisting
  # progress rows as side effects), append their results, and recurse. If
  # the model emits text, append it to session.messages — the FE will pick
  # it up on its next poll.
  defp session_turn_loop(messages, model, ctx, round) do
    max_rounds = AgentSettings.max_assistant_tool_rounds()

    if round >= max_rounds do
      msg = Dmhai.I18n.t("turn_cap_reached", "en", %{max: max_rounds})
      {:ok, _} = append_session_message(ctx.session_id, ctx.user_id,
                                        %{role: "assistant", content: msg})
    else
      tools = Dmhai.Tools.Registry.all_definitions()

      trace = %{
        origin: "assistant",
        path: "UserAgent.session_turn",
        role: "AssistantSession",
        phase: "round#{round}"
      }

      on_tokens = fn rx, tx -> TokenTracker.add_master(ctx.session_id, ctx.user_id, rx, tx) end

      case LLM.call(model, messages, tools: tools, on_tokens: on_tokens, trace: trace) do
        {:ok, {:tool_calls, calls}} ->
          call_names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
          Dmhai.SysLog.log("[ASSISTANT] round=#{round} tool_calls=[#{call_names}]")

          assistant_msg = %{role: "assistant", content: "", tool_calls: calls}
          tool_result_msgs = execute_tools(calls, ctx)

          new_messages = messages ++ [assistant_msg] ++ tool_result_msgs
          session_turn_loop(new_messages, model, ctx, round + 1)

        {:ok, text} when is_binary(text) and text != "" ->
          Dmhai.SysLog.log("[ASSISTANT] round=#{round} text(#{String.length(text)} chars)")
          {:ok, _assistant_ts} =
            append_session_message(ctx.session_id, ctx.user_id,
                                   %{role: "assistant", content: text})

        {:ok, ""} ->
          Dmhai.SysLog.log("[ASSISTANT] round=#{round} empty response — no message persisted")

        {:error, reason} ->
          Dmhai.SysLog.log("[ASSISTANT] round=#{round} ERROR: #{inspect(reason)}")
          # Persist the error as an assistant message so the FE renders it
          # and the user sees something actionable rather than silence.
          err_text = Dmhai.I18n.t("llm_error", "en", %{reason: inspect(reason)})
          {:ok, _} = append_session_message(ctx.session_id, ctx.user_id,
                                            %{role: "assistant", content: err_text})
      end
    end
  end

  # Execute each tool call: write a pending session_progress row (spinner
  # visible on the next FE poll, max 500 ms later), run the tool via
  # ToolRegistry, flip the row to done. Returns the tool_result messages
  # for the LLM's next round.
  defp execute_tools(calls, ctx) do
    Enum.map(calls, fn call ->
      name         = get_in(call, ["function", "name"]) || ""
      args         = get_in(call, ["function", "arguments"]) || %{}
      tool_call_id = call["id"] || ""

      # Update-task side effect: when update_task(task_id, status: "ongoing")
      # fires, the current task_id becomes the active one for subsequent
      # progress rows. We infer it below from the args when present.
      progress_ctx = %{
        session_id: ctx.session_id,
        user_id:    ctx.user_id,
        task_id:    args["task_id"]
      }

      progress_label = Dmhai.Agent.ProgressLabel.format(name, args)
      {:ok, row} = Dmhai.Agent.SessionProgress.append_tool_pending(progress_ctx, progress_label)

      args_log = args |> Jason.encode!() |> String.slice(0, 600)
      Dmhai.SysLog.log("[ASSISTANT] tool=#{name} args=#{args_log}")
      exec_result = Dmhai.Tools.Registry.execute(name, args, ctx)
      Dmhai.Agent.SessionProgress.mark_tool_done(row.id)

      content =
        case exec_result do
          {:ok, result}    -> format_tool_result(result)
          {:error, reason} -> "Error: #{reason}"
        end

      %{role: "tool", content: content, tool_call_id: tool_call_id}
    end)
  end

  # Normalise a tool's {:ok, result} payload into the string that the model
  # receives as `tool` role content. Rules (see CLAUDE.md rule #10):
  #   binary → pass-through (verbatim text, e.g. stdout)
  #   map/list → pretty JSON after recursive atom/tuple normalisation
  #   number / boolean → to_string
  #   nil → ""
  #   atom → Atom.to_string
  #   anything else → JSON of the normalised value
  # NEVER `inspect/1` — it leaks Elixir syntax into the model's context.
  defp format_tool_result(result) when is_binary(result), do: result
  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(normalise_json(result), pretty: true)
  defp format_tool_result(result) when is_number(result) or is_boolean(result),
    do: to_string(result)
  defp format_tool_result(nil), do: ""
  defp format_tool_result(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_tool_result(other), do: Jason.encode!(normalise_json(other))

  # Walk nested structures, coercing Elixir-only types to JSON-native forms:
  # atoms → strings (except true/false/nil which are JSON-native),
  # tuples → lists, map keys → strings.
  defp normalise_json(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {json_key(k), normalise_json(val)} end)
  end
  defp normalise_json(v) when is_list(v), do: Enum.map(v, &normalise_json/1)
  defp normalise_json(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&normalise_json/1)
  defp normalise_json(v) when is_atom(v) and not is_boolean(v) and v != nil,
    do: Atom.to_string(v)
  defp normalise_json(v), do: v

  defp json_key(k) when is_atom(k), do: Atom.to_string(k)
  defp json_key(k) when is_binary(k), do: k
  defp json_key(k), do: to_string(k)

  # ── small helpers ─────────────────────────────────────────────────────────

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
