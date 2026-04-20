# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.JobRuntime do
  @moduledoc """
  Owns the lifecycle of every job.

  Responsibilities:
    - Spawn a worker for a job (pending → running).
    - Poll worker_status rows via a per-job cursor on the jobs row.
    - Emit progress chunks to the session's chat (visible spinner updates).
    - Detect the `kind='final'` row → transition the job to done/blocked,
      emit the completion message, reschedule the next run for periodic jobs.
    - Detect orphaned workers (process dead without a `final` row) and mark BLOCKED.
    - Boot-time rehydration: kill orphaned 'running' jobs, spawn due-periodic.

  Architecture:
    A single supervised GenServer (registered globally) that keeps a map of
    running jobs keyed by job_id. For each job, a Task polls worker_status
    at `max(K, intvl/M)` intervals. When a Task exits, the GenServer either
    reschedules the next periodic run or leaves the job terminal.
  """

  use GenServer
  require Logger

  alias Dmhai.Agent.{AgentSettings, Jobs, LLM, MasterBuffer, Worker, WorkerStatus}

  @name __MODULE__
  @summarizer_locks :job_summarizer_locks

  # ─── Client API ──────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @doc "Start a new job run (called after Jobs.insert). Idempotent."
  def start_job(job_id) when is_binary(job_id) do
    GenServer.cast(@name, {:start_job, job_id})
  end

  @doc "Cancel a job: stop worker (if any), prevent future runs."
  def cancel_job(job_id) when is_binary(job_id) do
    GenServer.call(@name, {:cancel_job, job_id})
  end

  @doc "Pause a job: stop worker, preserve job data so it can be resumed later."
  def pause_job(job_id) when is_binary(job_id) do
    GenServer.call(@name, {:pause_job, job_id})
  end

  @doc "Resume a paused job: re-spawn the worker from scratch."
  def resume_job(job_id) when is_binary(job_id) do
    GenServer.call(@name, {:resume_job, job_id})
  end

  @doc "List currently running jobs (for debugging / admin)."
  def list_running do
    GenServer.call(@name, :list_running)
  end

  @doc "Boot rehydration — called at app startup after DB is ready."
  def rehydrate do
    GenServer.cast(@name, :rehydrate)
  end

  @doc """
  Generate a progress summary of the job's activity since the last summary
  and append it to the session. Returns the summary text (or a canned message).

  - force=false (from poller): skips the LLM call if nothing new.
  - force=true  (from Assistant's read_job_status): always responds, with a
    fixed "no new activity" message if the cursor is already at the latest row.
  """
  @spec summarize_and_announce(String.t(), keyword()) ::
          :ok
          | {:ok, String.t()}
          | {:error, term()}
          | {:skipped, String.t()}
  def summarize_and_announce(job_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    # Per-job mutex: first caller wins the insert, others see an active lock
    # and either skip (poller) or return a "being prepared" message (user query).
    if :ets.insert_new(@summarizer_locks, {job_id, self(), System.os_time(:millisecond)}) do
      try do
        do_summarize_and_announce(job_id, force)
      after
        :ets.delete(@summarizer_locks, job_id)
      end
    else
      if force do
        lang =
          case Jobs.get(job_id) do
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
    Logger.info("[JobRuntime] started")

    # ETS-backed per-job mutex for summarize_and_announce. A row in this
    # table means "a summariser is currently in flight for that job_id."
    # Prevents duplicate summaries when the poller and a user query race.
    :ets.new(@summarizer_locks, [:set, :public, :named_table])

    # Reschedule boot rehydration after supervisor tree is up.
    # Skipped in :test env (tests control lifecycle explicitly).
    if Application.get_env(:dmhai, :enable_job_rehydrate, true) do
      Process.send_after(self(), :rehydrate, 500)
    end
    {:ok, %{jobs: %{}, reschedule_timers: %{}}}
  end

  @impl true
  def handle_cast({:start_job, job_id}, state) do
    state = do_start_job(job_id, state)
    {:noreply, state}
  end

  def handle_cast(:rehydrate, state) do
    state = do_rehydrate(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:cancel_job, job_id}, _from, state) do
    state = do_cancel_job(job_id, state)
    Jobs.mark_cancelled(job_id)
    {:reply, :ok, state}
  end

  def handle_call({:pause_job, job_id}, _from, state) do
    state = do_pause_job(job_id, state)
    Jobs.mark_paused(job_id)
    {:reply, :ok, state}
  end

  def handle_call({:resume_job, job_id}, _from, state) do
    case Jobs.get(job_id) do
      %{job_status: "paused"} ->
        Jobs.mark_pending(job_id)
        state = do_start_job(job_id, state)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_paused}, state}
    end
  end

  def handle_call(:list_running, _from, state) do
    rows = Enum.map(state.jobs, fn {jid, %{started_at: t}} -> %{job_id: jid, started_at: t} end)
    {:reply, rows, state}
  end

  # A per-job poller Task finished. Check the job's terminal status and
  # reschedule the next run if periodic + not cancelled.
  @impl true
  def handle_info({ref, {:poller_done, job_id, outcome}}, state) do
    Process.demonitor(ref, [:flush])
    record = Map.get(state.jobs, job_id, %{})
    state  = update_in(state.jobs, &Map.delete(&1, job_id))
    state  = handle_poller_outcome(job_id, outcome, record, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("[JobRuntime] task crashed reason=#{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:run_scheduled, job_id}, state) do
    state = update_in(state.reschedule_timers, &Map.delete(&1, job_id))
    {:noreply, do_start_job(job_id, state, true)}
  end

  def handle_info(:rehydrate, state) do
    {:noreply, do_rehydrate(state)}
  end

  # Worker tasks (async_nolink) send {ref, result} on normal completion. The
  # poller handles terminal state via worker_status, so we just swallow this.
  def handle_info({_ref, _result}, state), do: {:noreply, state}

  # ─── Private ─────────────────────────────────────────────────────────────

  defp do_start_job(job_id, state, clean_previous \\ false) do
    cond do
      Map.has_key?(state.jobs, job_id) ->
        Logger.warning("[JobRuntime] job #{job_id} already running, skip start_job")
        state

      true ->
        case Jobs.get(job_id) do
          nil ->
            Logger.error("[JobRuntime] start_job: job #{job_id} not found")
            state

          %{job_status: "cancelled"} ->
            Logger.info("[JobRuntime] skip cancelled job=#{job_id}")
            state

          job ->
            if clean_previous do
              Dmhai.Agent.UserAgentMessages.archive_by_job_id(job.session_id, job.user_id, job.job_id)
            end
            worker_id = gen_worker_id()
            Jobs.mark_running(job_id, worker_id)

            # Spawn the worker under the existing WorkerSupervisor.
            worker_task = spawn_worker_task(job, worker_id)

            # Spawn the poller under TaskSupervisor. When it exits, we get
            # {ref, {:poller_done, ...}} and handle rescheduling there.
            # Start cursor at last_reported_status_id so periodic re-runs don't
            # re-process final rows from previous cycles.
            start_cursor = job.last_reported_status_id || 0
            poller =
              Task.Supervisor.async_nolink(
                Dmhai.Agent.TaskSupervisor,
                fn -> poller_loop(job_id, worker_task, start_cursor) end
              )

            record = %{
              worker_id:     worker_id,
              worker_task:   worker_task,
              poller_task:   poller,
              started_at:    System.os_time(:millisecond),
              restart_count: Map.get(state.jobs[job_id] || %{}, :restart_count, 0)
            }

            %{state | jobs: Map.put(state.jobs, job_id, record)}
        end
    end
  end

  defp spawn_worker_task(job, worker_id) do
    email         = lookup_user_email(job.user_id)
    session_root  = Dmhai.Constants.session_root(email, job.session_id)
    data_dir      = Dmhai.Constants.session_data_dir(email, job.session_id)
    workspace_dir = Dmhai.Constants.job_workspace_dir(email, job.session_id, job.origin || "assistant", job.job_id)

    # Eagerly create the workspace so tools can write without pre-mkdir gymnastics.
    File.mkdir_p(workspace_dir)
    File.mkdir_p(data_dir)

    Task.Supervisor.async_nolink(Dmhai.Agent.WorkerSupervisor, fn ->
      ctx = %{
        user_id:       job.user_id,
        user_email:    email,
        session_id:    job.session_id,
        worker_id:     worker_id,
        job_id:        job.job_id,
        description:   job.job_title,
        language:      job.language || "en",
        origin:        job.origin    || "assistant",
        pipeline:      job.pipeline  || "assistant",
        session_root:  session_root,
        data_dir:      data_dir,
        workspace_dir: workspace_dir,
        log_trace:     AgentSettings.log_trace()
      }

      try do
        Worker.run(job.job_spec, ctx)
      rescue
        e ->
          Logger.error("[JobRuntime] worker crashed job=#{job.job_id}: #{Exception.message(e)}")
          WorkerStatus.append(job.job_id, worker_id, "final",
            "Worker crashed: #{Exception.message(e)}", "BLOCKED")
          {:error, Exception.message(e)}
      end
    end)
  end

  defp lookup_user_email(user_id), do: Jobs.lookup_user_email(user_id)

  # Poller loop: tails worker_status, pushes progress to the session, detects
  # the 'final' row, and returns {:poller_done, job_id, outcome}.
  defp poller_loop(job_id, worker_task, last_cursor) do
    # Re-read job row each iteration (status/intvl can change mid-flight).
    case Jobs.get(job_id) do
      nil ->
        {:poller_done, job_id, {:error, :job_deleted}}

      %{job_status: "cancelled"} = job ->
        safe_shutdown_worker(worker_task)
        lang = job.language || "en"
        WorkerStatus.append(job_id, "runtime", "final",
          Dmhai.I18n.t("job_cancelled_by_user", lang), "BLOCKED")
        {:poller_done, job_id, {:cancelled, nil}}

      %{job_status: "paused"} ->
        safe_shutdown_worker(worker_task)
        {:poller_done, job_id, {:paused, nil}}

      job ->
        new_rows = WorkerStatus.fetch_since(job_id, last_cursor)
        new_cursor = case new_rows do
          [] -> last_cursor
          rows -> rows |> List.last() |> Map.get(:id)
        end

        if new_cursor != last_cursor do
          Jobs.advance_cursor(job_id, new_cursor)
          broadcast_progress(job, new_rows)
        end

        final = Enum.find(new_rows, fn r -> r.kind == "final" end)

        # Unsolicited progress summary: run when enough new rows OR enough time has passed.
        maybe_announce_progress(job)

        cond do
          final && final.signal_status == "JOB_RESTART" ->
            {:poller_done, job_id, {:restart, final.content || "exec error restart"}}

          final ->
            finalize_job(job, final)
            {:poller_done, job_id, {:final, final.signal_status, final.content}}

          worker_dead?(worker_task) ->
            # Worker exited without a final row yet — peek ONE more time in case
            # the final row landed while we were deciding.
            case WorkerStatus.fetch_since(job_id, last_cursor) do
              rows when rows != [] ->
                case Enum.find(rows, fn r -> r.kind == "final" end) do
                  nil ->
                    lang = job.language || "en"
                    reason = Dmhai.I18n.t("worker_exited_no_signal", lang)
                    WorkerStatus.append(job_id, job.current_worker_id || "runtime", "final", reason, "BLOCKED")
                    Jobs.mark_blocked(job_id, reason)
                    emit_final_message(job, "BLOCKED", reason)
                    {:poller_done, job_id, {:final, "BLOCKED", reason}}

                  final_row ->
                    finalize_job(job, final_row)
                    {:poller_done, job_id, {:final, final_row.signal_status, final_row.content}}
                end

              _ ->
                lang = job.language || "en"
                reason = Dmhai.I18n.t("worker_exited_no_signal", lang)
                WorkerStatus.append(job_id, job.current_worker_id || "runtime", "final", reason, "BLOCKED")
                Jobs.mark_blocked(job_id, reason)
                emit_final_message(job, "BLOCKED", reason)
                {:poller_done, job_id, {:final, "BLOCKED", reason}}
            end

          true ->
            interval_ms = poll_interval_ms(job)
            Process.sleep(interval_ms)
            poller_loop(job_id, worker_task, new_cursor)
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

  defp poll_interval_ms(%{job_type: "periodic", intvl_sec: intvl}) when is_integer(intvl) and intvl > 0 do
    k = AgentSettings.job_poll_min_interval_sec()
    m = AgentSettings.job_poll_samples_per_cycle()
    ms = max(k, div(intvl, max(m, 1))) * 1_000
    apply_override(ms)
  end

  defp poll_interval_ms(_job) do
    ms = AgentSettings.job_poll_min_interval_sec() * 1_000
    apply_override(ms)
  end

  # Test-only override: when :job_poll_override_ms is set in the env, it forces
  # the poll interval to exactly that value (bypassing K settings). Production
  # runs leave this unset and use the K/M calculation above.
  defp apply_override(default_ms) do
    case Application.get_env(:dmhai, :job_poll_override_ms) do
      nil        -> default_ms
      override   -> override
    end
  end

  defp finalize_job(job, %{signal_status: "JOB_DONE", content: content}) do
    Jobs.mark_done(job.job_id, content || "")
    emit_final_message(job, "JOB_DONE", content || "")
  end

  # Handles both model-called JOB_BLOCKED and runtime-synthesized BLOCKED.
  defp finalize_job(job, %{signal_status: status, content: content})
       when status in ["JOB_BLOCKED", "BLOCKED"] do
    do_summarize_and_announce(job.job_id, true)
    Jobs.mark_blocked(job.job_id, content || "(no reason)")
    emit_final_message(job, "BLOCKED", content || "(no reason)")
  end

  defp finalize_job(job, _), do: Jobs.mark_blocked(job.job_id, "Final row with unknown status.")

  # Broadcast progress rows to the session (visible as subtle chunks in the UI).
  # For now we emit a single "step" per batch; frontend can render as spinner text.
  defp broadcast_progress(_job, []), do: :ok
  defp broadcast_progress(_job, _rows), do: :ok

  # ── progress summarizer (delta-only) ─────────────────────────────────────

  # Poller-driven: fire a summary when enough new rows have accumulated AND
  # enough time has passed since the last summary. Both thresholds must be
  # crossed to avoid spamming the user on bursty jobs.
  defp maybe_announce_progress(job) do
    min_cycle = AgentSettings.job_progress_summary_min_cycle_sec()

    if job.job_type == "periodic" and is_integer(job.intvl_sec) and job.intvl_sec < min_cycle do
      :ok
    else
      n_threshold = AgentSettings.job_progress_summary_every_n_rows()
      t_threshold_ms = AgentSettings.job_progress_summary_min_interval_sec() * 1_000
      now = System.os_time(:millisecond)

      new_row_count =
        WorkerStatus.fetch_since(job.job_id, job.last_summarized_status_id || 0)
        |> Enum.count(fn r -> r.kind != "progress_summary" end)

      last_at = job.last_summarized_at || 0
      elapsed_ms = now - last_at

      if new_row_count >= n_threshold and elapsed_ms >= t_threshold_ms do
        do_summarize_and_announce(job.job_id, false)
      else
        :ok
      end
    end
  end

  defp do_summarize_and_announce(job_id, force) do
    case Jobs.get(job_id) do
      nil -> {:error, :job_not_found}
      job ->
        cursor = job.last_summarized_status_id || 0
        all_rows = WorkerStatus.fetch_since(job.job_id, cursor)
        # Don't let summary rows become input to the next summary.
        new_rows = Enum.reject(all_rows, fn r -> r.kind == "progress_summary" end)

        cond do
          new_rows == [] and not force ->
            :ok

          new_rows == [] and force ->
            lang = job.language || "en"
            text = Dmhai.I18n.t("no_new_activity", lang, %{title: job.job_title})
            append_progress_to_session(job, text)
            {:ok, text}

          true ->
            case call_summarizer(job, new_rows) do
              {:ok, text} when is_binary(text) and text != "" ->
                max_id = new_rows |> List.last() |> Map.get(:id)
                WorkerStatus.append(job.job_id, job.current_worker_id || "runtime",
                  "progress_summary", text)
                append_progress_to_session(job, text)
                Jobs.advance_summary_cursor(job.job_id, max_id)
                {:ok, text}

              {:ok, other} ->
                Logger.warning("[JobRuntime] summarizer returned non-text job=#{job.job_id}: #{inspect(other)}")
                {:error, :non_text_summary}

              {:error, reason} ->
                Logger.warning("[JobRuntime] summarizer failed job=#{job.job_id}: #{inspect(reason)}")
                {:error, reason}
            end
        end
    end
  end

  defp call_summarizer(job, rows) do
    flat = Enum.map_join(rows, "\n", fn r ->
      "[#{r.kind}] #{String.slice(r.content || "", 0, 400)}"
    end)

    lang = job.language || "en"

    prompt = [
      %{role: "user", content:
        "You are the progress reporter for a background job. " <>
        "Job title: \"#{job.job_title}\". Job spec: \"#{String.slice(job.job_spec, 0, 400)}\".\n\n" <>
        "Below is the activity log since the last update. " <>
        "Write a status update in EXACTLY this format: \"<title>: <detail>\"\n" <>
        "  - <title>: 2–6 words, noun phrase describing the current action (e.g. \"Downloading report\", \"Running analysis\")\n" <>
        "  - <detail>: 1–2 sentences max, describing ONLY what the log slice shows. No speculation, no prior activity.\n" <>
        "Output ONLY the single line — no explanation, no bullet, no markdown.\n\n" <>
        "IMPORTANT: write the update in the user's language, ISO 639-1 code \"#{lang}\". " <>
        "Do not use any other language.\n\n" <>
        "Activity:\n#{flat}"}
    ]

    LLM.call(AgentSettings.summarizer_model(), prompt)
  end

  defp append_progress_to_session(job, text) do
    lang = job.language || "en"
    notify = Dmhai.I18n.t("notify_progress", lang, %{title: job.job_title})
    MasterBuffer.append_progress_notification(job.session_id, job.user_id, text, String.slice(notify, 0, 200))
  end

  defp emit_final_message(job, "JOB_DONE", result) do
    lang = job.language || "en"
    body = "**#{job.job_title}**\n\n#{result}"
    append_assistant_message(job.session_id, job.user_id, body, %{"job_id" => job.job_id})
    notify = Dmhai.I18n.t("notify_done", lang, %{title: job.job_title})
    MasterBuffer.append_notification(job.session_id, job.user_id, String.slice(notify, 0, 200))
    Dmhai.MsgGateway.notify(job.user_id, notify)
  end

  defp emit_final_message(job, "BLOCKED", reason) do
    lang = job.language || "en"
    blocked_label = Dmhai.I18n.t("blocked_label", lang, %{reason: reason})
    body =
      "<span style=\"color:#ef4444;font-weight:600\">🔴 #{job.job_title}:</span>\n\n#{blocked_label}"
    append_assistant_message(job.session_id, job.user_id, body, %{"job_id" => job.job_id})
    notify = Dmhai.I18n.t("notify_blocked", lang, %{title: job.job_title})
    MasterBuffer.append_notification(job.session_id, job.user_id, String.slice(notify, 0, 200))
    Dmhai.MsgGateway.notify(job.user_id, notify)
  end

  defp append_assistant_message(session_id, user_id, content, extra) do
    msg = Map.merge(%{
      role: "assistant",
      content: content,
      ts: System.os_time(:millisecond)
    }, extra)
    Dmhai.Agent.UserAgentMessages.append(session_id, user_id, msg)
  end

  # If this was a periodic job and still not cancelled, schedule the next run.
  defp handle_poller_outcome(job_id, {:restart, reason}, record, state) do
    restart_count = Map.get(record, :restart_count, 0)
    max_restarts  = AgentSettings.max_worker_restarts()

    if restart_count >= max_restarts do
      Logger.error("[JobRuntime] max restarts (#{max_restarts}) reached — blocking job=#{job_id}")
      case Jobs.get(job_id) do
        nil -> state
        job ->
          msg = "Worker could not recover after #{max_restarts} restart(s). Permanently blocked."
          WorkerStatus.append(job_id, "runtime", "final", msg, "BLOCKED")
          Jobs.mark_blocked(job_id, msg)
          emit_final_message(job, "BLOCKED", msg)
          state
      end
    else
      Logger.warning("[JobRuntime] restarting worker attempt=#{restart_count + 1}/#{max_restarts} job=#{job_id}: #{reason}")
      new_state = do_start_job(job_id, state, false)
      update_in(new_state.jobs, fn jobs ->
        case Map.get(jobs, job_id) do
          nil -> jobs
          r   -> Map.put(jobs, job_id, Map.put(r, :restart_count, restart_count + 1))
        end
      end)
    end
  end

  defp handle_poller_outcome(_job_id, {:paused, _}, _record, state), do: state

  defp handle_poller_outcome(job_id, outcome, _record, state) do
    maybe_reschedule_next_run(job_id, outcome, state)
  end

  defp maybe_reschedule_next_run(job_id, _outcome, state) do
    case Jobs.get(job_id) do
      %{job_type: "periodic", intvl_sec: intvl, job_status: status}
          when status not in ["cancelled", "paused"] and is_integer(intvl) and intvl > 0 ->
        next_at = System.os_time(:millisecond) + intvl * 1_000
        Jobs.schedule_next_run(job_id, next_at)

        # Start a timer so the next run fires locally without needing a tick.
        ref = Process.send_after(self(), {:run_scheduled, job_id}, intvl * 1_000)
        %{state | reschedule_timers: Map.put(state.reschedule_timers, job_id, ref)}

      _ ->
        state
    end
  end

  defp do_cancel_job(job_id, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        # No in-flight worker — also cancel any pending periodic reschedule.
        case Map.get(state.reschedule_timers, job_id) do
          nil -> state
          ref ->
            Process.cancel_timer(ref)
            %{state | reschedule_timers: Map.delete(state.reschedule_timers, job_id)}
        end

      %{worker_task: wt, poller_task: pt} ->
        safe_shutdown_worker(wt)
        safe_shutdown_poller(pt)
        %{state | jobs: Map.delete(state.jobs, job_id)}
    end
  end

  # Same as do_cancel_job but without marking DB — caller marks paused separately.
  # Also cancels any pending reschedule timer so periodic jobs don't re-fire while paused.
  defp do_pause_job(job_id, state) do
    state =
      case Map.get(state.reschedule_timers, job_id) do
        nil -> state
        ref ->
          Process.cancel_timer(ref)
          %{state | reschedule_timers: Map.delete(state.reschedule_timers, job_id)}
      end

    case Map.get(state.jobs, job_id) do
      nil -> state
      %{worker_task: wt, poller_task: pt} ->
        safe_shutdown_worker(wt)
        safe_shutdown_poller(pt)
        %{state | jobs: Map.delete(state.jobs, job_id)}
    end
  end

  # Boot rehydration: kill orphans, spawn due periodics.
  defp do_rehydrate(state) do
    # 1. Orphans: jobs marked 'running' in DB with no in-memory worker → blocked.
    Jobs.fetch_orphaned()
    |> Enum.each(fn job ->
      if not Map.has_key?(state.jobs, job.job_id) do
        lang = job.language || "en"
        reason = Dmhai.I18n.t("worker_orphaned", lang)
        WorkerStatus.append(job.job_id, job.current_worker_id || "runtime", "final", reason, "BLOCKED")
        Jobs.mark_blocked(job.job_id, reason)
        emit_final_message(job, "BLOCKED", reason)
      end
    end)

    # 2. Periodic jobs whose next_run_at is in the past → start now.
    Enum.reduce(Jobs.fetch_due_periodic(), state, fn job, acc ->
      do_start_job(job.job_id, acc)
    end)
  end

  defp gen_worker_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
