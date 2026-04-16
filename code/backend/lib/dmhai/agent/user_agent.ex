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

  alias Dmhai.Agent.{AgentSettings, Command, ContextEngine, LLM, MasterBuffer, ProfileExtractor, Supervisor, TokenTracker, WebSearch, Worker, WorkerState}
  alias Dmhai.{MsgGateway, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]

  # ─── State ────────────────────────────────────────────────────────────────

  defstruct [
    :user_id,
    # current inline task: nil | {task_ref, reply_pid}
    current_task: nil,
    # active detached workers: %{worker_id => %{ref, pid, session_id, description, started_at}}
    workers: %{},
    # per-platform opaque state (e.g. %{telegram: %{chat_id: "123"}})
    platform_state: %{},
    # debounce timers for trigger_master_from_buffer: %{session_id => timer_ref}
    buffer_timers: %{}
  ]

  # ─── Client API ───────────────────────────────────────────────────────────

  @doc "Route a Command to the user's agent, starting it if needed."
  @spec dispatch(String.t(), Command.t()) :: :ok | {:error, term()}
  def dispatch(user_id, %Command{} = command) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, {:dispatch, command}, :infinity)
    end
  end

  @doc "Spawn a detached worker task. Returns {:ok, worker_id} immediately.
  `task_fn` receives (agent_pid, worker_id) so it can report progress."
  @spec spawn_worker(String.t(), String.t(), String.t(), (pid(), String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_worker(user_id, session_id, description, task_fn)
      when is_binary(user_id) and is_function(task_fn, 2) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, {:spawn_worker, session_id, description, task_fn})
    end
  end

  @doc "Cancel a running worker by id. Returns :ok if found and killed."
  @spec cancel_worker(String.t(), String.t()) :: :ok | {:error, :not_found}
  def cancel_worker(user_id, worker_id) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, {:cancel_worker, worker_id})
    end
  end

  @doc "List all active workers for the user."
  @spec list_workers(String.t()) :: [map()]
  def list_workers(user_id) do
    case Registry.lookup(Dmhai.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, :list_workers)
      [] -> []
    end
  end

  @doc "Cancel all workers for a specific session (called on session delete)."
  @spec cancel_session_workers(String.t(), String.t()) :: :ok
  def cancel_session_workers(user_id, session_id) do
    case Registry.lookup(Dmhai.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, {:cancel_session_workers, session_id})
      [] -> :ok
    end
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
    agent_pid = self()

    # Re-spawn any workers that were running before a crash/restart.
    # fetch_and_claim atomically marks them 'recovering' so a second UserAgent
    # init (after idle-timeout) cannot double-claim still-live recovery tasks.
    workers =
      WorkerState.fetch_and_claim(user_id)
      |> Enum.reduce(%{}, fn checkpoint, acc ->
        task =
          Task.Supervisor.async_nolink(Dmhai.Agent.WorkerSupervisor, fn ->
            Logger.info("[Worker] recovering id=#{checkpoint.worker_id} session=#{checkpoint.session_id}")

            _result =
              try do
                Worker.run_from_checkpoint(checkpoint, agent_pid)
              rescue
                e ->
                  Logger.error("[Worker] recovery crashed id=#{checkpoint.worker_id}: #{Exception.message(e)}")
                  %{error: Exception.message(e)}
              end

            trigger_master_from_buffer(
              checkpoint.session_id, user_id, checkpoint.worker_id, checkpoint.task
            )
            MsgGateway.notify(user_id, "✓ #{checkpoint.task} — result ready in DMH-AI")
          end)

        worker = %{
          ref:        task.ref,
          pid:        task.pid,
          session_id: checkpoint.session_id,
          description: checkpoint.task,
          started_at: DateTime.utc_now(),
          progress:   []
        }

        Map.put(acc, checkpoint.worker_id, worker)
      end)

    {:ok, %__MODULE__{user_id: user_id, workers: workers}, @idle_timeout}
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

  # Spawn a detached worker
  def handle_call({:spawn_worker, session_id, description, task_fn}, _from, state) do
    worker_id = generate_id()
    user_id = state.user_id
    agent_pid = self()

    task =
      Task.Supervisor.async_nolink(Dmhai.Agent.WorkerSupervisor, fn ->
        Logger.info("[Worker] starting id=#{worker_id} session=#{session_id}")

        result =
          try do
            task_fn.(agent_pid, worker_id)
          rescue
            e ->
              Logger.error("[Worker] crashed id=#{worker_id}: #{Exception.message(e)}")
              %{error: Exception.message(e)}
          end

        # Trigger proactive master response from buffer (final worker result)
        trigger_master_from_buffer(session_id, user_id, worker_id, description)

        MsgGateway.notify(user_id, "✓ #{description} — result ready in DMH-AI")
        result
      end)

    worker = %{
      ref: task.ref,
      pid: task.pid,
      session_id: session_id,
      description: description,
      started_at: DateTime.utc_now(),
      progress: []
    }

    Logger.info("[UserAgent] spawned worker id=#{worker_id} user=#{user_id}")

    {:reply, {:ok, worker_id},
     %{state | workers: Map.put(state.workers, worker_id, worker)},
     @idle_timeout}
  end

  # Cancel a worker
  def handle_call({:cancel_worker, worker_id}, _from, state) do
    case Map.get(state.workers, worker_id) do
      nil ->
        {:reply, {:error, :not_found}, state, @idle_timeout}

      %{pid: pid} ->
        Task.Supervisor.terminate_child(Dmhai.Agent.WorkerSupervisor, pid)
        WorkerState.mark_cancelled(worker_id)
        {:reply, :ok, %{state | workers: Map.delete(state.workers, worker_id)},
         @idle_timeout}
    end
  end

  # Cancel all workers for a session (called on session delete)
  def handle_call({:cancel_session_workers, session_id}, _from, state) do
    {to_cancel, remaining} =
      Enum.split_with(state.workers, fn {_id, w} -> w.session_id == session_id end)

    Enum.each(to_cancel, fn {worker_id, %{pid: pid}} ->
      Task.Supervisor.terminate_child(Dmhai.Agent.WorkerSupervisor, pid)
      WorkerState.mark_cancelled(worker_id)
    end)

    {:reply, :ok, %{state | workers: Map.new(remaining)}, @idle_timeout}
  end

  # List workers
  def handle_call(:list_workers, _from, state) do
    workers =
      Enum.map(state.workers, fn {id, w} ->
        %{id: id, session_id: w.session_id, description: w.description,
          started_at: w.started_at, progress: w.progress}
      end)

    {:reply, workers, state, @idle_timeout}
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

  # Worker task completed normally
  def handle_info({ref, _result}, state) do
    state = drop_worker_by_ref(ref, state)
    Process.demonitor(ref, [:flush])
    {:noreply, state, @idle_timeout}
  end

  # Inline task crashed
  def handle_info({:DOWN, ref, :task, _pid, reason}, %{current_task: {ref, reply_pid}} = state) do
    Logger.error("[UserAgent] inline task crashed user=#{state.user_id} reason=#{inspect(reason)}")
    send(reply_pid, {:error, "Internal error — please try again"})
    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  # Mid-job notification from a worker — debounce then trigger master response + external push.
  # Multiple rapid notifications within 1.5 s are collapsed: only the last one
  # fires trigger_master_from_buffer, which fetches ALL unconsumed buffer entries
  # at once.  MsgGateway.notify runs immediately for each (low-latency push).
  @buffer_debounce_ms 4_000

  def handle_info({:midjob_notify, session_id, user_id, worker_id, summary}, state) do
    worker_desc = get_in(state.workers, [worker_id, :description])

    # Cancel any pending flush timer for this session and start a fresh one.
    state =
      case Map.get(state.buffer_timers, session_id) do
        nil -> state
        ref ->
          Process.cancel_timer(ref)
          %{state | buffer_timers: Map.delete(state.buffer_timers, session_id)}
      end

    timer_ref =
      Process.send_after(
        self(),
        {:flush_buffer, session_id, user_id, worker_id, worker_desc},
        @buffer_debounce_ms
      )

    state = %{state | buffer_timers: Map.put(state.buffer_timers, session_id, timer_ref)}

    Task.start(fn -> MsgGateway.notify(user_id, summary) end)
    {:noreply, state, @idle_timeout}
  end

  def handle_info({:flush_buffer, session_id, user_id, worker_id, worker_desc}, state) do
    state = %{state | buffer_timers: Map.delete(state.buffer_timers, session_id)}
    # Snapshot worker descriptions so the task can label each entry correctly.
    worker_descs = Map.new(state.workers, fn {id, w} -> {id, w.description} end)
    Task.start(fn -> trigger_master_from_buffer(session_id, user_id, worker_id, worker_desc, worker_descs) end)
    {:noreply, state, @idle_timeout}
  end

  # Worker progress report — append step to worker's progress list
  def handle_info({:worker_progress, worker_id, step}, state) do
    case Map.get(state.workers, worker_id) do
      nil ->
        {:noreply, state, @idle_timeout}

      worker ->
        updated = %{worker | progress: worker.progress ++ [step]}
        {:noreply, %{state | workers: Map.put(state.workers, worker_id, updated)},
         @idle_timeout}
    end
  end

  # Worker task exited — either crashed or was cancelled via Task.Supervisor.terminate_child.
  # Task.Supervisor.async_nolink sends {:DOWN, ref, :process, pid, reason}, not :task.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    crashed =
      Enum.find_value(state.workers, fn {id, w} ->
        if w.ref == ref, do: {id, w}, else: nil
      end)

    case crashed do
      {worker_id, worker} when reason not in [:normal, :shutdown] ->
        Logger.error("[UserAgent] worker crashed id=#{worker_id} reason=#{inspect(reason)}")

        Task.start(fn ->
          MasterBuffer.append(
            worker.session_id, state.user_id,
            "Worker task '#{worker.description}' crashed unexpectedly: #{inspect(reason)}",
            "⚠ Task '#{worker.description}' crashed"
          )
        end)

      _ ->
        :ok
    end

    state = drop_worker_by_ref(ref, state)
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

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp cancel_current_task(%{current_task: nil} = state), do: state

  defp cancel_current_task(%{current_task: {_ref, reply_pid}} = state) do
    send(reply_pid, {:error, :interrupted})
    %{state | current_task: nil}
  end

  defp drop_worker_by_ref(ref, state) do
    workers =
      Enum.reject(state.workers, fn {_, w} -> w.ref == ref end)
      |> Map.new()

    %{state | workers: workers}
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

  defp run_confidant(%Command{reply_pid: reply_pid, session_id: session_id} = command, state, session_data, extra_context \\ nil) do
    user_id = state.user_id
    model   = AgentSettings.confidant_model()

    # Web search detection (only for text messages, not image-only)
    web_context =
      if command.content != "" do
        recent = extract_recent_context(session_data)

        case WebSearch.detect_category(command.content, recent, reply_pid) do
          {:search, category} ->
            user_msgs = extract_user_messages(session_data)
            queries = WebSearch.build_queries(command.content, user_msgs)
            result = WebSearch.search_and_fetch(queries, category, reply_pid)
            build_web_context(command.content, result, reply_pid)

          :no_search ->
            nil
        end
      end

    profile            = load_user_profile(user_id)
    image_descriptions = load_image_descriptions(session_id)
    video_descriptions = load_video_descriptions(session_id)

    # Use pre-computed description when available; fall back to raw images for master.
    images = effective_images(command, image_descriptions, video_descriptions)

    llm_messages =
      ContextEngine.build_messages(session_data,
        profile:            profile,
        has_video:          images != [] and command.has_video,
        images:             images,
        files:              command.files,
        image_descriptions: image_descriptions,
        video_descriptions: video_descriptions,
        web_context:        web_context,
        buffer_context:     extra_context
      )

    on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
    case LLM.stream(model, llm_messages, reply_pid, on_tokens: on_tokens) do
      {:ok, full_text} when full_text != "" ->
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
        send(reply_pid, {:error, "LLM error: #{inspect(reason)}"})
    end
  end

  # ─── Assistant pipeline ─────────────────────────────────────────────────
  # Master creates plan → worker executes → master_buffer → master reports.

  defp run_assistant(%Command{reply_pid: reply_pid, session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.assistant_model()

    profile            = load_user_profile(user_id)
    image_descriptions = load_image_descriptions(session_id)
    video_descriptions = load_video_descriptions(session_id)

    # Inject any unconsumed master_buffer entries as context
    buffer_entries = MasterBuffer.fetch_unconsumed(session_id)
    buffer_context = format_buffer_context(buffer_entries)

    if buffer_entries != [] do
      ids = Enum.map(buffer_entries, & &1.id)
      MasterBuffer.mark_consumed(ids)
    end

    # Inject active workers for this session so master can answer status/cancel queries
    session_workers =
      state.workers
      |> Enum.filter(fn {_id, w} -> w.session_id == session_id end)
      |> Enum.map(fn {id, w} ->
        progress_str =
          case w.progress do
            [] -> ""
            steps ->
              recent = steps |> Enum.take(-5) |> Enum.join("; ")
              "\n  progress (last steps): #{recent}"
          end
        "- id: #{id}, task: #{w.description}, started: #{DateTime.to_iso8601(w.started_at)}#{progress_str}"
      end)

    worker_context =
      if session_workers != [] do
        "[Active background tasks for this session]\n" <> Enum.join(session_workers, "\n")
      else
        nil
      end

    combined_buffer =
      [buffer_context, worker_context]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end

    # Use pre-computed description when available; fall back to raw images for master.
    images = effective_images(command, image_descriptions, video_descriptions)

    llm_messages =
      ContextEngine.build_messages(session_data,
        mode:               "assistant",
        profile:            profile,
        has_video:          images != [] and command.has_video,
        images:             images,
        files:              command.files,
        image_descriptions: image_descriptions,
        video_descriptions: video_descriptions,
        buffer_context:     combined_buffer
      )

    tools = [
      handoff_to_resolver_json_schema_def(),
      handoff_to_worker_json_schema_def(),
      cancel_worker_json_schema_def(),
      query_job_updates_json_schema_def()
    ]

    on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
    # Pass self() so master reasoning/text does not stream to the user when a tool call is made.
    # For the rare text-only fallback, we forward full_text manually below.
    case LLM.stream(model, llm_messages, self(), tools: tools, on_tokens: on_tokens) do
      {:ok, {:tool_calls, calls}} ->
        handle_tool_calls(calls, command, state, session_data, combined_buffer)

      {:ok, full_text} when full_text != "" ->
        # Fallback — master should always call a tool, but handle gracefully if it doesn't.
        # Since we passed self() above, chunks went to the Task mailbox; forward them here.
        Logger.warning("[UserAgent] master returned text without tool call, presenting directly")
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
        send(reply_pid, {:error, "LLM error: #{inspect(reason)}"})
    end
  end

  defp handle_tool_calls(calls, command, state, session_data, combined_buffer) do
    tool_name =
      Enum.find_value(calls, nil, fn call -> get_in(call, ["function", "name"]) end)

    case tool_name do
      "handoff_to_resolver" -> run_confidant(command, state, session_data, combined_buffer)
      "cancel_worker"       -> handle_cancel_worker(calls, command, state)
      "query_job_updates"   -> handle_query_job_updates(calls, command, state)
      _                     -> handle_handoff(calls, command, state)
    end
  end

  defp handle_cancel_worker(calls, command, state) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    user_id = state.user_id

    {worker_id, ack} =
      Enum.find_value(calls, {nil, nil}, fn call ->
        case get_in(call, ["function", "name"]) do
          "cancel_worker" ->
            args = get_in(call, ["function", "arguments"]) || %{}
            args = case args do
              a when is_map(a)    -> a
              a when is_binary(a) -> Jason.decode!(a)
            end
            {args["worker_id"], args["ack"]}
          _ -> nil
        end
      end)

    result = if worker_id, do: cancel_worker(user_id, worker_id), else: {:error, :not_found}

    msg = ack || case result do
      :ok                    -> "Task cancelled."
      {:error, :not_found}   -> "No such task found."
      _                      -> "Could not cancel the task."
    end

    append_session_message(session_id, user_id, %{
      role: "assistant",
      content: msg,
      ts: System.os_time(:millisecond)
    })

    send(reply_pid, {:chunk, msg})
    send(reply_pid, {:done, %{}})
  end

  defp handle_query_job_updates(calls, command, state) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    user_id = state.user_id
    model   = AgentSettings.assistant_model()

    {worker_id, limit} =
      Enum.find_value(calls, {nil, 20}, fn call ->
        case get_in(call, ["function", "name"]) do
          "query_job_updates" ->
            args = get_in(call, ["function", "arguments"]) || %{}
            args = case args do
              a when is_map(a)    -> a
              a when is_binary(a) -> Jason.decode!(a)
            end
            {args["worker_id"], args["limit"] || 20}
          _ -> nil
        end
      end)

    updates = if worker_id do
      MasterBuffer.fetch_for_worker(session_id, worker_id, limit)
    else
      []
    end

    worker_desc = get_in(state.workers, [worker_id, :description])
    label = if worker_desc, do: "Job [#{worker_id}]: #{worker_desc}", else: "Job [#{worker_id}]"

    updates_text =
      if updates == [] do
        "No progress updates found for #{label}."
      else
        entries =
          updates
          |> Enum.map(fn e -> "[#{label} — at #{e.created_at}]\n#{e.content}" end)
          |> Enum.join("\n---\n")
        "[Recent updates for #{label}]\n#{entries}"
      end

    case load_session(session_id, user_id) do
      {:ok, _, session_data} ->
        profile = load_user_profile(user_id)

        llm_messages =
          ContextEngine.build_messages(session_data,
            mode:           "assistant",
            profile:        profile,
            buffer_context: updates_text
          )

        on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
        case LLM.stream(model, llm_messages, reply_pid, on_tokens: on_tokens) do
          {:ok, full_text} when full_text != "" ->
            append_session_message(session_id, user_id, %{
              role: "assistant",
              content: full_text,
              ts: System.os_time(:millisecond)
            })
            send(reply_pid, {:done, %{content: full_text}})

          {:ok, ""} ->
            send(reply_pid, {:error, "No response received."})

          {:error, reason} ->
            send(reply_pid, {:error, "LLM error: #{inspect(reason)}"})
        end

      _ ->
        send(reply_pid, {:error, "Session not found."})
    end
  end

  defp handle_handoff(calls, command, state) do
    %Command{reply_pid: reply_pid, session_id: session_id} = command
    user_id = state.user_id

    task_desc =
      Enum.find_value(calls, "Task requested by user", fn call ->
        case get_in(call, ["function", "name"]) do
          "handoff_to_worker" ->
            args = get_in(call, ["function", "arguments"]) || %{}

            args =
              case args do
                a when is_map(a) -> a
                a when is_binary(a) -> Jason.decode!(a)
              end

            args["task"] || "Task requested by user"

          _ ->
            nil
        end
      end)

    ack =
      Enum.find_value(calls, nil, fn call ->
        case get_in(call, ["function", "name"]) do
          "handoff_to_worker" ->
            args = get_in(call, ["function", "arguments"]) || %{}
            args = case args do
              a when is_map(a)    -> a
              a when is_binary(a) -> Jason.decode!(a)
            end
            args["ack"]
          _ -> nil
        end
      end) || "Working on it — I'll notify you when the result is ready."

    # Describe any attached media and append to task brief so worker has full context.
    # Descriptions are usually already in DB (background describe ran while user was typing).
    # The synchronous fallback only fires if the user sent before background describe finished.
    media_context = describe_command_media(command, session_id)

    # Prepend a language directive so the worker model cannot miss it.
    # Placed in the task text itself (not just the system prompt) because
    # some models ignore system prompt language rules when generating content.
    lang_prefix =
      "[LANGUAGE RULE: You must respond and generate ALL content — including any text written to files or sent via midjob_notify — in the exact same language as this task description. Never use Spanish or any other language unless this task is explicitly written in that language.]\n\n"

    full_task =
      lang_prefix <>
        if media_context do
          task_desc <> "\n\n" <> media_context
        else
          task_desc
        end

    Logger.info("[UserAgent] handoff to worker user=#{user_id} task=#{String.slice(task_desc, 0, 80)}")

    # Spawn the worker as a detached task
    spawn_worker(user_id, session_id, full_task, fn agent_pid, worker_id ->
      ctx = %{user_id: user_id, session_id: session_id, agent_pid: agent_pid, worker_id: worker_id, description: full_task}
      Worker.run(full_task, ctx)
    end)

    append_session_message(session_id, user_id, %{
      role: "assistant",
      content: ack,
      ts: System.os_time(:millisecond)
    })

    send(reply_pid, {:chunk, ack})
    send(reply_pid, {:done, %{}})
  end

  defp handoff_to_resolver_json_schema_def do
    %{
      name: "handoff_to_resolver",
      description:
        "Route to the Resolver for a direct answer. " <>
          "Use for: factual questions, explanations, general knowledge, opinions, " <>
          "quick web lookups, or anything answerable in one shot. " <>
          "The Resolver runs the full Confidant pipeline — web search is handled automatically.",
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end

  defp handoff_to_worker_json_schema_def do
    %{
      name: "handoff_to_worker",
      description:
        "Hand off this task to a dedicated background agent that runs independently. " <>
          "The agent has tools: bash, web fetch, file read/write, calculator, date/time, " <>
          "and can push mid-job notifications directly into this chat. " <>
          "Use this for: research, file operations, calculations, multi-step work, " <>
          "AND any periodic or monitoring task (e.g. 'check CPU every 10 seconds', " <>
          "'notify me when disk usage exceeds 80%', 'poll this URL every minute'). " <>
          "The worker can run indefinitely for ongoing tasks — it will notify the user " <>
          "with each update directly in the chat thread.",
      parameters: %{
        type: "object",
        properties: %{
          task: %{
            type: "string",
            description:
              "A fully self-contained task brief for the worker. " <>
                "The worker has NO access to the chat history, so include everything it needs. " <>
                "Structure it as:\n" <>
                "Goal: what to accomplish and why.\n" <>
                "Steps: key steps or approach (for multi-step tasks).\n" <>
                "Context: relevant parameters, constraints, preferences, or data from the conversation."
          },
          ack: %{
            type: "string",
            description:
              "A brief acknowledgment to show the user while the task runs. " <>
                "MUST be in the same language as the user's message."
          }
        },
        required: ["task", "ack"]
      }
    }
  end

  defp cancel_worker_json_schema_def do
    %{
      name: "cancel_worker",
      description:
        "Cancel a running background task by its ID. " <>
          "Use this when the user asks to stop, cancel, or abort a task that is in progress.",
      parameters: %{
        type: "object",
        properties: %{
          worker_id: %{
            type: "string",
            description: "The exact ID of the worker task to cancel, from the active tasks list."
          },
          ack: %{
            type: "string",
            description:
              "Confirmation message to show the user. MUST be in the same language as the user's message."
          }
        },
        required: ["worker_id", "ack"]
      }
    }
  end

  defp query_job_updates_json_schema_def do
    %{
      name: "query_job_updates",
      description:
        "Fetch recent progress updates for a specific background job. " <>
          "Use this when the user asks about a job's status, progress, or results " <>
          "(e.g. 'how is job X doing?', 'what happened to the monitoring task?', " <>
          "'show me the latest report from Y'). " <>
          "Identify the worker_id from the active tasks list or conversation context, " <>
          "then call this tool to retrieve recent updates and summarise them for the user.",
      parameters: %{
        type: "object",
        properties: %{
          worker_id: %{
            type: "string",
            description: "The ID of the worker/job to query."
          },
          limit: %{
            type: "integer",
            description: "Maximum number of recent updates to fetch (default: 20)."
          }
        },
        required: ["worker_id"]
      }
    }
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
  defp extract_recent_context(session_data) do
    messages = session_data["messages"] || []

    messages
    |> Enum.take(-4)
    |> Enum.map(fn m -> "#{m["role"]}: #{String.slice(m["content"] || "", 0, 500)}" end)
    |> Enum.join("\n")
  end

  # Extract last 10 user messages (300 chars each) for search query generation.
  defp extract_user_messages(session_data) do
    messages = session_data["messages"] || []

    messages
    |> Enum.filter(fn m -> m["role"] == "user" end)
    |> Enum.take(-10)
    |> Enum.map(fn m -> String.slice(m["content"] || "", 0, 300) end)
  end

  # Format web search results and optionally synthesize large result sets.
  # Mirrors the original frontend pipeline:
  #   formatSearchResults → (synthesizeResults if > threshold) → inject as framing message.
  @synthesis_threshold 45_000
  @synthesis_fallback  8_000

  defp build_web_context(_content, %{snippets: [], pages: []}, _reply_pid), do: nil

  defp build_web_context(_content, result_map, reply_pid) do
    raw = format_raw_results(result_map)

    if raw == "" do
      nil
    else
      if String.length(raw) > @synthesis_threshold do
        send(reply_pid, {:status, "🧠 Synthesizing results..."})

        case WebSearch.synthesize_results(raw) do
          {:ok, synthesis} when is_binary(synthesis) and synthesis != "" ->
            Logger.info("[UserAgent] synthesis ok chars=#{String.length(synthesis)}")
            synthesis

          _ ->
            Logger.info("[UserAgent] synthesis failed, truncating raw results")
            String.slice(raw, 0, @synthesis_fallback)
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

  # Format master_buffer entries for injection into Assistant LLM call.
  defp format_buffer_context(entries), do: format_buffer_context(entries, nil, nil, %{})

  defp format_buffer_context([], _worker_id, _worker_desc, _worker_descs), do: nil

  defp format_buffer_context(entries, _worker_id, _worker_desc, worker_descs) do
    entries
    |> Enum.map(fn e ->
      id   = e.worker_id
      desc = Map.get(worker_descs, id)
      label =
        cond do
          desc && id -> "Job [#{id}]: #{desc}"
          id         -> "Job [#{id}]"
          true       -> "Worker update"
        end
      "[#{label} — update at #{e.created_at}]\n#{e.content}"
    end)
    |> Enum.join("\n---\n")
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

  # Build a text block describing any images/videos attached to the command.
  # Loads from DB first (background describe already ran); only calls the describer
  # synchronously as a fallback when descriptions aren't stored yet.
  # Uses INSERT OR IGNORE so a late-arriving background describe doesn't duplicate.
  defp describe_command_media(%Command{images: [], files: []}, _session_id), do: nil

  defp describe_command_media(%Command{} = command, session_id) do
    image_descs = load_image_descriptions(session_id)
    video_descs = load_video_descriptions(session_id)

    new_descs =
      if command.images != [] do
        model =
          if command.has_video,
            do: AgentSettings.video_describer_model(),
            else: AgentSettings.image_describer_model()

        prompt =
          if command.has_video,
            do: video_describe_prompt(),
            else: image_describe_prompt()

        command.image_names
        |> Enum.zip(Enum.chunk_every(command.images, length(command.images)))
        |> Enum.flat_map(fn {name, imgs} ->
          already = if command.has_video,
            do: Enum.any?(video_descs, &(&1.name == name)),
            else: Enum.any?(image_descs, &(&1.name == name))

          if already do
            []
          else
            Logger.info("[UserAgent] describe_command_media fallback name=#{name}")
            messages = [%{role: "user", content: prompt, images: imgs}]

            case LLM.call(model, messages) do
              {:ok, desc} when is_binary(desc) and desc != "" ->
                store_media_description(session_id, name, desc, command.has_video)
                [%{name: name, description: desc}]
              _ ->
                []
            end
          end
        end)
      else
        []
      end

    all_descs = image_descs ++ video_descs ++ new_descs

    file_descs =
      Enum.flat_map(command.files || [], fn f ->
        case f do
          %{"name" => name, "content" => content} when is_binary(content) and content != "" ->
            ["[File: #{name}]\n#{String.slice(content, 0, 8_000)}"]
          _ ->
            []
        end
      end)

    parts =
      (Enum.map(all_descs, fn d -> "[#{d.name}]: #{d.description}" end) ++ file_descs)

    if parts == [] do
      nil
    else
      "[Attached media and files — use these to understand the content]\n" <>
        Enum.join(parts, "\n")
    end
  end

  defp store_media_description(session_id, name, desc, is_video) do
    table = if is_video, do: "video_descriptions", else: "image_descriptions"
    file_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    now = System.os_time(:millisecond)

    try do
      query!(Repo,
        "INSERT OR IGNORE INTO #{table} (session_id, file_id, name, description, created_at) VALUES (?,?,?,?,?)",
        [session_id, file_id, name, desc, now])
    rescue
      e -> Logger.error("[UserAgent] store_media_description failed: #{Exception.message(e)}")
    end
  end

  defp image_describe_prompt do
    "Describe this image in detail: subjects, layout, setting, lighting, text, and mood."
  end

  defp video_describe_prompt do
    "These are frames from a video. Describe the content: overview, timeline, subjects, setting, and any visible text."
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

  # Proactive master response: when a Worker finishes, call the Master Agent
  # with the buffer contents so it can generate a report/response.
  defp trigger_master_from_buffer(session_id, user_id, worker_id, worker_desc, worker_descs \\ %{}) do
    try do
      entries = MasterBuffer.fetch_unconsumed(session_id)

      if entries != [] do
        buffer_context = format_buffer_context(entries, worker_id, worker_desc, worker_descs)
        ids = Enum.map(entries, & &1.id)
        MasterBuffer.mark_consumed(ids)

        # Present the worker update directly to the user.
        # Do NOT use assistant mode here — that system prompt instructs the model to
        # call tools, causing it to emit raw tool-call text instead of a real message.
        # A simple two-message prompt with the confidant model works correctly.
        model = AgentSettings.confidant_model()
        date = Date.utc_today() |> Date.to_string()

        llm_messages = [
          %{role: "system",
            content:
              "You are DMH-AI. Today's date: #{date}. " <>
              "A background job has sent you an update to report to the user. " <>
              "Format your response as:\n\n" <>
              "**<Job Name>:**\n\n<report content>\n\n" <>
              "Derive a short 2-6 word bold title from the job description in the update label (e.g. '**Joke delivery:**', '**Resource monitor:**') — never use the full description verbatim. " <>
              "If multiple jobs reported, use a separate short bold header for each. " <>
              "No other preamble — just the bold title, a blank line, then the information directly. " <>
              "Always reply in the same language the user used in their original task description."},
          %{role: "user", content: buffer_context}
        ]

        on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
        case LLM.call(model, llm_messages, on_tokens: on_tokens) do
          {:ok, text} when is_binary(text) and text != "" ->
            append_session_message(session_id, user_id, %{
              role: "assistant",
              content: text,
              ts: System.os_time(:millisecond)
            })

            # Write a consumed notification entry now that the message is in the session.
            # consumed=1 means fetch_unconsumed skips it (no loop), but fetch_notifications
            # returns it (summary IS NOT NULL) — frontend reloads and sees the master message.
            MasterBuffer.append_notification(session_id, user_id, String.slice(text, 0, 200))

            Logger.info("[UserAgent] proactive master response session=#{session_id} chars=#{String.length(text)}")

          _ ->
            :ok
        end
      end
    rescue
      e -> Logger.error("[UserAgent] trigger_master_from_buffer failed: #{Exception.message(e)}")
    end
  end
end
