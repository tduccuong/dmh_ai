# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent do
  @idle_timeout :timer.minutes(30)

  @moduledoc """
  Per-user agent (GenServer).

  Lifecycle: started lazily by `DmhAi.Agent.Supervisor.ensure_started/1`
  on first command, shuts down after 30 minutes of idle.

    {:dispatch_confidant, %ConfidantCommand{}} → run_confidant/3
    :cancel_current_turn                        → cancel inline turn

  Confidant is single-turn: one user message produces one streamed LLM
  reply (with optional web-search + memo pre-steps). There is no tool
  loop and no chain.

  This module is a thin GenServer shell. The memo lifecycle, session DB
  I/O, context builders, and stream collectors live in
  `__MODULE__.{Memo, SessionIO, ContextBuilders, StreamCollectors}`.
  """

  use GenServer
  require Logger

  alias DmhAi.Agent.{AgentSettings, ConfidantCommand, ContextEngine,
                     LLM, StreamBuffer, ThinkingBuffer,
                     Supervisor}
  alias DmhAi.Web.Search, as: WebSearchEngine
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  alias __MODULE__.{
    ContextBuilders,
    SessionIO,
    StreamCollectors
  }

  defstruct [
    :user_id,
    # current inline task: nil | {task_ref, task_pid, reply_pid, session_id}
    current_task: nil,
    platform_state: %{}
  ]

  # ─── Client API ───────────────────────────────────────────────────────────

  @doc "Dispatch a ConfidantCommand to the user's agent, starting it if needed."
  @spec dispatch_confidant(String.t(), ConfidantCommand.t()) :: :ok | {:error, term()}
  def dispatch_confidant(user_id, %ConfidantCommand{} = command) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, {:dispatch_confidant, command}, :infinity)
    end
  end

  @doc "Cancel the user's currently-running inline turn, if any."
  @spec cancel_current_turn(String.t()) :: {:ok, :stopped | :no_active_turn} | {:error, term()}
  def cancel_current_turn(user_id) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, :cancel_current_turn)
      []         -> {:error, :not_started}
    end
  end

  @doc "session_id of the user's currently-running turn, or nil."
  @spec current_turn_session_id(String.t()) :: String.t() | nil
  def current_turn_session_id(user_id) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :current_turn_session_id, 1_000)
        catch
          :exit, _ -> nil
        end

      [] ->
        nil
    end
  end

  @doc "Store platform-specific state (e.g. Telegram chat_id)."
  @spec set_platform_state(String.t(), atom(), map()) :: :ok
  def set_platform_state(user_id, platform, state) when is_atom(platform) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.cast(pid, {:set_platform_state, platform, state})
      [] -> :ok
    end
  end

  @doc "Read platform-specific state. nil when agent not running."
  @spec get_platform_state(String.t(), atom()) :: map() | nil
  def get_platform_state(user_id, platform) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, {:get_platform_state, platform})
      [] -> nil
    end
  end

  # ─── Load-session pass-through ────────────────────────────────────────────
  #
  # Historical public surface: callers (router / handlers / tests) may
  # still reference `UserAgent.load_session/2`. Delegate to the SessionIO
  # sub-module which now owns the read.
  defdelegate load_session(session_id, user_id), to: __MODULE__.SessionIO

  # ─── GenServer callbacks ───────────────────────────────────────────────────

  def start_link(user_id) do
    GenServer.start_link(__MODULE__, user_id, name: via(user_id))
  end

  @impl true
  def init(user_id) do
    Logger.info("[UserAgent] started user=#{user_id}")
    {:ok, %__MODULE__{user_id: user_id}, @idle_timeout}
  end

  @impl true
  def handle_call({:dispatch_confidant, %ConfidantCommand{} = command}, _from, state) do
    {result, new_state} =
      dispatch_run(command, state, fn session_data ->
        run_confidant(command, state, session_data)
      end)

    {:reply, result, new_state, @idle_timeout}
  end

  def handle_call({:get_platform_state, platform}, _from, state) do
    {:reply, Map.get(state.platform_state, platform), state, @idle_timeout}
  end

  def handle_call(:cancel_current_turn, _from, state) do
    case state.current_task do
      nil ->
        {:reply, {:ok, :no_active_turn}, state, @idle_timeout}

      {ref, task_pid, reply_pid, session_id} ->
        Process.demonitor(ref, [:flush])

        if is_pid(task_pid) and Process.alive?(task_pid) do
          Process.exit(task_pid, :kill)
        end

        safe_reply(reply_pid, {:cancelled, "Stopped by user."})

        # Stamp session.cancelled_at so an in-flight turn sees the stop
        # even if it re-enters before the kill takes effect.
        now = System.os_time(:millisecond)
        try do
          query!(Repo, "UPDATE sessions SET cancelled_at=? WHERE id=? AND cancelled_at IS NULL",
                 [now, session_id])
        rescue _ -> :ok end

        _ = StreamBuffer.clear(session_id, state.user_id)
        _ = ThinkingBuffer.clear(session_id, state.user_id)

        progress_ctx = %{session_id: session_id, user_id: state.user_id}
        _ = DmhAi.Agent.SessionProgress.append(
              progress_ctx, "chain_aborted", "Stopped by user.")

        Logger.info("[UserAgent] cancel_current_turn user=#{state.user_id} session=#{session_id}")
        DmhAi.SysLog.log("[UserAgent] cancel_current_turn user=#{state.user_id} session=#{session_id}")

        {:reply, {:ok, :stopped}, %{state | current_task: nil}, @idle_timeout}
    end
  end

  def handle_call(:current_turn_session_id, _from, state) do
    sid =
      case state.current_task do
        {_ref, _pid, _reply, session_id} -> session_id
        nil -> nil
      end

    {:reply, sid, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:set_platform_state, platform, pstate}, state) do
    {:noreply, %{state | platform_state: Map.put(state.platform_state, platform, pstate)},
     @idle_timeout}
  end

  # Inline turn completed — just clear the slot.
  @impl true
  def handle_info({ref, _result}, %{current_task: {ref, _task_pid, _reply_pid, _session_id}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state, @idle_timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task: {ref, _task_pid, reply_pid, session_id}} = state) do
    crash_summary =
      "[UserAgent] inline task crashed user=#{state.user_id} session=#{session_id} reason=#{inspect(reason, limit: 1000)}"
    Logger.error(crash_summary)
    DmhAi.SysLog.log(crash_summary)

    safe_reply(reply_pid, {:error, "Internal error — please try again"})

    _ = StreamBuffer.clear(session_id, state.user_id)
    _ = ThinkingBuffer.clear(session_id, state.user_id)

    progress_ctx = %{session_id: session_id, user_id: state.user_id}
    _ = DmhAi.Agent.SessionProgress.append(
          progress_ctx, "chain_aborted", "Internal error — please try again.")

    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  def handle_info({:DOWN, _ref, _type, _pid, _reason}, state) do
    {:noreply, state, @idle_timeout}
  end

  def handle_info(:timeout, state) do
    Logger.info("[UserAgent] idle timeout, stopping user=#{state.user_id}")
    {:stop, :normal, state}
  end

  # ─── Private GenServer helpers ─────────────────────────────────────────────

  defp via(user_id) do
    {:via, Registry, {DmhAi.Agent.Registry, user_id}}
  end

  defp safe_reply(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp safe_reply(_, _), do: :ok

  defp dispatch_run(command, state, run_fn) do
    reply_pid = command.reply_pid

    if state.current_task do
      safe_reply(reply_pid, {:error, :busy})
      {{:error, :busy}, state}
    else
      task =
        Task.Supervisor.async_nolink(DmhAi.Agent.TaskSupervisor, fn ->
          case SessionIO.load_session(command.session_id, state.user_id) do
            {:ok, _model, session_data} ->
              run_fn.(session_data)

            {:error, reason} ->
              safe_reply(reply_pid, {:error, reason})
          end
        end)

      {:ok,
       %{state | current_task: {task.ref, task.pid, reply_pid, command.session_id}}}
    end
  end

  # ─── Confidant pipeline ─────────────────────────────────────────────────

  defp run_confidant(%ConfidantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.confidant_model()

    {web_context, facts_block, memos_block} =
      if command.content != "" do
        user_msgs = SessionIO.extract_user_messages(session_data)
        {facts_block, memos_block} = DmhAi.Kb.Query.blocks(user_id, command.content)

        web_task =
          Task.async(fn ->
            case WebSearchEngine.generate_search_queries(command.content, user_msgs,
                                                         %{session_id: session_id, user_id: user_id}) do
              {:no_search} ->
                nil

              {:search, category, queries} ->
                DmhAi.SysLog.log("[SEARCH] category=#{category} queries=#{inspect(Enum.map(queries, & &1.text))}")

                progress_ctx = %{session_id: session_id, user_id: user_id}
                label_preview = "WebSearch → " <> String.slice(command.content, 0, 80)
                {:ok, row} =
                  DmhAi.Agent.SessionProgress.append(
                    progress_ctx, "confidant_websearch", label_preview, status: "pending")

                t0 = System.monotonic_time(:millisecond)

                result =
                  WebSearchEngine.call_search_engine(
                    queries, category, progress_row_id: row.id)

                DmhAi.Agent.SessionProgress.mark_tool_done(
                  row.id, System.monotonic_time(:millisecond) - t0)

                ContextBuilders.build_web_context(command.content, result, nil)
            end
          end)

        pre_timeout = AgentSettings.confidant_pre_step_timeout_ms()
        {Task.await(web_task, pre_timeout), facts_block, memos_block}
      else
        {nil, "", ""}
      end

    image_descriptions = ContextBuilders.load_image_descriptions(session_id)
    video_descriptions = ContextBuilders.load_video_descriptions(session_id)

    images = ContextBuilders.effective_images(command, image_descriptions, video_descriptions)

    llm_messages =
      ContextEngine.build_confidant_messages(session_data,
        has_video:          images != [] and command.has_video,
        images:             images,
        files:              command.files,
        image_descriptions: image_descriptions,
        video_descriptions: video_descriptions,
        web_context:        web_context,
        user_facts:         facts_block,
        user_memos:         memos_block,
        timezone:           command.timezone,
        local_date:         command.local_date
      )

    DmhAi.SysLog.log("[CONFIDANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)} web_search=#{web_context != nil} facts=#{facts_block != ""} memos=#{memos_block != ""}")

    collector = StreamCollectors.spawn_confidant_stream_collector(session_id, user_id)

    trace = %{
      origin: "confidant", path: "UserAgent.run_confidant",
      role: "ConfidantMaster", phase: "single-turn",
      session_id: session_id, user_id: user_id, tier: :master
    }

    result = LLM.stream(model, llm_messages, collector, trace: trace)
    StreamCollectors.stop_stream_collector(collector)

    case result do
      {:ok, full_text} when full_text != "" ->
        DmhAi.SysLog.log("[CONFIDANT] response(#{String.length(full_text)} chars): #{String.slice(full_text, 0, 300)}")
        thinking = ThinkingBuffer.read(session_id, user_id)
        msg = %{role: "assistant", content: full_text}
        msg = if thinking != "", do: Map.put(msg, :thinking, thinking), else: msg
        {:ok, _assistant_ts} = SessionIO.append_session_message(session_id, user_id, msg)
        StreamBuffer.clear(session_id, user_id)
        ThinkingBuffer.clear(session_id, user_id)

        Task.start(fn -> DmhAi.Agent.FactExtractor.extract(user_id) end)

      {:ok, ""} ->
        StreamBuffer.clear(session_id, user_id)
        ThinkingBuffer.clear(session_id, user_id)
        DmhAi.SysLog.log("[CONFIDANT] empty response — no message persisted")

      {:error, reason} ->
        StreamBuffer.clear(session_id, user_id)
        ThinkingBuffer.clear(session_id, user_id)
        DmhAi.SysLog.log("[CONFIDANT] ERROR: #{inspect(reason)}")
    end

    :ok
  end
end
