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

  alias Dmhai.Agent.{AgentSettings, Command, ContextEngine, LLM, MasterBuffer, ProfileExtractor, Supervisor, WebSearch, Worker}
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

  @doc "Spawn a detached worker task. Returns {:ok, worker_id} immediately."
  @spec spawn_worker(String.t(), String.t(), String.t(), (-> any())) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_worker(user_id, session_id, description, task_fn)
      when is_binary(user_id) and is_function(task_fn, 0) do
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

  # Spawn a detached worker
  def handle_call({:spawn_worker, session_id, description, task_fn}, _from, state) do
    worker_id = generate_id()
    user_id = state.user_id

    task =
      Task.Supervisor.async_nolink(Dmhai.Agent.WorkerSupervisor, fn ->
        Logger.info("[Worker] starting id=#{worker_id} session=#{session_id}")

        result =
          try do
            task_fn.()
          rescue
            e ->
              Logger.error("[Worker] crashed id=#{worker_id}: #{Exception.message(e)}")
              %{error: Exception.message(e)}
          end

        # Trigger proactive master response from buffer
        trigger_master_from_buffer(session_id, user_id)

        MsgGateway.notify(user_id, "✓ #{description} — result ready in DMH-AI")
        result
      end)

    worker = %{
      ref: task.ref,
      pid: task.pid,
      session_id: session_id,
      description: description,
      started_at: DateTime.utc_now()
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
        {:reply, :ok, %{state | workers: Map.delete(state.workers, worker_id)},
         @idle_timeout}
    end
  end

  # Cancel all workers for a session (called on session delete)
  def handle_call({:cancel_session_workers, session_id}, _from, state) do
    {to_cancel, remaining} =
      Enum.split_with(state.workers, fn {_id, w} -> w.session_id == session_id end)

    Enum.each(to_cancel, fn {_id, %{pid: pid}} ->
      Task.Supervisor.terminate_child(Dmhai.Agent.WorkerSupervisor, pid)
    end)

    {:reply, :ok, %{state | workers: Map.new(remaining)}, @idle_timeout}
  end

  # List workers
  def handle_call(:list_workers, _from, state) do
    workers =
      Enum.map(state.workers, fn {id, w} ->
        %{id: id, session_id: w.session_id, description: w.description,
          started_at: w.started_at}
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

  # Worker task crashed (already logged inside the task_fn rescue block)
  def handle_info({:DOWN, ref, :task, _pid, _reason}, state) do
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

  defp run_confidant(%Command{reply_pid: reply_pid, session_id: session_id} = command, state, session_data) do
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
        web_context:        web_context
      )

    case LLM.stream(model, llm_messages, reply_pid) do
      {:ok, full_text} ->
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
        "- id: #{id}, task: #{w.description}, started: #{DateTime.to_iso8601(w.started_at)}"
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
        profile:            profile,
        has_video:          images != [] and command.has_video,
        images:             images,
        files:              command.files,
        image_descriptions: image_descriptions,
        video_descriptions: video_descriptions,
        buffer_context:     combined_buffer
      )

    tools = [handoff_to_worker_def(), cancel_worker_tool_def()]

    case LLM.stream(model, llm_messages, reply_pid, tools: tools) do
      {:ok, {:tool_calls, calls}} ->
        handle_tool_calls(calls, command, state)

      {:ok, full_text} ->
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

      {:error, reason} ->
        send(reply_pid, {:error, "LLM error: #{inspect(reason)}"})
    end
  end

  defp handle_tool_calls(calls, command, state) do
    tool_name =
      Enum.find_value(calls, nil, fn call -> get_in(call, ["function", "name"]) end)

    case tool_name do
      "cancel_worker" -> handle_cancel_worker(calls, command, state)
      _               -> handle_handoff(calls, command, state)
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

    Logger.info("[UserAgent] handoff to worker user=#{user_id} task=#{String.slice(task_desc, 0, 80)}")

    # Spawn the worker as a detached task
    spawn_worker(user_id, session_id, task_desc, fn ->
      ctx = %{user_id: user_id, session_id: session_id}
      Worker.run(task_desc, ctx)
    end)

    append_session_message(session_id, user_id, %{
      role: "assistant",
      content: ack,
      ts: System.os_time(:millisecond)
    })

    send(reply_pid, {:chunk, ack})
    send(reply_pid, {:done, %{}})
  end

  defp handoff_to_worker_def do
    %{
      name: "handoff_to_worker",
      description:
        "Hand off this task to a dedicated AI agent equipped with tools: " <>
          "web search, web fetch, file read/write, bash commands, calculator, and date/time. " <>
          "Use this when the request requires real-time information, research, " <>
          "file operations, calculations, or any multi-step work that needs tools.",
      parameters: %{
        type: "object",
        properties: %{
          task: %{
            type: "string",
            description:
              "A clear, self-contained description of what needs to be accomplished, " <>
                "including any relevant context from the conversation."
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

  defp cancel_worker_tool_def do
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
  defp format_buffer_context([]), do: nil

  defp format_buffer_context(entries) do
    entries
    |> Enum.map(fn e -> "[Worker update at #{e.created_at}]\n#{e.content}" end)
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
  defp trigger_master_from_buffer(session_id, user_id) do
    try do
      entries = MasterBuffer.fetch_unconsumed(session_id)

      if entries != [] do
        buffer_context = format_buffer_context(entries)
        ids = Enum.map(entries, & &1.id)
        MasterBuffer.mark_consumed(ids)

        model = AgentSettings.assistant_model()

        case load_session(session_id, user_id) do
          {:ok, _session_model, session_data} ->
            profile = load_user_profile(user_id)

            llm_messages =
              ContextEngine.build_messages(session_data,
                profile:        profile,
                buffer_context: buffer_context
              )

            case LLM.call(model, llm_messages) do
              {:ok, text} when is_binary(text) and text != "" ->
                append_session_message(session_id, user_id, %{
                  role: "assistant",
                  content: text,
                  ts: System.os_time(:millisecond)
                })

                Logger.info("[UserAgent] proactive master response session=#{session_id} chars=#{String.length(text)}")

              _ ->
                :ok
            end

          _ ->
            :ok
        end
      end
    rescue
      e -> Logger.error("[UserAgent] trigger_master_from_buffer failed: #{Exception.message(e)}")
    end
  end
end
