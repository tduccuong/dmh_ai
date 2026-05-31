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

  Strict path separation between Assistant and Confidant modes:

    {:dispatch_assistant, %AssistantCommand{}} → run_assistant/3
    {:dispatch_confidant, %ConfidantCommand{}} → run_confidant/3
    :cancel_current_turn                        → cancel inline turn

  The Assistant chain ends naturally when the LLM emits no tool calls —
  there's no task abstraction; a chain is a sequence of turns (LLM
  call + tool execution) until the model produces user-facing text.
  Session-level cancellation is signalled via `sessions.cancelled_at`,
  which the chain loop polls between turns.

  This module is a thin GenServer shell. The chain loop, tool
  dispatch, memo lifecycle, session DB I/O, and context builders live
  in `__MODULE__.{RunLoop, ToolExecution, CircuitBreaker, Memo,
  SessionIO, ProfileResolution, ContextBuilders, StreamCollectors}`.
  """

  use GenServer
  require Logger

  alias DmhAi.Agent.{AgentSettings, AssistantCommand, ConfidantCommand, ContextEngine,
                     LLM, ProfileExtractor, StreamBuffer, ThinkingBuffer,
                     Supervisor}
  alias DmhAi.Web.Search, as: WebSearchEngine
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  alias __MODULE__.{
    ContextBuilders,
    Memo,
    RunLoop,
    SessionIO,
    StreamCollectors
  }

  defstruct [
    :user_id,
    # current inline task: nil | {task_ref, task_pid, reply_pid, session_id, mode}
    current_task: nil,
    platform_state: %{},
    # 32-byte raw MMK — lazy loaded from DB on first :get_memo_key /
    # :ensure_memo_key call. Wiped on logout, idle timeout, restart.
    memo_key: nil
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

  @doc """
  Cancel the user's currently-running inline turn (Confidant or
  Assistant), if any.
  """
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

  @doc "Read the user's MMK. Lazy-loaded from DB on cache miss."
  @spec get_memo_key(String.t()) :: binary() | nil
  def get_memo_key(user_id) when is_binary(user_id) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      try do
        GenServer.call(pid, :get_memo_key, 5_000)
      catch
        :exit, _ -> nil
      end
    else
      _ -> nil
    end
  end

  @doc "Ensure a memo key exists for the user; generate one if not."
  @spec ensure_memo_key(String.t()) :: {:ok, binary()} | {:error, term()}
  def ensure_memo_key(user_id) when is_binary(user_id) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      GenServer.call(pid, :ensure_memo_key, 5_000)
    end
  end

  @doc "Drop the in-memory MMK cache (admin password reset)."
  @spec wipe_memo_key(String.t()) :: :ok
  def wipe_memo_key(user_id) when is_binary(user_id) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.cast(pid, :wipe_memo_key)
      []         -> :ok
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
    send(self(), :boot_scan)
    {:ok, %__MODULE__{user_id: user_id}, @idle_timeout}
  end

  @impl true
  def handle_call({:dispatch_assistant, %AssistantCommand{} = command}, _from, state) do
    {result, new_state} =
      dispatch_run(command, state, fn session_data ->
        run_assistant(command, state, session_data)
      end, required_mode: "assistant")

    {:reply, result, new_state, @idle_timeout}
  end

  def handle_call({:dispatch_confidant, %ConfidantCommand{} = command}, _from, state) do
    {result, new_state} =
      dispatch_run(command, state, fn session_data ->
        run_confidant(command, state, session_data)
      end, required_mode: "confidant")

    {:reply, result, new_state, @idle_timeout}
  end

  def handle_call({:get_platform_state, platform}, _from, state) do
    {:reply, Map.get(state.platform_state, platform), state, @idle_timeout}
  end

  def handle_call(:get_memo_key, _from, state) do
    case state.memo_key do
      mmk when is_binary(mmk) ->
        {:reply, mmk, state, @idle_timeout}

      nil ->
        case Memo.lazy_load_memo_key(state.user_id) do
          {:ok, mmk} ->
            {:reply, mmk, %{state | memo_key: mmk}, @idle_timeout}

          {:error, :bad_master_key} ->
            Logger.warning(
              "[UserAgent] master-key mismatch on read for user=#{state.user_id} — auto-rotating memo wrap."
            )
            Memo.wipe_user_memo_state(state.user_id)
            mint_mmk_reply(state)

          {:error, _r} ->
            {:reply, nil, state, @idle_timeout}
        end
    end
  end

  def handle_call(:ensure_memo_key, _from, state) do
    case state.memo_key do
      mmk when is_binary(mmk) ->
        {:reply, {:ok, mmk}, state, @idle_timeout}

      nil ->
        case Memo.lazy_load_memo_key(state.user_id) do
          {:ok, mmk} ->
            {:reply, {:ok, mmk}, %{state | memo_key: mmk}, @idle_timeout}

          {:error, :no_wrap} ->
            mint_mmk_reply(state)

          {:error, :bad_master_key} ->
            Logger.warning(
              "[UserAgent] master-key mismatch for user=#{state.user_id} — auto-rotating memo wrap."
            )
            Memo.wipe_user_memo_state(state.user_id)
            mint_mmk_reply(state)

          {:error, reason} ->
            {:reply, {:error, reason}, state, @idle_timeout}
        end
    end
  end

  def handle_call(:cancel_current_turn, _from, state) do
    case state.current_task do
      nil ->
        {:reply, {:ok, :no_active_turn}, state, @idle_timeout}

      {ref, task_pid, reply_pid, session_id, _mode} ->
        Process.demonitor(ref, [:flush])

        if is_pid(task_pid) and Process.alive?(task_pid) do
          Process.exit(task_pid, :kill)
        end

        safe_reply(reply_pid, {:cancelled, "Stopped by user."})

        # Stamp session.cancelled_at so the chain loop sees the stop
        # even if a turn re-enters before the kill takes effect.
        now = System.os_time(:millisecond)
        try do
          query!(Repo, "UPDATE sessions SET cancelled_at=? WHERE id=? AND cancelled_at IS NULL",
                 [now, session_id])
        rescue _ -> :ok end

        _ = StreamBuffer.clear(session_id, state.user_id)
        _ = ThinkingBuffer.clear(session_id, state.user_id)
        _ = DmhAi.Agent.ChainInFlight.clear(session_id)

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
        {_ref, _pid, _reply, session_id, _mode} -> session_id
        nil -> nil
      end

    {:reply, sid, state, @idle_timeout}
  end

  @impl true
  def handle_cast({:set_platform_state, platform, pstate}, state) do
    {:noreply, %{state | platform_state: Map.put(state.platform_state, platform, pstate)},
     @idle_timeout}
  end

  def handle_cast(:wipe_memo_key, state) do
    {:noreply, %{state | memo_key: nil}, @idle_timeout}
  end

  # Inline task completed.
  # Result shape: {:chain_done, watermark_ts}. When a user message arrived
  # after the chain's watermark, auto-resume so the new message gets
  # answered without requiring another dispatch.
  @impl true
  def handle_info({ref, result}, %{current_task: {ref, _task_pid, _reply_pid, session_id, mode}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current_task: nil}

    case mode do
      "assistant" ->
        case result do
          {:chain_done, watermark_ts} when is_integer(watermark_ts) ->
            if DmhAi.Agent.UserAgentMessages.user_msgs_since(session_id, watermark_ts) != [] do
              send(self(), {:auto_resume_assistant, session_id})
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    {:noreply, state, @idle_timeout}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state, @idle_timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task: {ref, _task_pid, reply_pid, session_id, mode}} = state) do
    crash_summary =
      "[UserAgent] inline task crashed mode=#{mode} user=#{state.user_id} session=#{session_id} reason=#{inspect(reason, limit: 1000)}"
    Logger.error(crash_summary)
    DmhAi.SysLog.log(crash_summary)

    safe_reply(reply_pid, {:error, "Internal error — please try again"})

    _ = StreamBuffer.clear(session_id, state.user_id)
    _ = ThinkingBuffer.clear(session_id, state.user_id)
    _ = DmhAi.Agent.ChainInFlight.clear(session_id)

    progress_ctx = %{session_id: session_id, user_id: state.user_id}
    _ = DmhAi.Agent.SessionProgress.append(
          progress_ctx, "chain_aborted", "Internal error — please try again.")

    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  def handle_info({:DOWN, _ref, _type, _pid, _reason}, state) do
    {:noreply, state, @idle_timeout}
  end

  def handle_info({:auto_resume_assistant, session_id}, %{current_task: nil} = state) do
    command = %AssistantCommand{
      type:             :chat,
      content:          "",
      session_id:       session_id,
      reply_pid:        nil,
      attachment_names: [],
      files:            [],
      metadata:         %{auto_resume: true}
    }

    DmhAi.SysLog.log("[ASSISTANT:resume] user=#{state.user_id} session=#{session_id}")

    {_result, new_state} =
      dispatch_run(command, state, fn session_data ->
        run_assistant(command, state, session_data)
      end, required_mode: "assistant")

    {:noreply, new_state, @idle_timeout}
  end

  def handle_info({:auto_resume_assistant, _session_id}, state) do
    {:noreply, state, @idle_timeout}
  end

  def handle_info(:boot_scan, state) do
    case DmhAi.Agent.UserAgentMessages.sessions_with_unanswered_user_msg(state.user_id) do
      [] ->
        :ok

      sessions ->
        Logger.info("[UserAgent] boot_scan found #{length(sessions)} orphan session(s) for user=#{state.user_id}")

        Enum.each(sessions, fn sid ->
          send(self(), {:auto_resume_assistant, sid})
        end)
    end

    {:noreply, state, @idle_timeout}
  end

  def handle_info(:timeout, state) do
    case DmhAi.Agent.UserAgentMessages.sessions_with_unanswered_user_msg(state.user_id) do
      [] ->
        Logger.info("[UserAgent] idle timeout, stopping user=#{state.user_id}")
        {:stop, :normal, state}

      [sid | _] ->
        send(self(), {:auto_resume_assistant, sid})
        {:noreply, state, @idle_timeout}
    end
  end

  # ─── Private GenServer helpers ─────────────────────────────────────────────

  defp via(user_id) do
    {:via, Registry, {DmhAi.Agent.Registry, user_id}}
  end

  defp safe_reply(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp safe_reply(_, _), do: :ok

  # Bridge between `Memo.generate_and_persist_mmk/1` (pure persist) and
  # the GenServer reply tuple shape — the caller pattern in the two
  # memo-key handlers needs both the new state and the reply value.
  defp mint_mmk_reply(state) do
    case Memo.generate_and_persist_mmk(state.user_id) do
      {:ok, mmk} ->
        {:reply, {:ok, mmk}, %{state | memo_key: mmk}, @idle_timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @idle_timeout}
    end
  end

  defp dispatch_run(command, state, run_fn, opts) do
    required_mode = Keyword.fetch!(opts, :required_mode)
    reply_pid     = command.reply_pid

    cond do
      state.current_task && required_mode == "assistant" ->
        # In-flight chain will pick up the queued user message on its
        # next iteration via the splice helper, or the chain-complete
        # hook will auto-resume.
        safe_reply(reply_pid, {:error, :queued})
        {{:error, :queued}, state}

      state.current_task ->
        safe_reply(reply_pid, {:error, :busy})
        {{:error, :busy}, state}

      true ->
        task =
          Task.Supervisor.async_nolink(DmhAi.Agent.TaskSupervisor, fn ->
            case SessionIO.load_session(command.session_id, state.user_id) do
              {:ok, _model, session_data} ->
                actual_mode = session_data["mode"] || "confidant"

                if actual_mode == required_mode do
                  run_fn.(session_data)
                else
                  Logger.error("[UserAgent] mode mismatch: session=#{actual_mode} dispatch=#{required_mode}")
                  safe_reply(reply_pid, {:error, :mode_mismatch})
                end

              {:error, reason} ->
                safe_reply(reply_pid, {:error, reason})
            end
          end)

        {:ok,
         %{state | current_task: {task.ref, task.pid, reply_pid, command.session_id, required_mode}}}
    end
  end

  # ─── Confidant pipeline ─────────────────────────────────────────────────

  defp run_confidant(%ConfidantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.confidant_model()

    {web_context, memo_context} =
      if command.content != "" do
        user_msgs = SessionIO.extract_user_messages(session_data)
        {memo_context, memo_hits} = Memo.build_memo_context(command.content, user_msgs, user_id)

        web_task =
          Task.async(fn ->
            case WebSearchEngine.generate_search_queries(command.content, user_msgs, :confidant, memo_hits,
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
        {Task.await(web_task, pre_timeout), memo_context}
      else
        {nil, nil}
      end

    profile            = ContextBuilders.load_user_profile(user_id)
    image_descriptions = ContextBuilders.load_image_descriptions(session_id)
    video_descriptions = ContextBuilders.load_video_descriptions(session_id)

    images = ContextBuilders.effective_images(command, image_descriptions, video_descriptions)

    llm_messages =
      ContextEngine.build_confidant_messages(session_data,
        profile:            profile,
        has_video:          images != [] and command.has_video,
        images:             images,
        files:              command.files,
        image_descriptions: image_descriptions,
        video_descriptions: video_descriptions,
        web_context:        web_context,
        memo_context:       memo_context,
        timezone:           command.timezone,
        local_date:         command.local_date
      )

    DmhAi.SysLog.log("[CONFIDANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)} web_search=#{web_context != nil} memo_context=#{memo_context != nil}")

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

        Task.start(fn -> ProfileExtractor.extract_and_merge(user_id) end)

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

  # ─── Assistant pipeline ─────────────────────────────────────────────────

  @doc false
  # Test seam — bypass the GenServer / dispatch machinery and call the
  # internal pipeline directly.
  def run_for_test(%AssistantCommand{} = command, user_id, session_data) when is_binary(user_id) do
    state = %__MODULE__{user_id: user_id}
    run_assistant(command, state, session_data)
  end

  defp run_assistant(%AssistantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.assistant_model()
    profile = ContextBuilders.load_user_profile(user_id)
    email   = ContextBuilders.lookup_user_email(user_id)

    session_data = SessionIO.compact_if_needed(session_id, user_id, session_data)

    user_msgs = SessionIO.extract_user_messages(session_data)
    {memo_context, _memo_hits} = Memo.build_memo_context(command.content, user_msgs, user_id)

    llm_messages =
      ContextEngine.build_assistant_messages(session_data,
        user_id:         user_id,
        profile:         profile,
        files:           command.files,
        timezone:        command.timezone,
        local_date:      command.local_date,
        memo_context:    memo_context
      )

    data_dir      = DmhAi.Constants.session_data_dir(email, session_id)
    workspace_dir = DmhAi.Constants.session_workspace_dir(email, session_id)
    File.mkdir_p(data_dir)
    File.mkdir_p(workspace_dir)

    fresh_attachment_paths = DmhAi.Agent.Police.extract_fresh_attachment_paths(llm_messages)

    ctx = %{
      user_id:       user_id,
      user_email:    email,
      user_role:     ContextBuilders.lookup_user_role(user_id),
      session_id:    session_id,
      session_root:  DmhAi.Constants.session_root(email, session_id),
      data_dir:      data_dir,
      workspace_dir: workspace_dir,
      keystore_dir:  DmhAi.Constants.user_keystore_dir(email),
      log_trace:     AgentSettings.log_trace(),
      fresh_attachment_paths: fresh_attachment_paths,
      chain_start_idx: length(llm_messages),
      role:          "assistant",
      model:         model
    }

    DmhAi.SysLog.log("[ASSISTANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)} fresh_attachments=#{inspect(fresh_attachment_paths)}")

    DmhAi.Agent.ChainInFlight.set(session_id)

    # Chain-start reset of the active tool-profile set. This is the
    # single guaranteed entry point for an assistant chain, so it
    # cleans up after ANY prior-chain ending — including the abnormal
    # ones that bypass `emit_chain_end` (user cancel mid-loop, explicit
    # stop killing the task, task crash). `emit_chain_end` still resets
    # on normal completion for prompt cleanup; this guarantees a fresh
    # chain always starts at core-only regardless. See
    # `arch_wiki/dmh_ai/architecture.md` §Auto-deactivate at chain end.
    DmhAi.Agent.SessionContext.set_active_profiles(session_id, [])

    result =
      try do
        RunLoop.session_chain_loop(llm_messages, model, ctx, 0)
      after
        DmhAi.Agent.ChainInFlight.clear(session_id)
      end

    Task.start(fn -> ProfileExtractor.extract_and_merge(user_id) end)

    result
  end
end
