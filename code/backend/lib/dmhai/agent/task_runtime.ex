# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.TaskRuntime do
  @moduledoc """
  Periodic-pickup scheduler. That's it.

  Task execution is inline in the user's session turn — there is no
  Loop process, no poller, no completion watchdog. The only thing
  that needs to live between turns is a timer that tells the session
  to wake up when a periodic task's `time_to_pickup` arrives.

  Responsibilities:
    - `schedule_pickup(task_id, when_ms)` — arm a timer. Called by
      `Tasks.mark_done/2` after rescheduling a periodic task.
    - `cancel_pickup(task_id)` — called by `Tasks.mark_cancelled/1` and
      `Tasks.mark_paused/1` so a pickup doesn't fire after the user
      changes the task state.
    - On timer fire: ensure the user's session GenServer is started,
      then `send(session_pid, {:task_due, task_id})`. The session's next
      turn sees the pickup in its task list and acts.
    - Boot rehydration: revert `task_status="ongoing"` to `"pending"`
      (the turn that was running when the BEAM died didn't complete;
      the assistant will resume via the task list). Re-arm pickups for
      all `pending` periodic tasks with non-null `time_to_pickup`.

  Implementation: a single named GenServer keyed by `@name`, state =
  `%{timers: %{task_id => ref}}`.

  The `summarize_and_announce/2` on-demand summariser is co-located here
  because it's driven by the assistant when the user asks "how's task X
  going?" — it reads `session_progress` rows since the task's last
  summary cursor and writes a `kind='summary'` row. No scheduling.
  """

  use GenServer
  require Logger

  alias Dmhai.Agent.{AgentSettings, LLM, SessionProgress, Tasks}

  @name __MODULE__
  @summarizer_locks :task_summarizer_locks

  # ─── Client API ──────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @doc "Arm a timer that fires `{:task_due, task_id}` to the user's session at `when_ms`."
  def schedule_pickup(task_id, when_ms) when is_binary(task_id) and is_integer(when_ms) do
    GenServer.cast(@name, {:schedule_pickup, task_id, when_ms})
  end

  @doc "Cancel any armed timer for this task (called on cancel/pause)."
  def cancel_pickup(task_id) when is_binary(task_id) do
    GenServer.cast(@name, {:cancel_pickup, task_id})
  end

  @doc "Boot rehydration. Called at app startup after the supervisor tree is up."
  def rehydrate do
    GenServer.cast(@name, :rehydrate)
  end

  @doc """
  On-demand progress summariser. The assistant calls this (via a tool or
  direct reply helper) when the user asks for a status check. Reads
  session_progress rows since the last summary, calls an LLM to compile
  a one-liner, writes the summary as a `kind='summary'` row.

  `force: true`  — always respond, even if nothing new.
  `force: false` — no-op when no new rows.
  """
  @spec summarize_and_announce(String.t(), keyword()) ::
          :ok | {:ok, String.t()} | {:error, term()} | {:skipped, String.t()}
  def summarize_and_announce(task_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

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
            _              -> "en"
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
    :ets.new(@summarizer_locks, [:set, :public, :named_table])

    if Application.get_env(:dmhai, :enable_task_rehydrate, true) do
      Process.send_after(self(), :rehydrate, 500)
    end
    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_cast({:schedule_pickup, task_id, when_ms}, state) do
    state = cancel_timer(state, task_id)
    delay = max(when_ms - System.os_time(:millisecond), 0)
    ref = Process.send_after(self(), {:pickup_due, task_id}, delay)
    {:noreply, %{state | timers: Map.put(state.timers, task_id, ref)}}
  end

  def handle_cast({:cancel_pickup, task_id}, state) do
    {:noreply, cancel_timer(state, task_id)}
  end

  def handle_cast(:rehydrate, state) do
    {:noreply, do_rehydrate(state)}
  end

  @impl true
  def handle_info({:pickup_due, task_id}, state) do
    state = %{state | timers: Map.delete(state.timers, task_id)}

    case Tasks.get(task_id) do
      nil ->
        Logger.info("[TaskRuntime] pickup_due for missing task=#{task_id}")
        {:noreply, state}

      %{task_status: status, user_id: user_id, session_id: session_id, task_type: task_type}
          when status == "pending" ->
        # Don't stack periodic pickups. If another periodic in this
        # session is already `ongoing` (prior cycle mid-chain, hasn't
        # closed), skip THIS firing entirely. The missed cycle is NOT
        # made up for — the next natural timer re-fires after
        # intvl_sec. Prevents overlapping periodic silent chains that
        # compound model confusion and amplify Police rejections.
        # See architecture.md §Scheduler — don't stack periodic pickups.
        if task_type == "periodic" and Tasks.session_has_ongoing_periodic?(session_id) do
          Logger.info("[TaskRuntime] pickup_due task=#{task_id} skipped — another periodic is already ongoing in session=#{session_id}")
          {:noreply, state}
        else
          deliver_pickup(user_id, session_id, task_id)
          {:noreply, state}
        end

      %{task_status: status} ->
        Logger.info("[TaskRuntime] pickup_due task=#{task_id} status=#{status} — not pending, skip")
        {:noreply, state}
    end
  end

  def handle_info(:rehydrate, state) do
    {:noreply, do_rehydrate(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # ─── Private ─────────────────────────────────────────────────────────────

  defp cancel_timer(state, task_id) do
    case Map.get(state.timers, task_id) do
      nil -> state
      ref ->
        Process.cancel_timer(ref)
        %{state | timers: Map.delete(state.timers, task_id)}
    end
  end

  # Ensure the user's agent GenServer is started, then poke it with
  # {:task_due, task_id}. The session turn will pick it up next.
  defp deliver_pickup(user_id, _session_id, task_id) do
    case Dmhai.Agent.Supervisor.ensure_started(user_id) do
      {:ok, pid} ->
        send(pid, {:task_due, task_id})
        :ok

      {:error, reason} ->
        Logger.error("[TaskRuntime] failed to start UserAgent for pickup user=#{user_id} reason=#{inspect(reason)}")
        :error
    end
  end

  defp do_rehydrate(state) do
    # 1. PERIODIC ongoing tasks → pending. Their `ongoing` state is
    #    tied to a running cycle; if the BEAM died mid-cycle, the
    #    cycle is lost and the task must be re-armed to fire again.
    #    One_off tasks' `ongoing` state is NOT touched — a multi-chain
    #    one_off can legitimately stay `ongoing` across restarts
    #    (awaiting user clarification between chains). If its chain
    #    was killed mid-work, the boot scan detects the orphan via
    #    `has_unanswered_user_msg?` and dispatches a resume chain;
    #    the `ongoing` status is correct for the continuation.
    Tasks.fetch_orphaned_ongoing_periodic()
    |> Enum.each(fn task ->
      Logger.info("[TaskRuntime] reverting orphaned ongoing periodic task=#{task.task_id} → pending")
      Tasks.mark_pending(task.task_id)
    end)

    # 2. Re-arm pickup timers for pending periodic tasks.
    Enum.reduce(Tasks.fetch_pending_periodic(), state, fn task, acc ->
      case task.time_to_pickup do
        nil -> acc
        when_ms ->
          delay = max(when_ms - System.os_time(:millisecond), 0)
          ref = Process.send_after(self(), {:pickup_due, task.task_id}, delay)
          %{acc | timers: Map.put(acc.timers, task.task_id, ref)}
      end
    end)
  end

  # ─── Summariser (on-demand only) ─────────────────────────────────────────

  defp do_summarize_and_announce(task_id, force) do
    case Tasks.get(task_id) do
      nil  -> {:error, :task_not_found}
      task ->
        all_rows = SessionProgress.fetch_for_task(task.task_id)
        new_rows = Enum.reject(all_rows, fn r -> r.kind == "summary" end)

        cond do
          new_rows == [] and not force ->
            :ok

          new_rows == [] and force ->
            lang = task.language || "en"
            text = Dmhai.I18n.t("no_new_activity", lang, %{title: task.task_title})
            SessionProgress.append_summary(task_ctx(task), text)
            {:ok, text}

          true ->
            case call_summarizer(task, new_rows) do
              {:ok, text} when is_binary(text) and text != "" ->
                SessionProgress.append_summary(task_ctx(task), text)
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
      "[#{r.kind}] #{String.slice(r.label || "", 0, 400)}"
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

  defp task_ctx(task) do
    %{
      session_id: task.session_id,
      user_id:    task.user_id,
      task_id:    task.task_id
    }
  end
end
