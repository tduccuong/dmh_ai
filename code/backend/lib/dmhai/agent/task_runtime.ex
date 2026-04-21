# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.TaskRuntime do
  @moduledoc """
  Owns the lifecycle of every task.

  Responsibilities:
    - Spawn a worker for a task (pending → running).
    - Poll worker_status rows via a per-task cursor on the tasks row.
    - Emit progress chunks to the session's chat (visible spinner updates).
    - Detect the `kind='final'` row → transition the task to done/blocked,
      emit the completion message, reschedule the next run for periodic tasks.
    - Detect orphaned workers (process dead without a `final` row) and mark BLOCKED.
    - Boot-time rehydration: kill orphaned 'running' tasks, spawn due-periodic.

  Architecture:
    A single supervised GenServer (registered globally) that keeps a map of
    running tasks keyed by task_id. For each task, a Task polls worker_status
    at `max(K, intvl/M)` intervals. When a Task exits, the GenServer either
    reschedules the next periodic run or leaves the task terminal.
  """

  use GenServer
  require Logger

  alias Dmhai.Agent.{AgentSettings, LLM, MasterBuffer, Tasks, Worker, WorkerStatus}

  @name __MODULE__
  @summarizer_locks :task_summarizer_locks

  # ─── Client API ──────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @doc "Start a new task run (called after Tasks.insert). Idempotent."
  def start_task(task_id) when is_binary(task_id) do
    GenServer.cast(@name, {:start_task, task_id})
  end

  @doc "Cancel a task: stop worker (if any), prevent future runs."
  def cancel_task(task_id) when is_binary(task_id) do
    GenServer.call(@name, {:cancel_task, task_id})
  end

  @doc "Pause a task: stop worker, preserve task data so it can be resumed later."
  def pause_task(task_id) when is_binary(task_id) do
    GenServer.call(@name, {:pause_task, task_id})
  end

  @doc "Resume a paused task: re-spawn the worker from scratch."
  def resume_task(task_id) when is_binary(task_id) do
    GenServer.call(@name, {:resume_task, task_id})
  end

  @doc "List currently running tasks (for debugging / admin)."
  def list_running do
    GenServer.call(@name, :list_running)
  end

  @doc "Boot rehydration — called at app startup after DB is ready."
  def rehydrate do
    GenServer.cast(@name, :rehydrate)
  end

  @doc """
  Generate a progress summary of the task's activity since the last summary
  and append it to the session. Returns the summary text (or a canned message).

  - force=false (from poller): skips the LLM call if nothing new.
  - force=true  (from Assistant's read_task_status): always responds, with a
    fixed "no new activity" message if the cursor is already at the latest row.
  """
  @spec summarize_and_announce(String.t(), keyword()) ::
          :ok
          | {:ok, String.t()}
          | {:error, term()}
          | {:skipped, String.t()}
  def summarize_and_announce(task_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    # Per-task mutex: first caller wins the insert, others see an active lock
    # and either skip (poller) or return a "being prepared" message (user query).
    if :ets.insert_new(@summarizer_locks, {task_id, self(), System.os_time(:millisecond)}) do
      try do
        do_summarize_and_announce(task_id, force)
      after
        :ets.delete(@summarizer_locks, task_id)
      end
    else
      if force do
        lang =
          case Tasks.get(task_id) do
            %{language: l} -> l
            _ -> "en"
          end
        {:skipped, Dmhai.I18n.t("summary_already_being_prepared", lang)}
      else
        :ok
      end
    end
  end

  # ─── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_) do
    Logger.info("[TaskRuntime] started")

    # ETS-backed per-task mutex for summarize_and_announce. A row in this
    # table means "a summariser is currently in flight for that task_id."
    # Prevents duplicate summaries when the poller and a user query race.
    :ets.new(@summarizer_locks, [:set, :public, :named_table])

    # Reschedule boot rehydration after supervisor tree is up.
    # Skipped in :test env (tests control lifecycle explicitly).
    if Application.get_env(:dmhai, :enable_task_rehydrate, true) do
      Process.send_after(self(), :rehydrate, 500)
    end
    {:ok, %{tasks: %{}, reschedule_timers: %{}}}
  end

  @impl true
  def handle_cast({:start_task, task_id}, state) do
    state = do_start_task(task_id, state)
    {:noreply, state}
  end

  def handle_cast(:rehydrate, state) do
    state = do_rehydrate(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:cancel_task, task_id}, _from, state) do
    state = do_cancel_task(task_id, state)
    Tasks.mark_cancelled(task_id)
    {:reply, :ok, state}
  end

  def handle_call({:pause_task, task_id}, _from, state) do
    state = do_pause_task(task_id, state)
    Tasks.mark_paused(task_id)
    {:reply, :ok, state}
  end

  def handle_call({:resume_task, task_id}, _from, state) do
    case Tasks.get(task_id) do
      %{task_status: "paused"} ->
        Tasks.mark_pending(task_id)
        state = do_start_task(task_id, state)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_paused}, state}
    end
  end

  def handle_call(:list_running, _from, state) do
    rows = Enum.map(state.tasks, fn {tid, %{started_at: t}} -> %{task_id: tid, started_at: t} end)
    {:reply, rows, state}
  end

  # A per-task poller Task finished. Check the task's terminal status and
  # reschedule the next run if periodic + not cancelled.
  @impl true
  def handle_info({ref, {:poller_done, task_id, outcome}}, state) do
    Process.demonitor(ref, [:flush])
    record = Map.get(state.tasks, task_id, %{})
    state  = update_in(state.tasks, &Map.delete(&1, task_id))
    state  = handle_poller_outcome(task_id, outcome, record, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("[TaskRuntime] task crashed reason=#{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:run_scheduled, task_id}, state) do
    state = update_in(state.reschedule_timers, &Map.delete(&1, task_id))
    {:noreply, do_start_task(task_id, state, true)}
  end

  def handle_info(:rehydrate, state) do
    {:noreply, do_rehydrate(state)}
  end

  # Worker tasks (async_nolink) send {ref, result} on normal completion. The
  # poller handles terminal state via worker_status, so we just swallow this.
  def handle_info({_ref, _result}, state), do: {:noreply, state}

  # ─── Private ─────────────────────────────────────────────────────────────

  defp do_start_task(task_id, state, clean_previous \\ false) do
    cond do
      Map.has_key?(state.tasks, task_id) ->
        Logger.warning("[TaskRuntime] task #{task_id} already running, skip start_task")
        state

      true ->
        case Tasks.get(task_id) do
          nil ->
            Logger.error("[TaskRuntime] start_task: task #{task_id} not found")
            state

          %{task_status: "cancelled"} ->
            Logger.info("[TaskRuntime] skip cancelled task=#{task_id}")
            state

          task ->
            if clean_previous do
              Dmhai.Agent.UserAgentMessages.archive_by_task_id(task.session_id, task.user_id, task.task_id)
            end
            worker_id = gen_worker_id()
            Tasks.mark_running(task_id, worker_id)

            # Spawn the worker under the existing WorkerSupervisor.
            worker_task = spawn_worker_task(task, worker_id)

            # Spawn the poller under TaskSupervisor. When it exits, we get
            # {ref, {:poller_done, ...}} and handle rescheduling there.
            # Start cursor at last_reported_status_id so periodic re-runs don't
            # re-process final rows from previous cycles.
            start_cursor = task.last_reported_status_id || 0
            poller =
              Task.Supervisor.async_nolink(
                Dmhai.Agent.TaskSupervisor,
                fn -> poller_loop(task_id, worker_task, start_cursor) end
              )

            record = %{
              worker_id:     worker_id,
              worker_task:   worker_task,
              poller_task:   poller,
              started_at:    System.os_time(:millisecond),
              restart_count: Map.get(state.tasks[task_id] || %{}, :restart_count, 0)
            }

            %{state | tasks: Map.put(state.tasks, task_id, record)}
        end
    end
  end

  defp spawn_worker_task(task, worker_id) do
    email         = lookup_user_email(task.user_id)
    session_root  = Dmhai.Constants.session_root(email, task.session_id)
    data_dir      = Dmhai.Constants.session_data_dir(email, task.session_id)
    workspace_dir = Dmhai.Constants.task_workspace_dir(email, task.session_id, task.origin || "assistant", task.task_id)

    # Eagerly create the workspace so tools can write without pre-mkdir gymnastics.
    File.mkdir_p(workspace_dir)
    File.mkdir_p(data_dir)

    Task.Supervisor.async_nolink(Dmhai.Agent.WorkerSupervisor, fn ->
      ctx = %{
        user_id:       task.user_id,
        user_email:    email,
        session_id:    task.session_id,
        worker_id:     worker_id,
        task_id:       task.task_id,
        description:   task.task_title,
        language:      task.language || "en",
        origin:        task.origin    || "assistant",
        pipeline:      task.pipeline  || "assistant",
        session_root:  session_root,
        data_dir:      data_dir,
        workspace_dir: workspace_dir,
        log_trace:     AgentSettings.log_trace()
      }

      try do
        Worker.run(task.task_spec, ctx)
      rescue
        e ->
          Logger.error("[TaskRuntime] worker crashed task=#{task.task_id}: #{Exception.message(e)}")
          WorkerStatus.append(task.task_id, worker_id, "final",
            "Worker crashed: #{Exception.message(e)}", "TASK_BLOCKED")
          {:error, Exception.message(e)}
      end
    end)
  end

  defp lookup_user_email(user_id), do: Tasks.lookup_user_email(user_id)

  # Poller loop: tails worker_status, pushes progress to the session, detects
  # the 'final' row, and returns {:poller_done, task_id, outcome}.
  defp poller_loop(task_id, worker_task, last_cursor) do
    # Re-read task row each iteration (status/intvl can change mid-flight).
    case Tasks.get(task_id) do
      nil ->
        {:poller_done, task_id, {:error, :task_deleted}}

      %{task_status: "cancelled"} = task ->
        safe_shutdown_worker(worker_task)
        lang = task.language || "en"
        WorkerStatus.append(task_id, "runtime", "final",
          Dmhai.I18n.t("task_cancelled_by_user", lang), "TASK_BLOCKED")
        {:poller_done, task_id, {:cancelled, nil}}

      %{task_status: "paused"} ->
        safe_shutdown_worker(worker_task)
        {:poller_done, task_id, {:paused, nil}}

      task ->
        new_rows = WorkerStatus.fetch_since(task_id, last_cursor)
        new_cursor = case new_rows do
          [] -> last_cursor
          rows -> rows |> List.last() |> Map.get(:id)
        end

        if new_cursor != last_cursor do
          Tasks.advance_cursor(task_id, new_cursor)
          broadcast_progress(task, new_rows)
        end

        final = Enum.find(new_rows, fn r -> r.kind == "final" end)

        # Unsolicited progress summary: run when enough new rows OR enough time has passed.
        maybe_announce_progress(task)

        cond do
          final && final.signal_status == "TASK_RESTART" ->
            {:poller_done, task_id, {:restart, final.content || "exec error restart"}}

          final ->
            finalize_task(task, final)
            {:poller_done, task_id, {:final, final.signal_status, final.content}}

          worker_dead?(worker_task) ->
            # Worker exited without a final row yet — peek ONE more time in case
            # the final row landed while we were deciding.
            case WorkerStatus.fetch_since(task_id, last_cursor) do
              rows when rows != [] ->
                case Enum.find(rows, fn r -> r.kind == "final" end) do
                  nil ->
                    lang = task.language || "en"
                    reason = Dmhai.I18n.t("worker_exited_no_signal", lang)
                    WorkerStatus.append(task_id, task.current_worker_id || "runtime", "final", reason, "TASK_BLOCKED")
                    Tasks.mark_blocked(task_id, reason)
                    emit_final_message(task, "TASK_BLOCKED", reason)
                    {:poller_done, task_id, {:final, "TASK_BLOCKED", reason}}

                  final_row ->
                    finalize_task(task, final_row)
                    {:poller_done, task_id, {:final, final_row.signal_status, final_row.content}}
                end

              _ ->
                lang = task.language || "en"
                reason = Dmhai.I18n.t("worker_exited_no_signal", lang)
                WorkerStatus.append(task_id, task.current_worker_id || "runtime", "final", reason, "TASK_BLOCKED")
                Tasks.mark_blocked(task_id, reason)
                emit_final_message(task, "TASK_BLOCKED", reason)
                {:poller_done, task_id, {:final, "TASK_BLOCKED", reason}}
            end

          true ->
            interval_ms = poll_interval_ms(task)
            Process.sleep(interval_ms)
            poller_loop(task_id, worker_task, new_cursor)
        end
    end
  end

  defp worker_dead?(%Task{pid: pid}) when is_pid(pid), do: not Process.alive?(pid)
  defp worker_dead?(_), do: true

  defp safe_shutdown_worker(%Task{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Task.Supervisor.terminate_child(Dmhai.Agent.WorkerSupervisor, pid)
  end
  defp safe_shutdown_worker(_), do: :ok

  defp safe_shutdown_poller(%Task{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Task.Supervisor.terminate_child(Dmhai.Agent.TaskSupervisor, pid)
  end
  defp safe_shutdown_poller(_), do: :ok

  defp poll_interval_ms(%{task_type: "periodic", intvl_sec: intvl}) when is_integer(intvl) and intvl > 0 do
    k = AgentSettings.task_poll_min_interval_sec()
    m = AgentSettings.task_poll_samples_per_cycle()
    ms = max(k, div(intvl, max(m, 1))) * 1_000
    apply_override(ms)
  end

  defp poll_interval_ms(_task) do
    ms = AgentSettings.task_poll_min_interval_sec() * 1_000
    apply_override(ms)
  end

  # Test-only override: when :task_poll_override_ms is set in the env, it forces
  # the poll interval to exactly that value (bypassing K settings). Production
  # runs leave this unset and use the K/M calculation above.
  defp apply_override(default_ms) do
    case Application.get_env(:dmhai, :task_poll_override_ms) do
      nil        -> default_ms
      override   -> override
    end
  end

  defp finalize_task(task, %{signal_status: "TASK_DONE", content: content}) do
    Tasks.mark_done(task.task_id, content || "")
    emit_final_message(task, "TASK_DONE", content || "")
  end

  # Handles both model-called TASK_BLOCKED and runtime-synthesized BLOCKED.
  defp finalize_task(task, %{signal_status: status, content: content})
       when status in ["TASK_BLOCKED", "BLOCKED"] do
    do_summarize_and_announce(task.task_id, true)
    Tasks.mark_blocked(task.task_id, content || "(no reason)")
    emit_final_message(task, "TASK_BLOCKED", content || "(no reason)")
  end

  defp finalize_task(task, _), do: Tasks.mark_blocked(task.task_id, "Final row with unknown status.")

  # Broadcast progress rows to the session (visible as subtle chunks in the UI).
  # For now we emit a single "step" per batch; frontend can render as spinner text.
  defp broadcast_progress(_task, []), do: :ok
  defp broadcast_progress(_task, _rows), do: :ok

  # ── progress summarizer (delta-only) ─────────────────────────────────────

  # Poller-driven: fire a summary when enough new rows have accumulated AND
  # enough time has passed since the last summary. Both thresholds must be
  # crossed to avoid spamming the user on bursty tasks.
  defp maybe_announce_progress(task) do
    min_cycle = AgentSettings.task_progress_summary_min_cycle_sec()

    if task.task_type == "periodic" and is_integer(task.intvl_sec) and task.intvl_sec < min_cycle do
      :ok
    else
      n_threshold = AgentSettings.task_progress_summary_every_n_rows()
      t_threshold_ms = AgentSettings.task_progress_summary_min_interval_sec() * 1_000
      now = System.os_time(:millisecond)

      new_row_count =
        WorkerStatus.fetch_since(task.task_id, task.last_summarized_status_id || 0)
        |> Enum.count(fn r -> r.kind != "progress_summary" end)

      last_at = task.last_summarized_at || 0
      elapsed_ms = now - last_at

      if new_row_count >= n_threshold and elapsed_ms >= t_threshold_ms do
        do_summarize_and_announce(task.task_id, false)
      else
        :ok
      end
    end
  end

  defp do_summarize_and_announce(task_id, force) do
    case Tasks.get(task_id) do
      nil -> {:error, :task_not_found}
      task ->
        cursor = task.last_summarized_status_id || 0
        all_rows = WorkerStatus.fetch_since(task.task_id, cursor)
        # Don't let summary rows become input to the next summary.
        new_rows = Enum.reject(all_rows, fn r -> r.kind == "progress_summary" end)

        cond do
          new_rows == [] and not force ->
            :ok

          new_rows == [] and force ->
            lang = task.language || "en"
            text = Dmhai.I18n.t("no_new_activity", lang, %{title: task.task_title})
            append_progress_to_session(task, text)
            {:ok, text}

          true ->
            case call_summarizer(task, new_rows) do
              {:ok, text} when is_binary(text) and text != "" ->
                max_id = new_rows |> List.last() |> Map.get(:id)
                WorkerStatus.append(task.task_id, task.current_worker_id || "runtime",
                  "progress_summary", text)
                append_progress_to_session(task, text)
                Tasks.advance_summary_cursor(task.task_id, max_id)
                {:ok, text}

              {:ok, other} ->
                Logger.warning("[TaskRuntime] summarizer returned non-text task=#{task.task_id}: #{inspect(other)}")
                {:error, :non_text_summary}

              {:error, reason} ->
                Logger.warning("[TaskRuntime] summarizer failed task=#{task.task_id}: #{inspect(reason)}")
                {:error, reason}
            end
        end
    end
  end

  defp call_summarizer(task, rows) do
    flat = Enum.map_join(rows, "\n", fn r ->
      "[#{r.kind}] #{String.slice(r.content || "", 0, 400)}"
    end)

    lang = task.language || "en"

    prompt = [
      %{role: "user", content:
        "You are the progress reporter for a background task. " <>
        "Task title: \"#{task.task_title}\". Task spec: \"#{String.slice(task.task_spec, 0, 400)}\".\n\n" <>
        "Below is the activity log since the last update. " <>
        "Write a status update in EXACTLY this format: \"<title>: <detail>\"\n" <>
        "  - <title>: 2–6 words, noun phrase describing the current action (e.g. \"Downloading report\", \"Running analysis\")\n" <>
        "  - <detail>: 1–2 sentences max, describing ONLY what the log slice shows. No speculation, no prior activity.\n" <>
        "Output ONLY the single line — no explanation, no bullet, no markdown.\n\n" <>
        "IMPORTANT: write the update in the user's language, ISO 639-1 code \"#{lang}\". " <>
        "Do not use any other language.\n\n" <>
        "Activity:\n#{flat}"}
    ]

    trace = %{origin: "assistant", path: "TaskRuntime.summarize_progress", role: "ProgressSummarizer", phase: "summarize"}
    LLM.call(AgentSettings.summarizer_model(), prompt, trace: trace)
  end

  defp append_progress_to_session(task, text) do
    lang = task.language || "en"
    notify = Dmhai.I18n.t("notify_progress", lang, %{title: task.task_title})
    MasterBuffer.append_progress_notification(task.session_id, task.user_id, text, String.slice(notify, 0, 200))
  end

  defp emit_final_message(task, "TASK_DONE", result) do
    lang = task.language || "en"
    body = "**#{task.task_title}**\n\n#{result}"
    append_assistant_message(task.session_id, task.user_id, body, %{"task_id" => task.task_id})
    notify = Dmhai.I18n.t("notify_done", lang, %{title: task.task_title})
    MasterBuffer.append_notification(task.session_id, task.user_id, String.slice(notify, 0, 200))
    Dmhai.MsgGateway.notify(task.user_id, notify)
  end

  defp emit_final_message(task, status, reason) when status in ["TASK_BLOCKED", "BLOCKED"] do
    lang = task.language || "en"
    blocked_label = Dmhai.I18n.t("blocked_label", lang, %{reason: reason})
    body =
      "<span style=\"color:#ef4444;font-weight:600\">🔴 #{task.task_title}:</span>\n\n#{blocked_label}"
    append_assistant_message(task.session_id, task.user_id, body, %{"task_id" => task.task_id})
    notify = Dmhai.I18n.t("notify_blocked", lang, %{title: task.task_title})
    MasterBuffer.append_notification(task.session_id, task.user_id, String.slice(notify, 0, 200))
    Dmhai.MsgGateway.notify(task.user_id, notify)
  end

  defp append_assistant_message(session_id, user_id, content, extra) do
    msg = Map.merge(%{
      role: "assistant",
      content: content,
      ts: System.os_time(:millisecond)
    }, extra)
    Dmhai.Agent.UserAgentMessages.append(session_id, user_id, msg)
  end

  # If this was a periodic task and still not cancelled, schedule the next run.
  defp handle_poller_outcome(task_id, {:restart, reason}, record, state) do
    restart_count = Map.get(record, :restart_count, 0)
    max_restarts  = AgentSettings.max_worker_restarts()

    if restart_count >= max_restarts do
      Logger.error("[TaskRuntime] max restarts (#{max_restarts}) reached — blocking task=#{task_id}")
      case Tasks.get(task_id) do
        nil -> state
        task ->
          msg = "Worker could not recover after #{max_restarts} restart(s). Permanently blocked."
          WorkerStatus.append(task_id, "runtime", "final", msg, "TASK_BLOCKED")
          Tasks.mark_blocked(task_id, msg)
          emit_final_message(task, "TASK_BLOCKED", msg)
          state
      end
    else
      Logger.warning("[TaskRuntime] restarting worker attempt=#{restart_count + 1}/#{max_restarts} task=#{task_id}: #{reason}")
      new_state = do_start_task(task_id, state, false)
      update_in(new_state.tasks, fn tasks ->
        case Map.get(tasks, task_id) do
          nil -> tasks
          r   -> Map.put(tasks, task_id, Map.put(r, :restart_count, restart_count + 1))
        end
      end)
    end
  end

  defp handle_poller_outcome(_task_id, {:paused, _}, _record, state), do: state

  defp handle_poller_outcome(task_id, outcome, _record, state) do
    maybe_reschedule_next_run(task_id, outcome, state)
  end

  defp maybe_reschedule_next_run(task_id, _outcome, state) do
    case Tasks.get(task_id) do
      %{task_type: "periodic", intvl_sec: intvl, task_status: status}
          when status not in ["cancelled", "paused"] and is_integer(intvl) and intvl > 0 ->
        next_at = System.os_time(:millisecond) + intvl * 1_000
        Tasks.schedule_next_run(task_id, next_at)

        # Start a timer so the next run fires locally without needing a tick.
        ref = Process.send_after(self(), {:run_scheduled, task_id}, intvl * 1_000)
        %{state | reschedule_timers: Map.put(state.reschedule_timers, task_id, ref)}

      _ ->
        state
    end
  end

  defp do_cancel_task(task_id, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        # No in-flight worker — also cancel any pending periodic reschedule.
        case Map.get(state.reschedule_timers, task_id) do
          nil -> state
          ref ->
            Process.cancel_timer(ref)
            %{state | reschedule_timers: Map.delete(state.reschedule_timers, task_id)}
        end

      %{worker_task: wt, poller_task: pt} ->
        safe_shutdown_worker(wt)
        safe_shutdown_poller(pt)
        %{state | tasks: Map.delete(state.tasks, task_id)}
    end
  end

  # Same as do_cancel_task but without marking DB — caller marks paused separately.
  # Also cancels any pending reschedule timer so periodic tasks don't re-fire while paused.
  defp do_pause_task(task_id, state) do
    state =
      case Map.get(state.reschedule_timers, task_id) do
        nil -> state
        ref ->
          Process.cancel_timer(ref)
          %{state | reschedule_timers: Map.delete(state.reschedule_timers, task_id)}
      end

    case Map.get(state.tasks, task_id) do
      nil -> state
      %{worker_task: wt, poller_task: pt} ->
        safe_shutdown_worker(wt)
        safe_shutdown_poller(pt)
        %{state | tasks: Map.delete(state.tasks, task_id)}
    end
  end

  # Boot rehydration: kill orphans, spawn due periodics.
  defp do_rehydrate(state) do
    # 1. Orphans: tasks marked 'running' in DB with no in-memory worker → blocked.
    Tasks.fetch_orphaned()
    |> Enum.each(fn task ->
      if not Map.has_key?(state.tasks, task.task_id) do
        lang = task.language || "en"
        reason = Dmhai.I18n.t("worker_orphaned", lang)
        WorkerStatus.append(task.task_id, task.current_worker_id || "runtime", "final", reason, "TASK_BLOCKED")
        Tasks.mark_blocked(task.task_id, reason)
        emit_final_message(task, "TASK_BLOCKED", reason)
      end
    end)

    # 2. Periodic tasks whose next_run_at is in the past → start now.
    Enum.reduce(Tasks.fetch_due_periodic(), state, fn task, acc ->
      do_start_task(task.task_id, acc)
    end)
  end

  defp gen_worker_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
