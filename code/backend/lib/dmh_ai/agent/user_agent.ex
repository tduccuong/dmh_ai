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
  """

  use GenServer
  require Logger

  alias DmhAi.Agent.{AgentSettings, AssistantCommand, ConfidantCommand, ContextEngine,
                     LLM, ProfileExtractor, StreamBuffer, ThinkingBuffer,
                     Supervisor}
  alias DmhAi.Web.Search, as: WebSearchEngine
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.Embedder
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

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
        case lazy_load_memo_key(state.user_id) do
          {:ok, mmk} ->
            {:reply, mmk, %{state | memo_key: mmk}, @idle_timeout}

          {:error, :bad_master_key} ->
            Logger.warning(
              "[UserAgent] master-key mismatch on read for user=#{state.user_id} — auto-rotating memo wrap."
            )
            wipe_user_memo_state(state.user_id)
            generate_and_persist_mmk(state)

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
        case lazy_load_memo_key(state.user_id) do
          {:ok, mmk} ->
            {:reply, {:ok, mmk}, %{state | memo_key: mmk}, @idle_timeout}

          {:error, :no_wrap} ->
            generate_and_persist_mmk(state)

          {:error, :bad_master_key} ->
            Logger.warning(
              "[UserAgent] master-key mismatch for user=#{state.user_id} — auto-rotating memo wrap."
            )
            wipe_user_memo_state(state.user_id)
            generate_and_persist_mmk(state)

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

  # ─── Private helpers ───────────────────────────────────────────────────────

  defp via(user_id) do
    {:via, Registry, {DmhAi.Agent.Registry, user_id}}
  end

  defp lazy_load_memo_key(user_id) do
    case query!(Repo, "SELECT memo_wrapped_mmk FROM users WHERE id=?", [user_id]) do
      %{rows: [[nil]]} ->
        {:error, :no_wrap}

      %{rows: [[wrapped]]} when is_binary(wrapped) ->
        case DmhAi.MemoCrypto.wrap_version(wrapped) do
          :v2 ->
            case DmhAi.MemoCrypto.unwrap_with_master(wrapped, DmhAi.MemoCrypto.MasterKey.get()) do
              {:ok, mmk} -> {:ok, mmk}
              {:error, reason} ->
                Logger.warning("[UserAgent] master-key unwrap failed user=#{user_id} reason=#{inspect(reason)}")
                {:error, reason}
            end

          :v1 ->
            {:error, :legacy_v1}

          :unknown ->
            {:error, :unknown_format}
        end

      _ ->
        {:error, :no_wrap}
    end
  end

  defp generate_and_persist_mmk(state) do
    mmk = DmhAi.MemoCrypto.generate_mmk()
    wrapped = DmhAi.MemoCrypto.wrap_with_master(mmk, DmhAi.MemoCrypto.MasterKey.get())

    try do
      query!(Repo,
        "UPDATE users SET memo_wrapped_mmk = ?, memo_kdf_salt = NULL WHERE id = ?",
        [wrapped, state.user_id])
      {:reply, {:ok, mmk}, %{state | memo_key: mmk}, @idle_timeout}
    rescue
      e ->
        {:reply, {:error, Exception.message(e)}, state, @idle_timeout}
    end
  end

  defp wipe_user_memo_state(user_id) do
    DmhAi.VectorDB.Sources.wipe_user_memos(user_id)
  rescue
    e -> Logger.error("[UserAgent] wipe_user_memo_state failed for user=#{user_id}: #{Exception.message(e)}")
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
            case load_session(command.session_id, state.user_id) do
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

  defp safe_reply(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp safe_reply(_, _), do: :ok

  # ─── Confidant pipeline ─────────────────────────────────────────────────

  defp run_confidant(%ConfidantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.confidant_model()

    {web_context, memo_context} =
      if command.content != "" do
        user_msgs = extract_user_messages(session_data)
        {memo_context, memo_hits} = build_memo_context(command.content, user_msgs, user_id)

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

                build_web_context(command.content, result, nil)
            end
          end)

        pre_timeout = AgentSettings.confidant_pre_step_timeout_ms()
        {Task.await(web_task, pre_timeout), memo_context}
      else
        {nil, nil}
      end

    profile            = load_user_profile(user_id)
    image_descriptions = load_image_descriptions(session_id)
    video_descriptions = load_video_descriptions(session_id)

    images = effective_images(command, image_descriptions, video_descriptions)

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

    collector = spawn_confidant_stream_collector(session_id, user_id)

    trace = %{
      origin: "confidant", path: "UserAgent.run_confidant",
      role: "ConfidantMaster", phase: "single-turn",
      session_id: session_id, user_id: user_id, tier: :master
    }

    result = LLM.stream(model, llm_messages, collector, trace: trace)
    stop_stream_collector(collector)

    case result do
      {:ok, full_text} when full_text != "" ->
        DmhAi.SysLog.log("[CONFIDANT] response(#{String.length(full_text)} chars): #{String.slice(full_text, 0, 300)}")
        thinking = ThinkingBuffer.read(session_id, user_id)
        msg = %{role: "assistant", content: full_text}
        msg = if thinking != "", do: Map.put(msg, :thinking, thinking), else: msg
        {:ok, _assistant_ts} = append_session_message(session_id, user_id, msg)
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

  defp stop_stream_collector(collector) when is_pid(collector) do
    if Process.alive?(collector) do
      send(collector, :stop)
      ref = Process.monitor(collector)
      receive do
        {:DOWN, ^ref, :process, ^collector, _} -> :ok
      after 1_000 -> :ok end
    end
    :ok
  end
  defp stop_stream_collector(_), do: :ok

  defp spawn_assistant_stream_collector(session_id, user_id) do
    spawn(fn ->
      stream_collector_loop(
        StreamBuffer.new(session_id, user_id),
        ThinkingBuffer.new(session_id, user_id)
      )
    end)
  end

  defp spawn_confidant_stream_collector(session_id, user_id) do
    spawn(fn ->
      stream_collector_loop(
        StreamBuffer.new(session_id, user_id),
        ThinkingBuffer.new(session_id, user_id)
      )
    end)
  end

  defp stream_collector_loop(answer_buf, thinking_buf) do
    receive do
      {:chunk, token} when is_binary(token) ->
        new_answer = answer_buf |> StreamBuffer.append(token) |> StreamBuffer.maybe_flush()
        stream_collector_loop(new_answer, thinking_buf)

      {:thinking, token} when is_binary(token) ->
        new_thinking = thinking_buf |> ThinkingBuffer.append(token) |> ThinkingBuffer.maybe_flush()
        stream_collector_loop(answer_buf, new_thinking)

      :flush_and_stop ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
        :ok

      :stop ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
        :ok

      _ ->
        stream_collector_loop(answer_buf, thinking_buf)
    after
      120_000 ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
    end
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
    profile = load_user_profile(user_id)
    email   = lookup_user_email(user_id)

    session_data = compact_if_needed(session_id, user_id, session_data)

    user_msgs = extract_user_messages(session_data)
    {memo_context, _memo_hits} = build_memo_context(command.content, user_msgs, user_id)

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
      user_role:     lookup_user_role(user_id),
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
        session_chain_loop(llm_messages, model, ctx, 0)
      after
        DmhAi.Agent.ChainInFlight.clear(session_id)
      end

    Task.start(fn -> ProfileExtractor.extract_and_merge(user_id) end)

    result
  end

  # Chain loop: one Assistant chain (LLM call + tool executions until
  # the model emits user-facing text with no tool calls).
  # Returns {:chain_done, watermark_ts}.
  defp session_chain_loop(messages, model, ctx, turn) do
    max_turns = AgentSettings.max_assistant_turns_per_chain()

    messages = splice_mid_chain_user_msgs(messages, ctx)
    messages = flush_stale_tool_results(messages, turn)

    cond do
      session_cancelled?(ctx) ->
        _ = StreamBuffer.clear(ctx.session_id, ctx.user_id)
        _ = ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
        progress_ctx = %{session_id: ctx.session_id, user_id: ctx.user_id}
        {:ok, _} = DmhAi.Agent.SessionProgress.append(
          progress_ctx, "chain_aborted", "Stopped by user.")
        {:chain_done, max_user_ts_in_messages(messages)}

      turn >= max_turns ->
        msg = DmhAi.I18n.t("turn_cap_reached", "en", %{max: max_turns})
        cap_msg = %{role: "assistant", content: msg}
        {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, cap_msg)
        emit_chain_end(ctx, "turn_cap")
        {:chain_done, max_user_ts_in_messages(messages)}

      true ->
        do_one_turn(messages, model, ctx, turn)
    end
  end

  defp do_one_turn(messages, model, ctx, turn) do
    active_profiles = DmhAi.Agent.SessionContext.active_profiles(ctx.session_id)
    ctx = Map.put(ctx, :active_profiles, active_profiles)
    tools = DmhAi.Tools.Registry.all_definitions(ctx.user_id, ctx.session_id, active_profiles)

    # Pin the active-profile catalog into the outgoing context (NOT
    # persisted). The manifest the model needs to compose IR survives
    # the rolling tool-result flush this way — it's rebuilt every turn
    # from active_profiles, so it's authoritative and vanishes when the
    # chain ends (active set resets). See architecture.md §Tool profiles.
    outgoing = inject_active_catalog(messages, active_profiles, ctx)

    trace = %{
      origin: "assistant",
      path: "UserAgent.session_chain",
      role: "AssistantSession",
      phase: "turn#{turn}",
      session_id: ctx.session_id,
      user_id: ctx.user_id,
      tier: :master
    }

    collector = spawn_assistant_stream_collector(ctx.session_id, ctx.user_id)
    llm_options = %{num_predict: AgentSettings.llm_num_predict_assistant()}
    result = LLM.stream(model, outgoing, collector,
                        tools: tools, options: llm_options,
                        trace: trace)
    stop_stream_collector(collector)

    case result do
      {:ok, {:tool_calls, calls}} ->
        handle_tool_calls(calls, messages, model, ctx, turn)

      {:ok, text} when is_binary(text) ->
        handle_text_turn(text, messages, model, ctx, turn)

      {:error, reason} ->
        handle_error(reason, messages, ctx)
    end
  end

  defp handle_tool_calls(calls, messages, model, ctx, turn) do
    call_names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
    DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} tool_calls=[#{call_names}]")

    raw_narration  = StreamBuffer.read(ctx.session_id, ctx.user_id)
    clean_narration = DmhAi.Agent.TextSanitizer.strip_tool_bookkeeping(raw_narration)
    StreamBuffer.clear(ctx.session_id, ctx.user_id)
    ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

    may_emit_form? = Enum.any?(calls, fn c ->
      (get_in(c, ["function", "name"]) || "") in ~w(request_input connect_mcp)
    end)

    if String.trim(clean_narration) != "" and not may_emit_form? do
      DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} narration(#{String.length(clean_narration)} chars) persisted")
      narration_msg = %{role: "assistant", content: clean_narration}
      {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, narration_msg)
    end

    {tool_result_msgs_raw, tagged_calls, exec_results, ctx} = execute_tools(calls, messages, ctx)
    assistant_msg = %{role: "assistant", content: clean_narration, tool_calls: tagged_calls}

    {ctx, tool_result_msgs} = bump_nudge_counters(ctx, tool_result_msgs_raw)
    tool_result_msgs = Enum.map(tool_result_msgs, &Map.put(&1, :emit_turn, turn))
    form = if may_emit_form?, do: extract_form_from_results(exec_results), else: nil

    cond do
      form != nil ->
        content =
          case String.trim(clean_narration) do
            "" -> fallback_content_for_form(form)
            s  -> s
          end

        msg = %{role: "assistant", content: content, form: form}
        {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, msg)
        DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} form persisted (kind=#{form["kind"] || "request_input"} token=#{form["token"] || form[:token]})")
        emit_chain_end(ctx, "form")
        {:chain_done, max_user_ts_in_messages(messages)}

      true ->
        case maybe_abort_on_model_behavior_issue(ctx, model) do
          :continue ->
            new_messages = messages ++ [assistant_msg] ++ tool_result_msgs
            session_chain_loop(new_messages, model, ctx, turn + 1)

          :aborted ->
            emit_chain_end(ctx, "aborted")
            {:chain_done, max_user_ts_in_messages(messages)}
        end
    end
  end

  defp handle_text_turn(text, messages, model, ctx, turn) do
    case DmhAi.Agent.Police.check_assistant_text(text) do
      {:rejected, tagged_or_reason} ->
        {issue_atom, reason} =
          case tagged_or_reason do
            {atom, text_reason} when is_atom(atom) -> {atom, text_reason}
            plain when is_binary(plain)            -> {:assistant_text, plain}
          end

        DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} rejected text='#{String.slice(text, 0, 80)}' — nudging for retry")
        StreamBuffer.clear(ctx.session_id, ctx.user_id)
        ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
        ctx = record_non_tool_issue(ctx, issue_atom)

        new_messages =
          messages ++ [
            %{role: "assistant", content: text},
            %{role: "user",      content: wrap_runtime_correction(reason)}
          ]

        case maybe_abort_on_model_behavior_issue(ctx, model) do
          :continue ->
            session_chain_loop(new_messages, model, ctx, turn + 1)

          :aborted ->
            emit_chain_end(ctx, "aborted")
            {:chain_done, max_user_ts_in_messages(messages)}
        end

      :ok ->
        fresh_paths = Map.get(ctx, :fresh_attachment_paths, [])

        case DmhAi.Agent.Police.check_fresh_attachments_read(fresh_paths, messages) do
          {:rejected, tagged_or_reason} ->
            {issue_atom, reason} =
              case tagged_or_reason do
                {atom, r} when is_atom(atom) -> {atom, r}
                plain when is_binary(plain)  -> {:fresh_attachments_unread, plain}
              end

            DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} rejected fresh-attachment-miss — nudging for retry")
            StreamBuffer.clear(ctx.session_id, ctx.user_id)
            ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
            ctx = record_non_tool_issue(ctx, issue_atom)

            new_messages =
              messages ++ [
                %{role: "assistant", content: text},
                %{role: "user",      content: wrap_runtime_correction(reason)}
              ]

            case maybe_abort_on_model_behavior_issue(ctx, model) do
              :continue ->
                session_chain_loop(new_messages, model, ctx, turn + 1)

              :aborted ->
                emit_chain_end(ctx, "aborted")
                {:chain_done, max_user_ts_in_messages(messages)}
            end

          :ok ->
            case DmhAi.Agent.Police.check_no_phantom_outcome(Map.get(ctx, :outcome_attempts, 0), Map.get(ctx, :outcome_failures, 0)) do
              {:rejected, {issue_atom, reason}} ->
                DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} rejected phantom_outcome — nudging for retry")
                StreamBuffer.clear(ctx.session_id, ctx.user_id)
                ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
                ctx = record_non_tool_issue(ctx, issue_atom)

                new_messages =
                  messages ++ [
                    %{role: "assistant", content: text},
                    %{role: "user",      content: wrap_runtime_correction(reason)}
                  ]

                case maybe_abort_on_model_behavior_issue(ctx, model) do
                  :continue ->
                    session_chain_loop(new_messages, model, ctx, turn + 1)

                  :aborted ->
                    emit_chain_end(ctx, "aborted")
                    {:chain_done, max_user_ts_in_messages(messages)}
                end

              :ok ->
                clean_text = DmhAi.Agent.TextSanitizer.strip_tool_bookkeeping(text)
                DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} text(#{String.length(clean_text)} chars)")
                thinking_text = ThinkingBuffer.read(ctx.session_id, ctx.user_id)
                base_msg = %{role: "assistant", content: clean_text}
                base_msg = if thinking_text != "",
                              do: Map.put(base_msg, :thinking, thinking_text),
                              else: base_msg
                {:ok, _assistant_ts} =
                  append_session_message(ctx.session_id, ctx.user_id, base_msg)
                StreamBuffer.clear(ctx.session_id, ctx.user_id)
                ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

                emit_chain_end(ctx, "final_text")
                {:chain_done, max_user_ts_in_messages(messages)}
            end
        end
    end
  end

  defp handle_error(reason, messages, ctx) do
    DmhAi.SysLog.log("[ASSISTANT] ERROR: #{inspect(reason)}")
    StreamBuffer.clear(ctx.session_id, ctx.user_id)
    ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

    err_msg = %{
      role: "assistant",
      content: DmhAi.I18n.t("llm_error", "en", %{reason: inspect(reason)})
    }
    {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, err_msg)
    emit_chain_end(ctx, "error")
    {:chain_done, max_user_ts_in_messages(messages)}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp extract_form_from_results(exec_results) do
    Enum.find_value(exec_results, fn
      {:ok, %{form: form}} when is_map(form) -> form
      _                                       -> nil
    end)
  end

  defp emit_chain_end(ctx, cause) when is_binary(cause) do
    progress_ctx = %{session_id: Map.get(ctx, :session_id), user_id: Map.get(ctx, :user_id)}
    _ = DmhAi.Agent.SessionProgress.append_chain_end(progress_ctx, cause)
    _ = reset_active_profiles(ctx)
    :ok
  end

  # Chain-end reset: any profiles the model activated during this
  # chain are dropped, so the next chain starts at `:core`-only.
  # See `arch_wiki/dmh_ai/architecture.md` §Execution tools / §Tool
  # profiles / §Auto-deactivate at chain end.
  defp reset_active_profiles(%{session_id: session_id}) when is_binary(session_id) do
    DmhAi.Agent.SessionContext.set_active_profiles(session_id, [])
  end
  defp reset_active_profiles(_), do: :ok

  # Insert the active-profile catalog as a system-role message right
  # after the base system prompt (index 0). Transient — operates on
  # the OUTGOING message list only; the persisted `session.messages`
  # never carries it. No active profiles → messages unchanged. The
  # block is rebuilt each turn from the live active set, so it can't
  # leak across chains (chain end resets the active set to []).
  defp inject_active_catalog(messages, active_profiles, _ctx) do
    case DmhAi.Tools.Profiles.format_catalog_block(active_profiles) do
      nil ->
        messages

      block ->
        catalog_msg = %{role: "system", content: block}

        case messages do
          [first | rest] -> [first, catalog_msg | rest]
          [] -> [catalog_msg]
        end
    end
  end

  # Auto-activate the profile that owns `tool_name` when it isn't
  # already active. Dependency resolution: the model expressing
  # intent to call a tool IS the signal it needs that tool's
  # profile, so the runtime loads it rather than rejecting the call.
  # Persists to session context (so the schema ships next turn) and
  # returns ctx with `:active_profiles` updated for the rest of THIS
  # turn's gates. Tools in `:core` (or unknown names) are no-ops.
  defp resolve_profile_dependency(tool_name, ctx) do
    active = Map.get(ctx, :active_profiles, [])

    case DmhAi.Tools.Profiles.gate(tool_name, active) do
      {:needs_profile, profile} ->
        new_active = Enum.uniq(active ++ [profile])

        if session_id = Map.get(ctx, :session_id) do
          DmhAi.Agent.SessionContext.set_active_profiles(session_id, new_active)
        end

        DmhAi.SysLog.log("[ASSISTANT] auto-activated profile=#{profile} for tool=#{tool_name}")
        {Map.put(ctx, :active_profiles, new_active), profile}

      _ ->
        {ctx, nil}
    end
  end

  # Mirror what `activate_profile` / `connect_mcp` already return: when
  # the runtime auto-activates a profile to satisfy a direct tool call,
  # inject that profile's manifest into the {:ok, result} envelope so
  # the model immediately sees the other tools it just unlocked.
  # Only augments map results; non-map results (strings, lists) pass
  # through untouched.
  defp augment_with_profile_manifest(result, nil, _ctx), do: result

  defp augment_with_profile_manifest(result, profile, ctx) when is_map(result) do
    manifest = DmhAi.Tools.Profiles.build_manifest([profile], ctx.user_id, ctx.session_id)

    result
    |> Map.put_new("profile_activated", profile)
    |> Map.put_new("manifest", manifest)
    |> Map.put_new(
      "note",
      "Profile `" <> profile <> "` was auto-activated by this call; `manifest` lists every tool " <>
        "it now makes callable. Compose subsequent calls / IR against those names."
    )
  end

  defp augment_with_profile_manifest(result, _profile, _ctx), do: result

  defp session_cancelled?(%{session_id: session_id}) when is_binary(session_id) do
    try do
      case query!(Repo, "SELECT cancelled_at FROM sessions WHERE id=?", [session_id]) do
        %{rows: [[nil]]} -> false
        %{rows: [[_ts]]} -> true
        _ -> false
      end
    rescue
      _ -> false
    end
  end
  defp session_cancelled?(_), do: false

  defp fallback_content_for_form(form) when is_map(form) do
    case form["kind"] || form[:kind] do
      "connect_mcp_setup" -> "Setting up the connection — please fill in the form below."
      _                   -> "Please fill in the form below."
    end
  end
  defp fallback_content_for_form(_), do: "Please fill in the form below."

  defp execute_tools(calls, messages, ctx) do
    chain_start_idx = Map.get(ctx, :chain_start_idx, 0)
    in_chain_prior  = Enum.drop(messages, chain_start_idx)

    {triples, {_final_prior, final_ctx}} =
      Enum.flat_map_reduce(calls, {in_chain_prior, ctx}, fn call, {prior_acc, ctx} ->
        name         = get_in(call, ["function", "name"]) || ""
        args         = get_in(call, ["function", "arguments"]) || %{}
        tool_call_id = call["id"] || ""

        progress_ctx = %{session_id: ctx.session_id, user_id: ctx.user_id}

        # Dependency resolution: a tool call naming a tool from a
        # known-but-inactive profile auto-activates that profile and
        # proceeds — no reject, no wasted turn. When activation fires,
        # the profile's manifest is injected into the {:ok, result}
        # envelope below so the model sees the rest of that profile's
        # tools immediately, not only on the next turn. See
        # `arch_wiki/dmh_ai/architecture.md` §Tool profiles.
        {ctx, auto_activated_profile} = resolve_profile_dependency(name, ctx)

        {tool_msg, exec_result} =
          with :ok <- DmhAi.Agent.Police.check_tool_name_validity(name, ctx.user_id),
               :ok <- DmhAi.Agent.Police.check_tool_call_schema(name, args),
               :ok <- DmhAi.Agent.Police.check_no_duplicate_tool_call(name, args, prior_acc),
               :ok <- DmhAi.Agent.Police.check_workflow_build_continuity(name, prior_acc),
               :ok <- DmhAi.Agent.Police.check_no_consecutive_web_search(name, args, prior_acc),
               :ok <- DmhAi.Agent.Police.check_run_script_probe_budget(name, args, prior_acc),
               :ok <- DmhAi.Agent.Police.check_write_failure_budget(name, Map.get(ctx, :write_failures, 0), AgentSettings.write_failure_budget_per_chain()) do
            progress_label = DmhAi.Agent.ProgressLabel.format(name, args)
            {:ok, row} = DmhAi.Agent.SessionProgress.append(progress_ctx, "tool", progress_label,
                                                            status: "pending")

            args_log = args |> Jason.encode!() |> String.slice(0, 600)
            DmhAi.SysLog.log("[ASSISTANT] tool=#{name} args=#{args_log}")

            tool_ctx =
              ctx
              |> Map.put(:progress_row_id, row.id)
              |> Map.put(:tool_call_id, tool_call_id)
              |> Map.put(:step_seq, tool_call_id)

            exec_started_ms = System.system_time(:millisecond)
            exec_result = DmhAi.Tools.Registry.execute(name, args, tool_ctx)
            duration_ms = System.system_time(:millisecond) - exec_started_ms

            if DmhAi.Agent.AgentSettings.log_trace() do
              DmhAi.Agent.LogTrace.write_tool(
                %{origin: "assistant", path: "UserAgent.execute_tools", role: "ToolExec"},
                name, args, exec_result, duration_ms
              )
            end

            content =
              case exec_result do
                {:ok, result} ->
                  DmhAi.Agent.SessionProgress.mark_tool_done(row.id, duration_ms)
                  result
                  |> augment_with_profile_manifest(auto_activated_profile, ctx)
                  |> format_tool_result()

                {:error, reason} ->
                  DmhAi.Agent.SessionProgress.mark_tool_done(row.id, duration_ms)
                  "Error: " <> format_tool_result(reason)
              end

            content =
              case DmhAi.Agent.Police.consecutive_run_script_advisory(name, prior_acc) do
                nil       -> content
                advisory  -> advisory <> content
              end

            content =
              case exec_result do
                {:error, _} ->
                  case DmhAi.Agent.Police.check_repeated_tool_error(name, content, prior_acc) do
                    {:rejected, {issue_atom, nudge_reason}} ->
                      "[[ISSUE:#{issue_atom}:#{name}]]\n" <> nudge_reason <> "\n\n" <> content

                    :ok ->
                      content
                  end

                _ ->
                  content
              end

            {%{role: "tool", name: name, content: content, tool_call_id: tool_call_id}, exec_result}
          else
            {:rejected, reason} = rej when is_binary(reason) ->
              {%{role: "tool", name: name, content: reason, tool_call_id: tool_call_id}, rej}

            {:rejected, {issue_atom, reason}} = rej when is_atom(issue_atom) ->
              marker = "[[ISSUE:#{issue_atom}:#{name}]]\n"
              {%{role: "tool", name: name, content: marker <> reason, tool_call_id: tool_call_id}, rej}
          end

        rejected? = match?({:rejected, _}, exec_result)
        tagged_call = if rejected?, do: Map.put(call, "_rejected", true), else: call

        # Tally write-class outcomes into ctx counters. These are what
        # the write-failure-budget + phantom-outcome checks read — NOT
        # message text, because the rolling tool-result flush rewrites
        # old result bodies to a success-looking placeholder and would
        # erase the failure signal. Only tools that ACTUALLY RAN count
        # (a Police rejection never executed → neither attempt nor
        # failure).
        ctx =
          if not rejected? and DmhAi.Agent.Police.write_class?(name) do
            failed_inc = if match?({:error, _}, exec_result), do: 1, else: 0

            ctx =
              ctx
              |> Map.update(:write_attempts, 1, &(&1 + 1))
              |> Map.update(:write_failures, failed_inc, &(&1 + failed_inc))

            # Outcome tally is the subset the phantom-outcome guard
            # reads: setup/connection writes (`outcome_write: false`,
            # e.g. connect_mcp) are excluded so an incidental success
            # can't mask a chain whose real action never landed.
            if DmhAi.Agent.Police.outcome_write?(name) do
              ctx
              |> Map.update(:outcome_attempts, 1, &(&1 + 1))
              |> Map.update(:outcome_failures, failed_inc, &(&1 + failed_inc))
            else
              ctx
            end
          else
            ctx
          end

        pseudo = %{"role" => "assistant", "tool_calls" => [tagged_call]}

        {[{tool_msg, tagged_call, exec_result}], {prior_acc ++ [pseudo], ctx}}
      end)

    tool_msgs    = Enum.map(triples, fn {m, _, _} -> m end)
    tagged_calls = Enum.map(triples, fn {_, c, _} -> c end)
    exec_results = Enum.map(triples, fn {_, _, r} -> r end)

    {tool_msgs, tagged_calls, exec_results, final_ctx}
  end

  defp format_tool_result(result) when is_binary(result), do: result
  defp format_tool_result(%{envelope: env}) when is_binary(env), do: env
  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(normalise_json(result), pretty: true)
  defp format_tool_result(result) when is_number(result) or is_boolean(result),
    do: to_string(result)
  defp format_tool_result(nil), do: ""
  defp format_tool_result(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_tool_result(other), do: Jason.encode!(normalise_json(other))

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

  # ── ISSUE marker + nudge counter ────────────────────────────────────────

  # Default cap on how many same-class Police rejections may accrue in a
  # single chain before the safety-abort kicks in.
  @model_behavior_nudge_limit 3

  # Per-class overrides. `:duplicate_tool_call_in_chain` aborts on the
  # FIRST occurrence — a literal repeat is a strong signal the model is
  # spinning on a failed assumption rather than pivoting strategy, so we
  # don't give it three chances. Other classes inherit the default.
  @per_issue_nudge_limit %{
    duplicate_tool_call_in_chain: 1,
    write_failure_budget:         1
  }

  defp bump_nudge_counters(ctx, tool_result_msgs) do
    existing  = Map.get(ctx, :nudges, %{})
    prior_err = Map.get(ctx, :last_substantive_error)
    marker_re = ~r/^\[\[ISSUE:([a-z_]+):([^\]]*)\]\]\n?/u

    role  = Map.get(ctx, :role, "assistant")
    model = Map.get(ctx, :model, "unknown")

    {clean_msgs, {nudges_after, last_err}} =
      Enum.map_reduce(tool_result_msgs, {existing, prior_err}, fn msg, {acc, last} ->
        raw = msg[:content] || msg["content"] || ""

        case Regex.run(marker_re, raw) do
          [full, atom_name, tool_name] ->
            key = String.to_atom(atom_name)
            new_acc = Map.update(acc, key, 1, &(&1 + 1))
            DmhAi.Agent.ModelBehaviorStats.record(role, model, atom_name, tool_name)
            cleaned = String.replace_prefix(raw, full, "")
            {Map.put(msg, :content, cleaned), {new_acc, last}}

          _ ->
            # A tool result with no ISSUE marker is a real tool/validator
            # outcome, not a Police meta-rejection. Remember the most
            # recent ERROR among them so an eventual circuit-break can
            # tell the user what actually blocked the chain. It rides on
            # ctx (not the message list) so the rolling tool-result flush
            # can't erase it before the abort message is built.
            {msg, {acc, latest_tool_error(raw, last)}}
        end
      end)

    ctx =
      ctx
      |> Map.put(:nudges, nudges_after)
      |> Map.put(:last_substantive_error, last_err)

    {ctx, clean_msgs}
  end

  defp latest_tool_error(content, last) when is_binary(content) do
    if String.starts_with?(content, "Error:"), do: String.trim(content), else: last
  end

  defp latest_tool_error(_content, last), do: last

  defp wrap_runtime_correction(reason) do
    "[ Runtime correction - Apply the below and continue your current chain ]\n\n" <> reason
  end

  defp record_non_tool_issue(ctx, issue_atom) do
    role  = Map.get(ctx, :role, "assistant")
    model = Map.get(ctx, :model, "unknown")

    DmhAi.Agent.ModelBehaviorStats.record(role, model, Atom.to_string(issue_atom), "")

    nudges =
      ctx
      |> Map.get(:nudges, %{})
      |> Map.update(issue_atom, 1, &(&1 + 1))

    Map.put(ctx, :nudges, nudges)
  end

  defp maybe_abort_on_model_behavior_issue(ctx, model) do
    nudges = Map.get(ctx, :nudges, %{})

    over =
      Enum.find(nudges, fn {k, count} ->
        limit = Map.get(@per_issue_nudge_limit, k, @model_behavior_nudge_limit)
        count >= limit
      end)

    case over do
      nil ->
        :continue

      {issue, count} ->
        role = Map.get(ctx, :role, "assistant")
        Logger.error(
          "[ModelBehaviorIssue] type=#{issue} model=#{model} session=#{ctx.session_id} count=#{count} — aborting turn"
        )
        DmhAi.SysLog.log(
          "[CRITICAL] ModelBehaviorIssue type=#{issue} model=#{model} session=#{ctx.session_id} count=#{count}"
        )
        DmhAi.Agent.ModelBehaviorStats.record(role, model, "escalated_#{issue}", "")

        user_msg = circuit_breaker_message(issue, error_gist(Map.get(ctx, :last_substantive_error)))
        StreamBuffer.clear(ctx.session_id, ctx.user_id)
        ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
        {:ok, _} = append_session_message(ctx.session_id, ctx.user_id,
                                          %{role: "assistant", content: user_msg})
        :aborted
    end
  end

  # Cap on how much of the underlying error we splice into the
  # user-facing circuit-breaker message — the gist, not the whole
  # remediation paragraph.
  @abort_error_excerpt_chars 200

  # Error/repeat classes fold in the actual blocker (the last real
  # tool error, captured on ctx) so the user learns WHY the chain
  # stopped instead of a generic "rephrase". Budget/empty classes
  # have no underlying tool error worth surfacing.
  defp circuit_breaker_message(:duplicate_tool_call_in_chain, gist),
    do: with_blocker("I couldn't finish this — I kept repeating the same step instead of correcting it", gist)

  defp circuit_breaker_message(:repeated_tool_error, gist),
    do: with_blocker("I kept hitting the same error and couldn't make progress", gist)

  defp circuit_breaker_message(:tool_call_schema, gist),
    do: with_blocker("I kept calling one of my tools with the wrong arguments", gist)

  defp circuit_breaker_message(:run_script_probe_budget, _gist),
    do: "I ran out of tool-call budget. Please split this into smaller steps."

  defp circuit_breaker_message(:no_consecutive_web_search, _gist),
    do: "I ran out of search budget. Please narrow down what you're looking for."

  defp circuit_breaker_message(:empty_response, _gist),
    do: "I tried to reply and produced nothing several times in a row. Please retry."

  defp circuit_breaker_message(_other, _gist),
    do: "I hit an internal safety limit on this task. Please rephrase or try again."

  defp error_gist(nil), do: nil

  defp error_gist(err) when is_binary(err) do
    err
    |> String.replace_prefix("Error: ", "")
    |> String.split(~r/\.\s/, parts: 2)
    |> List.first()
    |> String.slice(0, @abort_error_excerpt_chars)
    |> String.trim()
  end

  defp with_blocker(lead, nil),
    do: lead <> ". Please rephrase the request or add a detail I can act on differently."

  defp with_blocker(lead, gist),
    do:
      lead <>
        ". The blocker was: " <>
        gist <> ". You can confirm those details or rephrase it, and I'll try a different approach."

  # ── splice + tool-result flush ──────────────────────────────────────────

  defp splice_mid_chain_user_msgs(messages, %{session_id: session_id}) do
    floor_ts = max_user_ts_in_messages(messages)

    case DmhAi.Agent.UserAgentMessages.user_msgs_since(session_id, floor_ts) do
      [] ->
        messages

      new_msgs ->
        DmhAi.SysLog.log("[ASSISTANT] mid-chain splice: #{length(new_msgs)} new user msg(s) since ts=#{floor_ts}")
        messages ++ new_msgs
    end
  end

  defp max_user_ts_in_messages(messages) do
    Enum.reduce(messages, 0, fn m, acc ->
      role = m[:role] || m["role"]
      ts   = m[:ts]   || m["ts"]

      if role == "user" and is_integer(ts) and ts > acc, do: ts, else: acc
    end)
  end

  # Rolling tool-result flush. For `role: "tool"` messages whose
  # `emit_turn` is older than `tool_result_retention_turns`, REPLACE
  # the `content` body with `@flushed_tool_result_placeholder`; keep
  # the message itself and its `tool_call_id` so the LLM-API pairing
  # rule (every `tool_call` has a matching `tool_result`) stays
  # intact. The prior assistant text + the original `tool_call` args
  # ride forward verbatim — only the verbose result body is dropped.
  # See architecture.md §Rolling tool-result flush.
  @flushed_tool_result_placeholder "[result removed to save tokens]"

  defp flush_stale_tool_results(messages, current_turn) do
    retention = AgentSettings.tool_result_retention_turns()

    Enum.map(messages, fn m ->
      role = m[:role] || m["role"]
      emit_turn = m[:emit_turn] || m["emit_turn"]

      if role == "tool" and is_integer(emit_turn) and current_turn - emit_turn > retention do
        replace_content(m, @flushed_tool_result_placeholder)
      else
        m
      end
    end)
  end

  defp replace_content(msg, new_content) do
    cond do
      Map.has_key?(msg, :content)  -> Map.put(msg, :content, new_content)
      Map.has_key?(msg, "content") -> Map.put(msg, "content", new_content)
      true                         -> Map.put(msg, :content, new_content)
    end
  end

  # ── session / profile helpers ───────────────────────────────────────────

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
          {:error, :session_not_found}
      end
    rescue
      e ->
        Logger.error("[UserAgent] append_session_message failed: #{Exception.message(e)}")
        {:error, :exception}
    end
  end

  def load_session(session_id, user_id) do
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

          {:ok, model || "",
           %{"id" => session_id,
             "messages" => messages,
             "context" => context,
             "mode" => mode || "confidant"}}

        _ ->
          {:error, "Session not found"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp extract_user_messages(session_data) do
    messages = session_data["messages"] || []

    messages
    |> Enum.filter(fn m -> m["role"] == "user" end)
    |> Enum.take(-10)
    |> Enum.map(fn m -> String.slice(m["content"] || "", 0, 300) end)
  end

  defp build_memo_context(current_content, recent_user_msgs, user_id) do
    case __MODULE__.get_memo_key(user_id) do
      nil ->
        {nil, []}

      mmk ->
        do_build_memo_context(current_content, recent_user_msgs, user_id, mmk)
    end
  end

  defp do_build_memo_context(current_content, recent_user_msgs, user_id, mmk) do
    prior =
      recent_user_msgs
      |> Enum.drop(-1)
      |> Enum.take(-2)

    embed_text = (prior ++ [current_content]) |> Enum.join("\n") |> String.trim()

    case Embedder.embed(embed_text) do
      {:ok, vec} ->
        top_k = AgentSettings.memo_context_top_k()

        case VectorDB.search(:memo, embed_text, vec, top_k, {:user, user_id}) do
          {:ok, raw_hits} ->
            hits = Enum.map(raw_hits, &decrypt_memo_hit(&1, mmk)) |> Enum.reject(&is_nil/1)
            log_memo_retrieval(embed_text, raw_hits, hits)
            {format_memo_context_block(hits), hits}

          {:error, reason} ->
            Logger.warning("[Memo auto] search failed: #{inspect(reason, limit: 80)}")
            {nil, []}
        end

      {:error, reason} ->
        Logger.warning("[Memo auto] embed failed: #{inspect(reason, limit: 80)}")
        {nil, []}
    end
  end

  defp log_memo_retrieval(embed_text, raw_hits, hits) do
    score_summary =
      hits
      |> Enum.map(fn h ->
        s = if is_number(h.score), do: Float.round(h.score, 3), else: h.score
        "#{s}|#{String.slice(h.chunk_text || "", 0, 40) |> String.replace("\n", " ")}"
      end)
      |> Enum.join("; ")

    line =
      "[Memo auto] embed=#{inspect(String.slice(embed_text, 0, 80))} " <>
        "raw=#{length(raw_hits)} decrypted=#{length(hits)} hits=[#{score_summary}]"

    Logger.info(line)
    DmhAi.SysLog.log(line)
  end

  defp decrypt_memo_hit(hit, mmk) do
    src_id = Map.get(hit, :source_id) || ""
    idx    = Map.get(hit, :chunk_idx) || 0
    case DmhAi.MemoCrypto.decrypt_chunk(hit.chunk_text, mmk, src_id, idx) do
      {:ok, plain}                  -> %{hit | chunk_text: plain}
      {:error, :legacy_plaintext}   -> hit
      {:error, :bad_key}            ->
        Logger.warning("[Memo auto] decrypt failed for source_id=#{inspect(src_id)} idx=#{inspect(idx)} — row dropped")
        nil
    end
  end

  defp format_memo_context_block([]) do
    "We checked the user's saved memos for this question. Nothing relevant found.\n\n" <>
      "How to use this signal:\n" <>
      "- IF the user's message references the memo store: tell the user honestly that no saved memo matches their question.\n" <>
      "- OTHERWISE: ignore this block entirely and answer per usual."
  end

  defp format_memo_context_block(hits) do
    bullets =
      hits
      |> Enum.map_join("\n", fn h ->
        "- " <> String.replace(h.chunk_text || "", "\n", " ")
      end)

    "The user previously saved these personal notes. Use any that are relevant; ignore the rest.\n\n" <>
      bullets
  end

  defp build_web_context(_content, %{snippets: [], pages: []}, _reply_pid), do: nil

  defp build_web_context(_content, result_map, _reply_pid) do
    raw = format_raw_results(result_map)

    if raw == "" do
      nil
    else
      String.slice(raw, 0, AgentSettings.web_results_max_chars())
    end
  end

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

  defp load_image_descriptions(session_id) do
    try do
      result = query!(Repo, "SELECT name, description FROM image_descriptions WHERE session_id=?",
                      [session_id])
      Enum.map(result.rows, fn [name, desc] -> %{name: name, description: desc} end)
    rescue
      _ -> []
    end
  end

  defp load_video_descriptions(session_id) do
    try do
      result = query!(Repo, "SELECT name, description FROM video_descriptions WHERE session_id=?",
                      [session_id])
      Enum.map(result.rows, fn [name, desc] -> %{name: name, description: desc} end)
    rescue
      _ -> []
    end
  end

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

  defp lookup_user_email(user_id) do
    try do
      case query!(Repo, "SELECT email FROM users WHERE id=?", [user_id]) do
        %{rows: [[email]]} when is_binary(email) -> email
        _ -> ""
      end
    rescue
      _ -> ""
    end
  end

  defp lookup_user_role(user_id) do
    try do
      case query!(Repo, "SELECT role FROM users WHERE id=?", [user_id]) do
        %{rows: [[role]]} when is_binary(role) -> role
        _ -> "user"
      end
    rescue
      _ -> "user"
    end
  end

  defp compact_if_needed(session_id, user_id, session_data) do
    case DmhAi.Agent.Compactor.maybe_compact(session_id, user_id) do
      {:compacted, _kept_chars} ->
        ctx =
          case query!(Repo, "SELECT context FROM sessions WHERE id=?", [session_id]) do
            %{rows: [[ctx_json]]} ->
              case Jason.decode(ctx_json || "{}") do
                {:ok, m} when is_map(m) -> m
                _ -> %{}
              end

            _ ->
              %{}
          end

        Map.put(session_data, "context", ctx)

      _ ->
        session_data
    end
  end
end
