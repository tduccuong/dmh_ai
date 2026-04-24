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
    # current inline task: nil | {task_ref, task_pid, reply_pid, session_id}
    # - task_pid is the running Task's process. It is never force-killed;
    #   the Phase 2 mid-chain design lets the user redirect the assistant
    #   by sending a new message, which is spliced into the current chain
    #   on the next LLM roundtrip. See architecture.md §Mid-chain user
    #   message injection.
    # - session_id is retained so on turn completion we can check
    #   `UserAgentMessages.has_unanswered_user_msg?` (auto-resume a chain
    #   for queued user messages) and `Tasks.fetch_next_due/1` (auto-chain
    #   the next pending task).
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
    # Boot rehydration of periodic tasks is delegated to
    # `Dmhai.Agent.TaskRuntime` at app startup.
    #
    # Phase 2 orphan-recovery: self-send `:boot_scan` so that any user
    # messages persisted to `session.messages` but never answered —
    # because the prior GenServer crashed or idle-timed-out while work
    # was queued — are picked up as soon as this instance is alive.
    # Deferred via send so `init/1` returns promptly; the scan runs
    # inside the normal mailbox loop. See architecture.md §Boot scan
    # for orphan recovery.
    send(self(), :boot_scan)
    {:ok, %__MODULE__{user_id: user_id}, @idle_timeout}
  end

  # Assistant path — strictly separated from Confidant. Requires a loaded
  # session in "assistant" mode; mismatched mode is a handler bug and gets
  # refused here as a safety net.
  @impl true
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
  # On completion, in order:
  #   1. If this session has a user message in `session.messages` with
  #      `ts` strictly greater than the chain's watermark (the max
  #      user-ts the chain's LLM calls actually saw), auto-resume with
  #      a fresh Assistant turn — the new turn's context build
  #      naturally includes the queued message. The watermark-based
  #      check is tight: it correctly catches the race where a user
  #      message lands AFTER the final LLM roundtrip started (so the
  #      assistant's reply's ts > user's ts, but the LLM never saw the
  #      user msg). See architecture.md §Mid-chain user message
  #      injection.
  #   2. Otherwise, check `Tasks.fetch_next_due/1` — if a pending task in
  #      this session has `time_to_pickup <= now`, self-send
  #      `{:task_due, task_id}` for a silent periodic pickup.
  #
  # `result` shape:
  #   * `{:chain_done, watermark_ts}` — Assistant session_chain_loop
  #   * anything else — Confidant path / legacy; fall back to
  #     `has_unanswered_user_msg?` (last-entry check) which is
  #     sufficient because Confidant has no mid-chain semantics.
  @impl true
  def handle_info({ref, result}, %{current_task: {ref, _task_pid, _reply_pid, session_id}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current_task: nil}

    has_newer_user_msg? =
      case result do
        {:chain_done, watermark_ts} when is_integer(watermark_ts) ->
          Dmhai.Agent.UserAgentMessages.user_msgs_since(session_id, watermark_ts) != []

        _ ->
          Dmhai.Agent.UserAgentMessages.has_unanswered_user_msg?(session_id)
      end

    cond do
      has_newer_user_msg? ->
        send(self(), {:auto_resume_assistant, session_id})
        {:noreply, state, @idle_timeout}

      true ->
        maybe_trigger_next_due(session_id)
        {:noreply, state, @idle_timeout}
    end
  end

  # Stray {ref, _result} from tasks we no longer track — swallow.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state, @idle_timeout}
  end

  # Inline task crashed. Before clearing state, also check the user-msg
  # queue so a crash mid-chain doesn't strand queued follow-ups.
  def handle_info({:DOWN, ref, :task, _pid, reason}, %{current_task: {ref, _task_pid, reply_pid, session_id}} = state) do
    Logger.error("[UserAgent] inline task crashed user=#{state.user_id} reason=#{inspect(reason)}")
    send(reply_pid, {:error, "Internal error — please try again"})
    state = %{state | current_task: nil}

    if Dmhai.Agent.UserAgentMessages.has_unanswered_user_msg?(session_id) do
      send(self(), {:auto_resume_assistant, session_id})
    end

    {:noreply, state, @idle_timeout}
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

  # Phase 2 auto-resume: after a chain finished while the DB shows an
  # unanswered user message for this session, synthesise a minimal
  # AssistantCommand and run the pipeline. The new turn's context build
  # includes the queued message naturally (it's already in session.messages).
  # If the agent is busy when this message is drained (e.g. the previous
  # auto-resume is still running), the chain-complete hook will re-fire
  # a new auto_resume_assistant on the next completion, so no re-queue is
  # needed here.
  def handle_info({:auto_resume_assistant, session_id}, %{current_task: nil} = state) do
    dummy_pid = spawn(fn -> :ok end)

    command = %AssistantCommand{
      type:             :chat,
      content:          "",
      session_id:       session_id,
      reply_pid:        dummy_pid,
      attachment_names: [],
      files:            [],
      metadata:         %{auto_resume: true}
    }

    Dmhai.SysLog.log("[ASSISTANT:resume] user=#{state.user_id} session=#{session_id}")

    dispatch_run(command, state, fn session_data ->
      run_assistant(command, state, session_data)
    end, required_mode: "assistant")
  end

  def handle_info({:auto_resume_assistant, _session_id}, state) do
    # Busy — silent drop. When the current turn completes its chain-
    # complete hook will re-check `has_unanswered_user_msg?` and fire
    # another :auto_resume_assistant at that time.
    {:noreply, state, @idle_timeout}
  end

  # Phase 2 boot scan: find Assistant-mode sessions for this user where
  # the last persisted message is role="user" and self-dispatch an
  # auto-resume for each. Restores responsiveness after GenServer crash
  # or idle-timeout + respawn. See architecture.md §Boot scan for
  # orphan recovery.
  def handle_info(:boot_scan, state) do
    case Dmhai.Agent.UserAgentMessages.sessions_with_unanswered_user_msg(state.user_id) do
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

  # Idle timeout — shut down cleanly.
  # Defensive re-check: in the narrow window where a new user message is
  # persisted right as we're about to time out, trigger one more
  # auto-resume before stopping. The boot scan on the next spawn
  # guarantees we still pick it up, but resuming in-place avoids the
  # spawn round-trip.
  def handle_info(:timeout, state) do
    case Dmhai.Agent.UserAgentMessages.sessions_with_unanswered_user_msg(state.user_id) do
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
    {:via, Registry, {Dmhai.Agent.Registry, user_id}}
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
    {:noreply,
     %{state | current_task: {spawned.ref, spawned.pid, dummy_pid, session_id}},
     @idle_timeout}
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
        files:        [],
        # Phase 3: forward the silent-pickup target so the anchor block
        # names this task explicitly (even though no runtime lookup
        # would otherwise pick a periodic task over other candidates).
        silent_turn_task_id: task.task_id
      )

    # Append synthetic "task due" instruction as the last user-role turn
    # so the model knows what to act on. Not persisted — it's an internal
    # prompt, not user input. The model's final assistant text IS persisted
    # via append_session_message below.
    #
    # Two instructions land hard here because they're the exact compliance
    # failures we saw with nemotron-3-nano:30b-cloud on periodic tasks:
    #
    #   1. "This is a PICKUP of the EXISTING task `<id>` — use
    #      complete_task, not create_task." Catches the nemotron failure
    #      mode where each pickup spawned a fresh periodic row, one of
    #      the causes of the exponential-amplification bug (Police gate
    #      6 now also rejects the runtime side).
    #
    #   2. "Your final text IS the task output. No 'Joke delivered:',
    #      'Task complete', or similar meta-prefix." Catches the nemotron
    #      habit of producing a real reply PLUS a bookkeeping-style line,
    #      both persisted, cluttering the session timeline.
    task_num = Map.get(task, :task_num)

    synthetic = %{role: "user",
                  content:
                    "[Task due: (#{task_num}) — #{task.task_title}]\n\n" <>
                    "This is a PICKUP of the EXISTING periodic task (#{task_num}). " <>
                    "The runtime has already flipped it to `ongoing` for you — " <>
                    "you do NOT need to call `pickup_task`. (Calling it is a harmless " <>
                    "no-op; skipping it is preferred to save a turn.)\n\n" <>
                    "STAY IN LANE — a silent pickup is scoped to THIS ONE TASK. " <>
                    "Even if the user asked about a different task in an earlier " <>
                    "conversational turn, do NOT act on that here. The user will " <>
                    "re-ask on their next message; wait for it. Forbidden this turn: " <>
                    "`create_task` (any type), `pickup_task` / `complete_task` / " <>
                    "`pause_task` / `cancel_task` on ANY task_num other than " <>
                    "#{task_num}, and cancelling (#{task_num}) itself to " <>
                    "free the periodic slot.\n\n" <>
                    "Workflow:\n" <>
                    "  1. Run whatever execution tools you need (web_fetch, run_script, etc.) " <>
                    "to produce this cycle's fresh output.\n" <>
                    "  2. Call `complete_task(task_num: #{task_num}, " <>
                    "task_result: \"<short summary>\")` — this auto-reschedules the next cycle.\n" <>
                    "  3. Your final text IS the task output (the joke, the quote, the status — " <>
                    "whatever this task produces). Write it directly in the user's language. " <>
                    "NO meta-prefix like \"Joke delivered:\", \"Task complete\", \"Here is your...\", " <>
                    "\"Your update:\". The user just wants the content."}

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
      log_trace:     AgentSettings.log_trace(),
      # Snapshot the initial message count so the duplicate-tool-call
      # police check only sees the within-chain accumulator, never history.
      chain_start_idx: length(llm_messages),
      # Silent-turn scope marker — drives Police gate #9. A scheduler
      # pickup fires for ONE specific task; the model must not use the
      # trigger as an opportunity to create new tasks, cancel the
      # triggered task to start a different one, or touch other tasks'
      # state. Seen in the wild: the model interpreted a joke-task
      # pickup as permission to cancel it, create an ASCII-drawing
      # task, and deliver 3 drawings — all in a single silent turn,
      # because the user had asked for ASCII in a prior turn. Police
      # rule #9 reads this ctx key to enforce the one-task-per-silent-
      # turn invariant.
      silent_turn_task_id: task.task_id,
      # Phase 3: silent-turn anchor starts at the triggered task's
      # task_num and can flip via back_to_when_done when the model
      # completes/cancels/pauses the pickup inside the chain. See
      # architecture.md §Anchor mutation via back_to_when_done.
      anchor_task_num: Map.get(task, :task_num),
      last_rendered_anchor_task_num: Map.get(task, :task_num),
      role:          "assistant",
      model:         model
    }

    Dmhai.SysLog.log("[ASSISTANT:auto] user=#{user_id} session=#{session_id} task=#{task.task_id} title=#{String.slice(task.task_title || "", 0, 60)}")

    # Flip the task to 'ongoing' at pickup start — the silent-turn
    # entry point acts as an implicit `pickup_task` for the triggered
    # row (the model doesn't need to re-pickup a task whose pickup this
    # turn *is*). This closes the cadence-correctness gap for periodic
    # pickups: without it, a silent turn starts with the task in
    # 'pending' (that's how the previous pickup's mark_done left it)
    # and relies on the model calling `complete_task(...)` to advance
    # it. If the model skips that (nemotron-3-nano frequently did),
    # `auto_close_ongoing_tasks` at end of the text turn filters for
    # status=="ongoing" and finds nothing → `mark_done` never fires →
    # `time_to_pickup` stays in the past → `maybe_trigger_next_due`
    # re-dispatches {:task_due} immediately → burst fire until the
    # model eventually complies. Marking ongoing here guarantees
    # auto_close will catch the pickup's completion and reschedule for
    # the next intvl_sec window regardless of model behaviour.
    Tasks.mark_ongoing(task.task_id)

    result = session_chain_loop(llm_messages, model, ctx, 0)

    Task.start(fn -> maybe_compact(session_id, user_id) end)

    # Same watermark plumbing as `run_assistant/3` — returned to the
    # chain-complete hook so a silent pickup that landed at the same
    # time as a user message still auto-resumes for the user.
    result
  end

  # Phase 2 mid-chain splice: return `messages` with any newly-arrived
  # user messages appended. "Newly arrived" = rows in `session.messages`
  # whose role="user" and whose `ts` is greater than the greatest `ts`
  # of any user-role entry already present in `messages`. Entries
  # without a `ts` (synthetic `[Task due:]` injections, Police nudges
  # injected as role=user) don't count toward the floor — they have no
  # DB representation, and we don't want them to block a genuine DB
  # message from being spliced in. See architecture.md §Mid-chain user
  # message injection.
  defp splice_mid_chain_user_msgs(messages, %{session_id: session_id}) do
    floor_ts = max_user_ts_in_messages(messages)

    case Dmhai.Agent.UserAgentMessages.user_msgs_since(session_id, floor_ts) do
      [] ->
        messages

      new_msgs ->
        Dmhai.SysLog.log("[ASSISTANT] mid-chain splice: #{length(new_msgs)} new user msg(s) since ts=#{floor_ts}")
        messages ++ Enum.map(new_msgs, &normalize_spliced_msg/1)
    end
  end

  # Max `ts` of any user-role message in a message list. Used both as
  # the splice-floor in `splice_mid_chain_user_msgs` and as the chain
  # watermark returned with `{:chain_done, ts}`. Entries without a `ts`
  # (synthetic injections — Police nudges, `[Task due: ...]` markers)
  # are ignored.
  defp max_user_ts_in_messages(messages) do
    messages
    |> Enum.reduce(0, fn m, acc ->
      role = m[:role] || m["role"]
      ts   = m[:ts]   || m["ts"]

      if role == "user" and is_integer(ts) and ts > acc, do: ts, else: acc
    end)
  end

  # DB rows are stored with string keys; `session_chain_loop` accepts
  # both atom- and string-keyed maps, so pass through as-is.
  defp normalize_spliced_msg(m), do: m

  # Phase 3: refresh the prompt's `## Active task` block mid-chain when
  # the runtime anchor has moved. Appends a synthetic user/assistant
  # pair to `messages` naming the current anchor (or a "none / free
  # mode" notice when the anchor has gone nil). Updates ctx's
  # `last_rendered_anchor_task_num` so subsequent iterations don't
  # re-append the same refresh. No-op when the rendered value already
  # matches the runtime value.
  defp maybe_refresh_anchor_block(messages, ctx) do
    current = Map.get(ctx, :anchor_task_num)
    last    = Map.get(ctx, :last_rendered_anchor_task_num)

    if current == last do
      {messages, ctx}
    else
      refresh = render_anchor_refresh_block(current)
      Dmhai.SysLog.log("[ASSISTANT] anchor refresh (#{inspect(last)}) → (#{inspect(current)}) — injecting prompt block")
      {messages ++ refresh,
       Map.put(ctx, :last_rendered_anchor_task_num, current)}
    end
  end

  # Mid-chain anchor refresh blocks. USER-ONLY (no trailing
  # `assistant: Understood.` stub) — because a refresh sits at the END
  # of `messages` and is followed IMMEDIATELY by the next
  # `LLM.stream` call; ending on `assistant` would violate Ollama's
  # "last role must be User or Tool" contract and break the whole
  # account pool.
  #
  # Refresh only fires on IMPLICIT anchor transitions (back-reference
  # pops from complete/cancel/pause of the current anchor) — explicit
  # `pickup_task(N)` calls advance `last_rendered_anchor_task_num` in
  # lock-step so no refresh is injected for those (model already
  # knows the anchor moved; runtime restating it just invites
  # exploratory `fetch_task` calls).
  #
  # Wording is deliberately minimal — no "Call fetch_task" hint, no
  # open-ended "whichever is appropriate" option. The model should
  # finish the task cleanly or emit text, not probe.
  defp render_anchor_refresh_block(nil) do
    body =
      "## Active task — UPDATED\n\n" <>
        "- Current task: none (free mode).\n" <>
        "- The chain's pickup task is closed and no back-reference " <>
        "remains. **Emit your final user-facing text and end the " <>
        "chain.** No more tool calls."

    [%{role: "user", content: body}]
  end

  defp render_anchor_refresh_block(n) when is_integer(n) do
    body =
      "## Active task — UPDATED\n\n" <>
        "- Current task: (#{n}).\n" <>
        "- The previous task in this chain is closed; focus has " <>
        "returned to (#{n}) via its back-reference. Continue the " <>
        "work or emit your final text."

    [%{role: "user", content: body}]
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

    cond do
      state.current_task && required_mode == "assistant" ->
        # Phase 2 queuing: the user message is already persisted to
        # `session.messages` by the HTTP handler. The in-flight chain's
        # `session_chain_loop` will splice it into the next LLM roundtrip
        # (mid-chain), or the chain-complete hook will auto-resume if
        # the chain finishes before the LLM call picks it up. Either
        # way, the FE gets a 202-like ack here. See architecture.md
        # §Mid-chain user message injection.
        send(reply_pid, {:error, :queued})
        {:reply, {:error, :queued}, state, @idle_timeout}

      state.current_task ->
        # Confidant still uses a synchronous busy reject (its one-shot
        # streaming contract has no chain to fold messages into).
        send(reply_pid, {:error, :busy})
        {:reply, {:error, :busy}, state, @idle_timeout}

      true ->
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

        {:reply, :ok,
         %{state | current_task: {task.ref, task.pid, reply_pid, command.session_id}},
         @idle_timeout}
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

    # Snapshot the set of `📎 [newly attached]` paths injected by
    # ContextEngine into the current chain's latest user message.
    # Police's check_fresh_attachments_read/2 uses this at the text
    # turn (chain end) to enforce that each fresh attachment was
    # actually extract_content'd during this chain.
    fresh_attachment_paths = Dmhai.Agent.Police.extract_fresh_attachment_paths(llm_messages)

    # Phase 3: resolve the active-task anchor at chain start. CAN mutate
    # during the chain via `maybe_mutate_anchor/4` inside `execute_tools`
    # — pickup_task pushes the prior anchor as the picked-up task's
    # `back_to_when_done_task_num`; complete/cancel/pause of the current
    # anchor flips back to that stored back-reference. Drives persisted-
    # message tagging AND gets refreshed into the prompt's `## Active task`
    # block at the next turn boundary. See architecture.md §Anchor
    # mutation via back_to_when_done back-stack.
    anchor = Dmhai.Agent.Anchor.resolve(session_id)
    anchor_task_num = anchor && anchor.task_num

    ctx = %{
      user_id:       user_id,
      user_email:    email,
      session_id:    session_id,
      session_root:  Dmhai.Constants.session_root(email, session_id),
      data_dir:      data_dir,
      workspace_dir: workspace_dir,
      log_trace:     AgentSettings.log_trace(),
      fresh_attachment_paths: fresh_attachment_paths,
      # Snapshot the initial message count so the duplicate-tool-call
      # police check can slice `messages[chain_start_idx..]` and see only
      # the in-chain accumulator — never cross-chain repeats.
      chain_start_idx: length(llm_messages),
      anchor_task_num: anchor_task_num,
      # Phase 3: track the anchor value most recently rendered into the
      # prompt's `## Active task` block. Starts equal to the chain-start
      # anchor (ContextEngine already emitted that block). When
      # `anchor_task_num` diverges — because a pickup/complete/cancel/
      # pause inside this chain mutated it — `session_chain_loop`
      # appends a refresh block before the NEXT LLM call and syncs
      # this field. Prevents the "stale prompt vs mutated runtime"
      # incoherence observed in the joke→docker stress test.
      last_rendered_anchor_task_num: anchor_task_num,
      # Model-behaviour telemetry inputs — every Police rejection bumps a
      # counter row for this (role, model, issue_type, tool_name).
      role:          "assistant",
      model:         model
    }

    Dmhai.SysLog.log("[ASSISTANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)} fresh_attachments=#{inspect(fresh_attachment_paths)} anchor=#{inspect(anchor_task_num)}")

    result = session_chain_loop(llm_messages, model, ctx, 0)

    Task.start(fn ->
      maybe_compact(session_id, user_id)
      ProfileExtractor.extract_and_merge(command.content, nil, user_id)
    end)

    # Return value is captured by Task's `{ref, result}` message to the
    # GenServer — used by the chain-complete hook to decide auto-resume.
    # See architecture.md §Mid-chain user message injection.
    result
  end

  # Chain loop — one Assistant chain, composed of turns (LLM roundtrips)
  # until the assistant emits user-facing text.
  #
  # Terminology (see architecture.md §Assistant Mode):
  #   * **turn**  = one LLM call + the tool execution it triggers
  #   * **chain** = sequence of turns until the assistant emits
  #     user-facing text (ending the chain)
  #   * **task**  = persistent objective spanning many chains
  #
  # On each turn: if the model emits tool calls, execute them (persisting
  # progress rows as side effects), append their results, and recurse
  # into the next turn. If the model emits text, append it to
  # session.messages — the FE picks it up on its next poll — and the
  # chain is done.
  #
  # Returns `{:chain_done, watermark_ts}` from every terminal branch.
  # `watermark_ts` is the max user-ts in the final messages list the
  # chain worked with — i.e. the highest user-message ts the chain's
  # LLM calls actually saw. The GenServer's chain-complete hook uses
  # it against DB state to detect "a new user message arrived AFTER
  # the chain had finished consuming input" and needs an auto-resume.
  defp session_chain_loop(messages, model, ctx, turn) do
    max_turns = AgentSettings.max_assistant_turns_per_chain()

    # Phase 2 mid-chain splice: fold any user messages that were
    # persisted to `session.messages` after this chain started (or after
    # the previous turn's LLM call returned) into the working messages
    # list, so the next turn's LLM call sees them as context. Splice
    # point is SAFE here — we're between turns, so any prior tool_call /
    # tool_result pair has already been paired up; OpenAI's sequencing
    # rule isn't violated.
    messages = splice_mid_chain_user_msgs(messages, ctx)

    # Phase 3 anchor refresh: if the runtime anchor has moved from
    # what the prompt currently says (because a pickup / complete /
    # cancel / pause in a prior turn of THIS chain mutated it), append
    # a refreshed `## Active task` block so the next LLM call sees the
    # updated value. Keeps prompt-side anchor coherent with the
    # runtime ctx. See architecture.md §Anchor mutation.
    {messages, ctx} = maybe_refresh_anchor_block(messages, ctx)

    if turn >= max_turns do
      msg = Dmhai.I18n.t("turn_cap_reached", "en", %{max: max_turns})
      cap_msg = maybe_tag_task_num(%{role: "assistant", content: msg}, ctx)
      {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, cap_msg)
      {:chain_done, max_user_ts_in_messages(messages)}
    else
      tools = Dmhai.Tools.Registry.all_definitions()

      trace = %{
        origin: "assistant",
        path: "UserAgent.session_chain",
        role: "AssistantSession",
        phase: "turn#{turn}"
      }

      on_tokens = fn rx, tx -> TokenTracker.add_master(ctx.session_id, ctx.user_id, rx, tx) end

      # Use LLM.stream for every turn. For tool-call turns the collector
      # stays empty (the model emits tool_calls, not content tokens) —
      # harmless, buffer is cleared before the next turn. For the FINAL
      # (text) turn, tokens flow into sessions.stream_buffer in real time
      # so the FE polling loop renders the answer progressively as it's
      # generated, same UX as Confidant mode.
      collector = spawn_stream_collector(ctx.session_id, ctx.user_id)
      # `num_predict` is a ceiling (no prepaid cost). Without it,
      # Ollama's default caps long tool_call generation — bash
      # scripts get truncated mid-string and the model loops
      # retrying the same malformed call. See AgentSettings
      # §llm_num_predict_assistant.
      llm_options = %{num_predict: AgentSettings.llm_num_predict_assistant()}
      result = LLM.stream(model, messages, collector,
                          tools: tools, options: llm_options,
                          on_tokens: on_tokens, trace: trace)
      stop_stream_collector(collector)

      case result do
        {:ok, {:tool_calls, calls}} ->
          call_names = Enum.map_join(calls, ", ", fn c -> get_in(c, ["function", "name"]) || "?" end)
          Dmhai.SysLog.log("[ASSISTANT] turn=#{turn} tool_calls=[#{call_names}]")

          # Capture any narration the model streamed before emitting
          # tool_calls ("Let me search for that first…"). Previously we
          # cleared `stream_buffer` unconditionally and discarded the
          # text, which caused the "half-rendered reasoning, rest renders
          # after tool finishes" visual glitch: FE saw partial text in
          # stream_buffer, then the clear wiped it, then the NEXT turn's
          # fresh narration filled the buffer and the FE perceived it as
          # a continuation. Persisting the narration as a real assistant
          # message (with sanitisation matching the final-text path)
          # makes it a permanent part of the chat timeline and removes
          # the flash. Sanitise, log, persist if non-empty, then clear.
          raw_narration  = StreamBuffer.read(ctx.session_id, ctx.user_id)
          clean_narration = Dmhai.Agent.TextSanitizer.strip_task_bookkeeping(raw_narration)
          StreamBuffer.clear(ctx.session_id, ctx.user_id)

          if String.trim(clean_narration) != "" do
            Dmhai.SysLog.log("[ASSISTANT] turn=#{turn} narration(#{String.length(clean_narration)} chars) persisted")

            narration_msg = %{role: "assistant", content: clean_narration}
            narration_msg = maybe_tag_task_num(narration_msg, ctx)

            {:ok, _} =
              append_session_message(ctx.session_id, ctx.user_id, narration_msg)
          end

          # In-memory assistant_msg carries the narration in its `content`
          # so subsequent LLM calls in this chain see the model's own
          # reasoning alongside its tool_calls — without it the LLM
          # would lose track of why it picked a particular tool.
          assistant_msg = %{role: "assistant", content: clean_narration, tool_calls: calls}
          {tool_result_msgs_raw, ctx} = execute_tools(calls, messages, ctx)

          # Tally any tagged Police rejections from this turn and bump
          # the matching nudge counters. Returns the cleaned messages
          # with the internal `[[ISSUE:...]]` marker stripped so the
          # model just sees the nudge prose.
          {ctx, tool_result_msgs} = bump_nudge_counters(ctx, tool_result_msgs_raw)

          case maybe_abort_on_model_behavior_issue(ctx, model) do
            :continue ->
              new_messages = messages ++ [assistant_msg] ++ tool_result_msgs
              session_chain_loop(new_messages, model, ctx, turn + 1)

            :aborted ->
              {:chain_done, max_user_ts_in_messages(messages)}
          end

        {:ok, text} when is_binary(text) and text != "" ->
          case Dmhai.Agent.Police.check_assistant_text(text) do
            {:rejected, tagged_or_reason} ->
              # Model emitted what meant to be a tool call as plain text,
              # OR leaked tool-call bookkeeping into user-facing content.
              # Unpack the tagged tuple when present; fall back to plain
              # string for backwards compatibility.
              {issue_atom, reason} =
                case tagged_or_reason do
                  {atom, text_reason} when is_atom(atom) -> {atom, text_reason}
                  plain when is_binary(plain)            -> {:assistant_text, plain}
                end

              Dmhai.SysLog.log("[ASSISTANT] turn=#{turn} rejected text='#{String.slice(text, 0, 80)}' — nudging for retry")
              StreamBuffer.clear(ctx.session_id, ctx.user_id)

              # Record telemetry + bump nudge counter for this non-tool issue.
              ctx = record_non_tool_issue(ctx, issue_atom)

              new_messages =
                messages ++ [
                  %{role: "assistant", content: text},
                  %{role: "user",      content: reason}
                ]

              case maybe_abort_on_model_behavior_issue(ctx, model) do
                :continue -> session_chain_loop(new_messages, model, ctx, turn + 1)
                :aborted  -> {:chain_done, max_user_ts_in_messages(messages)}
              end

            :ok ->
              # Before accepting the final text, enforce that every
              # `📎 [newly attached]` path in the current turn's user
              # message was passed to `extract_content` at some point
              # during this turn. Catches the "model acknowledges the
              # attachment in prose but never actually reads it" failure.
              fresh_paths = Map.get(ctx, :fresh_attachment_paths, [])

              case Dmhai.Agent.Police.check_fresh_attachments_read(fresh_paths, messages) do
                {:rejected, tagged_or_reason} ->
                  {issue_atom, reason} =
                    case tagged_or_reason do
                      {atom, r} when is_atom(atom) -> {atom, r}
                      plain when is_binary(plain)  -> {:fresh_attachments_unread, plain}
                    end

                  Dmhai.SysLog.log("[ASSISTANT] turn=#{turn} rejected fresh-attachment-miss — nudging for retry")
                  StreamBuffer.clear(ctx.session_id, ctx.user_id)
                  ctx = record_non_tool_issue(ctx, issue_atom)

                  new_messages =
                    messages ++ [
                      %{role: "assistant", content: text},
                      %{role: "user",      content: reason}
                    ]

                  case maybe_abort_on_model_behavior_issue(ctx, model) do
                    :continue -> session_chain_loop(new_messages, model, ctx, turn + 1)
                    :aborted  -> {:chain_done, max_user_ts_in_messages(messages)}
                  end

                :ok ->
                  # Strip tool-call bookkeeping annotations the model may
                  # have tacked on to its answer ("[used: complete_task(…)]",
                  # "[via: web_search]", etc.). Police already rejected
                  # flagrant cases at stream-end; this is the belt-and-
                  # braces strip for anything that slipped through.
                  clean_text = Dmhai.Agent.TextSanitizer.strip_task_bookkeeping(text)
                  if clean_text != text do
                    Logger.info("[UserAgent] stripped task-bookkeeping (#{String.length(text) - String.length(clean_text)} chars) from assistant text at persistence")
                  end
                  Dmhai.SysLog.log("[ASSISTANT] turn=#{turn} text(#{String.length(clean_text)} chars)")
                  final_msg = maybe_tag_task_num(%{role: "assistant", content: clean_text}, ctx)
                  {:ok, assistant_ts} =
                    append_session_message(ctx.session_id, ctx.user_id, final_msg)
                  # Stream buffer had the progressive text; clear it now that
                  # the permanent message is persisted, so the FE's streaming
                  # placeholder gives way to the real message on next poll.
                  StreamBuffer.clear(ctx.session_id, ctx.user_id)
                  # Snapshot this chain's tool_call/tool_result messages
                  # into the session's rolling tool-history window so the
                  # NEXT chain's context builder can inject them back and
                  # answer immediate follow-ups without re-running tools.
                  # Passes the anchor's `task_num` so entries rolling out
                  # of retention get archived per-task (Phase 3).
                  #
                  # IMPORTANT: slice by `chain_start_idx` FIRST. `messages`
                  # at this point contains (a) the tool_history re-injected
                  # from prior chains by `ContextEngine.build_assistant_messages`
                  # PLUS (b) this chain's own new tool_calls. Without the
                  # slice, `collect_tool_messages` would capture (a) too,
                  # and subsequent save_turn entries would accumulate
                  # prior-chain history — causing messages to appear
                  # duplicated in future context builds (entry 1 and the
                  # bloated entry 2 would both re-inject the same
                  # chain-1 tool_calls, splitting across two assistant_ts
                  # anchors). The slice ensures one chain's entry contains
                  # only THAT chain's work. `chain_start_idx` is the
                  # length of `llm_messages` captured when `run_assistant`
                  # (or `run_assistant_silent`) entered the loop — so
                  # everything after index is what this chain produced.
                  tool_msgs =
                    messages
                    |> Enum.drop(ctx.chain_start_idx)
                    |> collect_tool_messages()

                  Dmhai.Agent.ToolHistory.save_turn(
                    ctx.session_id, ctx.user_id, assistant_ts, tool_msgs,
                    Map.get(ctx, :anchor_task_num))
                  # Runtime auto-close: if the model worked on any task this
                  # turn but forgot to call `complete_task`, close them
                  # now using the final answer as task_result. Keeps the
                  # task list clean without relying on model compliance.
                  auto_close_ongoing_tasks(ctx.session_id, clean_text)

                  {:chain_done, max_user_ts_in_messages(messages)}
              end
          end

        {:ok, ""} ->
          Dmhai.SysLog.log("[ASSISTANT] turn=#{turn} empty response — no message persisted")
          StreamBuffer.clear(ctx.session_id, ctx.user_id)
          {:chain_done, max_user_ts_in_messages(messages)}

        {:error, reason} ->
          Dmhai.SysLog.log("[ASSISTANT] turn=#{turn} ERROR: #{inspect(reason)}")
          StreamBuffer.clear(ctx.session_id, ctx.user_id)

          # Phase 3: classify the error. Transient infra issues (API-key
          # exhaustion, rate-limits, provider 5xx, timeouts) are treated
          # as a SYSTEM-ERROR class — we auto-pause the active task so
          # the user's work is preserved, and surface a localised,
          # non-jargon message asking them to ping us when resolved.
          # Everything else falls back to the generic `llm_error`
          # render.
          err_msg_payload =
            case classify_llm_error(reason) do
              {:system_error, cause_key} ->
                build_system_error_reply(ctx, cause_key)

              :generic ->
                %{role: "assistant",
                  content: Dmhai.I18n.t("llm_error", "en", %{reason: inspect(reason)})}
            end

          err_msg = maybe_tag_task_num(err_msg_payload, ctx)
          {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, err_msg)
          {:chain_done, max_user_ts_in_messages(messages)}
      end
    end
  end

  # Decide whether an LLM-error reason is a SYSTEM-class failure
  # (transient infra we can't self-recover from — user needs to fix
  # something upstream) vs. a generic error (surface as-is). Returns
  # `{:system_error, i18n_cause_key}` or `:generic`. The cause_key
  # drives the humanised phrase inserted into the user-facing message.
  # See architecture.md §Error handling + `Dmhai.I18n` keys starting
  # with `system_error_cause_*`.
  @system_error_keys_exhausted_markers ["all_keys_exhausted", "exhausted", "quota"]
  @system_error_rate_limit_markers     ["rate_limit", "rate limit", "429"]
  @system_error_server_markers         ["server_error", "HTTP 5", "bad_gateway", "service_unavailable"]
  @system_error_timeout_markers        ["timeout", "timed out", "econnrefused", "connection reset", "closed"]

  defp classify_llm_error(reason) do
    text = error_reason_to_string(reason)

    cond do
      Enum.any?(@system_error_keys_exhausted_markers, &String.contains?(text, &1)) ->
        {:system_error, "system_error_cause_keys_exhausted"}

      Enum.any?(@system_error_rate_limit_markers, &String.contains?(text, &1)) ->
        {:system_error, "system_error_cause_rate_limited"}

      Enum.any?(@system_error_server_markers, &String.contains?(text, &1)) ->
        {:system_error, "system_error_cause_server_error"}

      Enum.any?(@system_error_timeout_markers, &String.contains?(text, &1)) ->
        {:system_error, "system_error_cause_timeout"}

      true ->
        :generic
    end
  end

  defp error_reason_to_string(r) when is_atom(r),   do: Atom.to_string(r)
  defp error_reason_to_string(r) when is_binary(r), do: r
  defp error_reason_to_string(r),                    do: inspect(r)

  # Produce the assistant reply for a system-error classified chain:
  # auto-pause the active task (if any) so the user's work survives,
  # then render the localised "pausing — let me know when resolved"
  # message. If no active task, emit the no-task variant.
  defp build_system_error_reply(ctx, cause_key) do
    lang = resolve_user_language(ctx)
    reason_phrase = Dmhai.I18n.t(cause_key, lang)

    case Map.get(ctx, :anchor_task_num) do
      n when is_integer(n) ->
        auto_pause_active_task(ctx, n)

        content = Dmhai.I18n.t("system_error_paused", lang, %{
          reason: reason_phrase, task_num: n})

        %{role: "assistant", content: content}

      _ ->
        content = Dmhai.I18n.t("system_error_no_active_task", lang, %{
          reason: reason_phrase})

        %{role: "assistant", content: content}
    end
  end

  # Look up the task_num → task_id and flip it to 'paused'. Uses
  # Tasks.mark_paused directly instead of emulating the verb tool
  # because the model is NOT in the loop — the LLM call failed
  # upstream of any tool-call. Guarded to paused-eligible states
  # (mirrors pause_task tool's own precondition).
  defp auto_pause_active_task(ctx, task_num) do
    with {:ok, task_id} <- Tasks.resolve_num(ctx.session_id, task_num),
         %{task_status: status} = _task when status in ["ongoing", "pending"] <-
           Tasks.get(task_id) do
      Tasks.mark_paused(task_id)
      Dmhai.SysLog.log("[ASSISTANT] auto-paused task (#{task_num}) due to system error")
      :ok
    else
      _ -> :ok
    end
  end

  # Best-effort user language detection: read the anchor task's
  # `language` field (set at create_task time from the user's message).
  # Falls back to 'en' when no anchor or no stored language.
  defp resolve_user_language(ctx) do
    case Map.get(ctx, :anchor_task_num) do
      n when is_integer(n) ->
        case Tasks.lookup_by_num(ctx.session_id, n) do
          %{language: lang} when is_binary(lang) and lang != "" -> lang
          _ -> "en"
        end

      _ ->
        "en"
    end
  end

  # Phase 3: tag an assistant message with the chain's anchor `task_num`
  # when one is set. Called at every `append_session_message` site in
  # `session_chain_loop` so archived slices can be partitioned per-task
  # by `ContextEngine.compact!`. Free-mode chains (no anchor) leave the
  # message untagged — they'll compact into the master session summary
  # like any pure-chat exchange. See architecture.md §Per-message task tag.
  defp maybe_tag_task_num(message, ctx) do
    case Map.get(ctx, :anchor_task_num) do
      n when is_integer(n) -> Map.put(message, :task_num, n)
      _                     -> message
    end
  end

  # Sweep any tasks still in `ongoing` for this session and mark them done
  # with the assistant's final text as the task_result. Called at the end
  # of a successful text turn (chain end) — catches the case where the
  # model did the work but forgot to call `complete_task` before emitting
  # its answer. Matches the "less reliance on model" philosophy already
  # applied to periodic re-arm: routine bookkeeping handled by the
  # runtime, not the model. Periodic tasks re-schedule themselves via
  # Tasks.mark_done/2's built-in branch.
  # Filter the in-chain message accumulator down to the tool_call-emitting
  # assistant messages AND their paired tool-result messages. These form
  # one retained chain entry in ToolHistory. User messages and the final
  # assistant text are omitted — they're already in session.messages.
  defp collect_tool_messages(messages) do
    Enum.filter(messages, fn m ->
      role         = m[:role] || m["role"]
      tool_calls   = m[:tool_calls] || m["tool_calls"] || []
      tool_call_id = m[:tool_call_id] || m["tool_call_id"]

      cond do
        role == "assistant" and is_list(tool_calls) and tool_calls != [] -> true
        role == "tool"      and is_binary(tool_call_id) and tool_call_id != "" -> true
        true -> false
      end
    end)
  end

  # Escalation threshold — the model gets this many chances to fix a
  # tagged Police misbehavior within a single turn before we give up
  # and surface an internal-error message to the user.
  @model_behavior_nudge_limit 3

  # Sniff tool_result messages for `[[ISSUE:<atom>:<tool_name>]]` markers
  # left by execute_tools/2: bump the matching counter in ctx.nudges,
  # record a telemetry row, AND strip the marker from the message content
  # so the model only sees the human-readable nudge prose.
  defp bump_nudge_counters(ctx, tool_result_msgs) do
    existing = Map.get(ctx, :nudges, %{})
    marker_re = ~r/^\[\[ISSUE:([a-z_]+):([^\]]*)\]\]\n?/u

    role  = Map.get(ctx, :role, "assistant")
    model = Map.get(ctx, :model, "unknown")

    {nudges_after, clean_msgs} =
      Enum.map_reduce(tool_result_msgs, existing, fn msg, acc ->
        raw = msg[:content] || msg["content"] || ""

        case Regex.run(marker_re, raw) do
          [full, atom_name, tool_name] ->
            key = String.to_atom(atom_name)
            new_acc = Map.update(acc, key, 1, &(&1 + 1))
            Dmhai.Agent.ModelBehaviorStats.record(role, model, atom_name, tool_name)
            cleaned = String.replace_prefix(raw, full, "")
            {Map.put(msg, :content, cleaned), new_acc}

          _ ->
            {msg, acc}
        end
      end)
      |> then(fn {msgs, acc} -> {acc, msgs} end)

    {Map.put(ctx, :nudges, nudges_after), clean_msgs}
  end

  # Non-tool-call Police rejections (check_assistant_text,
  # check_fresh_attachments_read) don't flow through execute_tools, so they
  # can't use the marker-in-content trick. This helper does the equivalent
  # counter bump + telemetry record inline in the text-turn handler.
  defp record_non_tool_issue(ctx, issue_atom) do
    role  = Map.get(ctx, :role, "assistant")
    model = Map.get(ctx, :model, "unknown")

    Dmhai.Agent.ModelBehaviorStats.record(role, model, Atom.to_string(issue_atom), "")

    nudges =
      ctx
      |> Map.get(:nudges, %{})
      |> Map.update(issue_atom, 1, &(&1 + 1))

    Map.put(ctx, :nudges, nudges)
  end

  # Check every counter against the limit. If any has reached it,
  # emit the user-facing error, log a critical ModelBehaviorIssue,
  # and return :aborted so the turn loop stops.
  defp maybe_abort_on_model_behavior_issue(ctx, model) do
    nudges = Map.get(ctx, :nudges, %{})

    over =
      Enum.find(nudges, fn {_k, count} -> count >= @model_behavior_nudge_limit end)

    case over do
      nil ->
        :continue

      {issue, count} ->
        role = Map.get(ctx, :role, "assistant")
        Logger.error(
          "[ModelBehaviorIssue] type=#{issue} model=#{model} session=#{ctx.session_id} count=#{count} — " <>
            "model exceeded nudge budget; aborting turn"
        )
        Dmhai.SysLog.log(
          "[CRITICAL] ModelBehaviorIssue type=#{issue} model=#{model} " <>
            "session=#{ctx.session_id} count=#{count}"
        )
        # Record the escalation as its own telemetry row ('escalated_<issue>')
        # so the admin UI can see how often each rule trips the 3-strike limit.
        Dmhai.Agent.ModelBehaviorStats.record(
          role, model, "escalated_#{issue}", "")

        user_msg = "Internal AI model error — we're investigating and working to fix. " <>
                     "Sorry for the inconvenience."
        StreamBuffer.clear(ctx.session_id, ctx.user_id)
        {:ok, _} = append_session_message(ctx.session_id, ctx.user_id,
                                          %{role: "assistant", content: user_msg})
        :aborted
    end
  end

  # Auto-close runs at end of text turn (chain end). PERIODIC-ONLY now —
  # one_off tasks stay `ongoing` across chains until the model explicitly
  # calls `complete_task`, which is the only reliable signal that the
  # objective is done. Was previously indiscriminate and closed
  # multi-turn one_off conversations prematurely (e.g. user asks
  # "ssh in and set up nextcloud", assistant needs to ask a clarifying
  # question, ends turn with text — old auto_close would mark the task
  # done, next turn's user answer couldn't attach to it).
  #
  # For periodic tasks, auto-close is still the right thing: the
  # pickup's "done" = "reschedule next cycle", a structural event the
  # runtime owns. `Tasks.mark_done/2` dispatches periodic → pending +
  # `time_to_pickup = now + intvl_sec` + `TaskRuntime.schedule_pickup`.
  # If the model forgot `complete_task`, the cadence still holds.
  defp auto_close_ongoing_tasks(session_id, assistant_text) do
    # Cap the task_result snippet — don't dump an entire multi-kilobyte
    # answer into every ongoing task row. First ~500 chars is enough
    # audit context; the full answer lives in session.messages.
    snippet = String.slice(assistant_text || "", 0, 500)

    session_id
    |> Tasks.active_for_session()
    |> Enum.filter(&(&1.task_status == "ongoing" and &1.task_type == "periodic"))
    |> Enum.each(fn t ->
      Dmhai.SysLog.log("[ASSISTANT] auto-closing PERIODIC pickup task=#{t.task_id} — model did not call complete_task; runtime reschedules")
      Tasks.mark_done(t.task_id, snippet)
    end)
  end

  # Execute each tool call: Police-gate first (task-discipline check —
  # rejects execution-class tool calls when no active task exists for the
  # session, so the model is forced to call create_task first), then write
  # a pending session_progress row, run the tool via ToolRegistry, flip
  # the row to done. Returns the tool_result messages for the LLM's next
  # turn.
  #
  # `messages` is the current LLM call input — the Police duplicate-call
  # check slices `messages[chain_start_idx..]` to scope its view to this
  # chain's accumulator only. Within a single batch of calls (one LLM
  # response with multiple tool_calls) we also dedupe by appending a
  # synthetic assistant message per iteration so later calls see earlier
  # ones.
  defp execute_tools(calls, messages, ctx) do
    chain_start_idx = Map.get(ctx, :chain_start_idx, 0)
    in_chain_prior  = Enum.drop(messages, chain_start_idx)

    {results, {_final_prior, final_ctx}} =
      Enum.map_reduce(calls, {in_chain_prior, ctx}, fn call, {prior_acc, ctx} ->
        name         = get_in(call, ["function", "name"]) || ""
        args         = get_in(call, ["function", "arguments"]) || %{}
        tool_call_id = call["id"] || ""

        # Task-verb side effect: when any verb (pickup_task / complete_task /
        # pause_task / cancel_task) fires with task_id, that id becomes the
        # active one for subsequent progress rows. We infer it below from
        # the args when present.
        progress_ctx = %{
          session_id: ctx.session_id,
          user_id:    ctx.user_id,
          task_id:    args["task_id"]
        }

        tool_msg =
          # Police gate 1 — tool-name validity. Rejects garbled blobs /
          # hallucinated names before we ever log or dispatch. Silent to the
          # user (no progress row). Model reads the error on its next turn
          # and retries with a clean name. See §Police::Tool-name validity.
          with :ok <- Dmhai.Agent.Police.check_tool_known(name),
               # Police gate 2 — task discipline. Silent to the user. Same
               # self-correction pattern.
               :ok <- Dmhai.Agent.Police.check_task_discipline(name, ctx, prior_acc),
               # Police gate 3 — tool-call schema compliance. Generic check
               # against the tool's own definition (required fields + types).
               # Schema-driven nudge example returned on failure.
               :ok <- Dmhai.Agent.Police.check_tool_call_schema(name, args),
               # Police gate 4 — within-chain duplicate-tool-call. Blocks
               # the "create_task twice with same title" / "extract_content
               # the same PDF twice" misbehaviour we saw on gemini-3-flash.
               :ok <- Dmhai.Agent.Police.check_no_duplicate_tool_call(name, args, prior_acc),
               # Police gate 5 — no two `web_search` calls in a row. A single
               # web_search already fans out 2-3 parallel queries in the BE,
               # so back-to-back web_searches are redundant. Catches the
               # "model spams web_search with slightly reworded queries
               # instead of digesting the first result" failure mode. The
               # nudge TEACHES the correct loop: digest → dig with a
               # different tool → re-search only if a genuine gap remains.
               :ok <- Dmhai.Agent.Police.check_no_consecutive_web_search(name, args, prior_acc),
               # Police gate 6 — one periodic task per session. Rejects
               # create_task(task_type: "periodic") when the session
               # already has an active periodic. Catches the failure
               # mode where a model spawns multiple periodics for one
               # user ask, each firing on its own timer → exponential
               # amplification of silent turns (observed with
               # nemotron-3-nano:30b-cloud: 4 periodic tasks for a
               # single "joke every 30 sec" ask). The nudge is
               # user-facing: it tells the model exactly what to reply
               # so the user sees a coherent explanation naming the
               # existing task's (N).
               :ok <- Dmhai.Agent.Police.check_no_duplicate_periodic_task_in_session(name, args, ctx),
               # Police gate 7 — silent-turn scope lock. During a
               # scheduler-triggered silent pickup (ctx carries
               # :silent_turn_task_id), forbid create_task and the
               # pickup/complete/pause/cancel verbs on any task OTHER
               # than the triggered one. Catches the "pickup hijack"
               # failure: model uses the pickup trigger to cancel the
               # triggered task, create a new periodic the user asked
               # about in a prior turn, and run multiple deliveries of
               # the new task — all in one silent turn (observed with
               # ministral-3:14b-cloud on 2026-04-24).
               :ok <- Dmhai.Agent.Police.check_silent_turn_scope(name, args, ctx) do
            progress_label = Dmhai.Agent.ProgressLabel.format(name, args)
            # `complete_task` is pure cleanup — the final assistant
            # message IS the completion event from the user's
            # perspective. Hide the row so it doesn't appear as noise
            # before the final answer renders. Other verbs (pickup /
            # pause / cancel) stay visible so the user sees state
            # transitions happen in the chat timeline.
            hide_row = name == "complete_task"
            {:ok, row} = Dmhai.Agent.SessionProgress.append(progress_ctx, "tool", progress_label,
                                                            status: "pending", hidden: hide_row)

            args_log = args |> Jason.encode!() |> String.slice(0, 600)
            Dmhai.SysLog.log("[ASSISTANT] tool=#{name} args=#{args_log}")
            # Thread the progress row id through ctx so tools with parallel
            # internals (web_search, OCR extract) can stream sub-activity
            # labels into session_progress.sub_labels for the FE to rotate.
            tool_ctx = Map.put(ctx, :progress_row_id, row.id)
            exec_result = Dmhai.Tools.Registry.execute(name, args, tool_ctx)

            # Flip to 'done' on BOTH success and error. A non-zero exit from
            # `run_script` (or any other tool error) is still a completed
            # tool invocation — the script ran, produced output, exited
            # with a code. Deleting the row was the pre-Phase-2 design
            # intended to hide failed attempts, but the FE never learns
            # about deletes (poll only returns rows with id > cursor), so
            # stale `status=pending` rows accumulated in the client's
            # local cache forever as stuck spinners. Keeping the row as
            # `done` preserves the audit trail AND lets the FE flip its
            # spinner off. The model still sees the `"Error: …"` string
            # as its tool_result and can correct on the next turn.
            content =
              case exec_result do
                {:ok, result} ->
                  Dmhai.Agent.SessionProgress.mark_tool_done(row.id)
                  format_tool_result(result)

                {:error, reason} ->
                  Dmhai.Agent.SessionProgress.mark_tool_done(row.id)
                  "Error: #{reason}"
              end

            %{role: "tool", content: content, tool_call_id: tool_call_id}
          else
            # Plain string rejection (legacy Police checks) — return as a
            # tool-result message, no issue tracking.
            {:rejected, reason} when is_binary(reason) ->
              %{role: "tool", content: reason, tool_call_id: tool_call_id}

            # Tagged rejection `{issue_atom, reason}` — emit a marker in the
            # message that the session loop can sniff later to bump the
            # matching counter in ctx.nudges AND record a telemetry row.
            # Marker format: `[[ISSUE:<atom>:<tool_name>]]` — tool_name
            # allows the stats row to be scoped per-tool.
            {:rejected, {issue_atom, reason}} when is_atom(issue_atom) ->
              marker = "[[ISSUE:#{issue_atom}:#{name}]]\n"
              %{role: "tool", content: marker <> reason, tool_call_id: tool_call_id}
          end

        # Append a synthetic assistant-role message for this call so later
        # calls in the SAME batch see it and dedupe against it. Rejected
        # calls also contribute — the model should not "double down" on a
        # rejected duplicate within the same round either.
        pseudo = %{"role" => "assistant", "tool_calls" => [call]}

        # Phase 3 anchor mutation — update ctx.anchor_task_num based on
        # the verb and its outcome. Also persists back_to_when_done on
        # pickup_task success. See architecture.md §Anchor mutation via
        # back_to_when_done back-stack.
        new_ctx = maybe_mutate_anchor(ctx, name, args, tool_msg)

        {tool_msg, {prior_acc ++ [pseudo], new_ctx}}
      end)

    {results, final_ctx}
  end

  # Apply anchor transitions based on tool verb + outcome. Only mutates
  # ctx on SUCCESSFUL task-verb calls; rejections and execution-tool
  # calls pass ctx through unchanged. See §Anchor mutation via
  # back_to_when_done back-stack.

  # `create_task` (Phase 3 lever 2b): the tool inserts with
  # `status='ongoing'` and we advance the anchor in lockstep —
  # functionally equivalent to what `pickup_task` does for an
  # existing task, but wrapped into the same LLM roundtrip. The
  # previous anchor becomes the new task's `back_to_when_done_task_num`
  # so complete/cancel/pause can pop back to it. `last_rendered_anchor`
  # is advanced too (EXPLICIT model-driven transition — no refresh
  # block needed; the model KNOWS it just created this task).
  defp maybe_mutate_anchor(ctx, "create_task", _args, %{content: content, role: "tool"}) do
    case extract_task_num_from_success(content) do
      nil ->
        ctx

      n ->
        prev = Map.get(ctx, :anchor_task_num)

        if is_integer(prev) and prev != n do
          case Tasks.resolve_num(ctx.session_id, n) do
            {:ok, task_id} ->
              Tasks.set_back_ref(task_id, prev)
              Dmhai.SysLog.log("[ASSISTANT] anchor_back_ref set on create task=(#{n}) ← was_anchor=(#{prev})")

            _ ->
              :ok
          end
        end

        Dmhai.SysLog.log("[ASSISTANT] anchor create+pickup: (#{inspect(prev)}) → (#{n})")
        ctx
        |> Map.put(:anchor_task_num, n)
        |> Map.put(:last_rendered_anchor_task_num, n)
    end
  end

  defp maybe_mutate_anchor(ctx, "pickup_task", args, %{content: content, role: "tool"}) do
    # Detect success by absence of the `[[ISSUE:...]]` Police marker AND
    # absence of the "Error:" prefix from tool errors. The tool's
    # payload is a JSON blob with `ok: true` on success.
    success? = is_binary(content) and String.contains?(content, "\"ok\": true")
    was_already_ongoing? = is_binary(content) and String.contains?(content, "was_already_ongoing")

    case {success?, coerce_task_num(args["task_num"])} do
      {true, n} when is_integer(n) ->
        prev = Map.get(ctx, :anchor_task_num)

        # Only write back-ref on a fresh transition to a different
        # task. Idempotent re-pickup (already ongoing) or pickup of
        # the current anchor: don't overwrite the stored back-ref —
        # we might clobber a valid earlier back-ref with a stale
        # current=N value.
        if not was_already_ongoing? and is_integer(prev) and prev != n do
          case Tasks.resolve_num(ctx.session_id, n) do
            {:ok, task_id} ->
              Tasks.set_back_ref(task_id, prev)
              Dmhai.SysLog.log("[ASSISTANT] anchor_back_ref set task=(#{n}) ← was_anchor=(#{prev})")

            {:error, :not_found} ->
              :ok
          end
        end

        Dmhai.SysLog.log("[ASSISTANT] anchor pickup: (#{inspect(prev)}) → (#{n})")
        # EXPLICIT transition: the model called pickup_task(N) itself,
        # so it already knows N is the new anchor — no refresh block
        # needed. Advance `last_rendered_anchor_task_num` to match
        # so `maybe_refresh_anchor_block/2` sees no divergence and
        # stays silent. Only IMPLICIT transitions (back-ref pops from
        # complete/cancel/pause) leave `last_rendered_anchor_task_num`
        # trailing so the refresh block fires.
        ctx
        |> Map.put(:anchor_task_num, n)
        |> Map.put(:last_rendered_anchor_task_num, n)

      _ ->
        ctx
    end
  end

  # complete_task / cancel_task / pause_task on the CURRENT anchor →
  # flip anchor to the stored back_to_when_done_task_num (may be nil
  # = free mode). If the verb targets some OTHER task_num, anchor
  # stays put — the model can close unrelated rows without disturbing
  # its current focus.
  defp maybe_mutate_anchor(ctx, verb, args, %{content: content, role: "tool"})
       when verb in ["complete_task", "cancel_task", "pause_task"] do
    success? = is_binary(content) and String.contains?(content, "\"ok\": true")
    current  = Map.get(ctx, :anchor_task_num)
    n        = coerce_task_num(args["task_num"])

    case {success?, current, n} do
      {true, c, n} when is_integer(c) and is_integer(n) and c == n ->
        # Closes / pauses the current anchor — flip to its back-ref.
        case Tasks.lookup_by_num(ctx.session_id, n) do
          %{back_to_when_done_task_num: back} ->
            Dmhai.SysLog.log("[ASSISTANT] anchor #{verb} on current: (#{n}) → back=(#{inspect(back)})")
            # Clear the back-ref on the closed task so a future
            # re-pickup starts clean.
            case Tasks.resolve_num(ctx.session_id, n) do
              {:ok, task_id} -> Tasks.set_back_ref(task_id, nil)
              _ -> :ok
            end
            Map.put(ctx, :anchor_task_num, back)

          _ ->
            Map.put(ctx, :anchor_task_num, nil)
        end

      _ ->
        ctx
    end
  end

  defp maybe_mutate_anchor(ctx, _name, _args, _tool_msg), do: ctx

  defp coerce_task_num(n) when is_integer(n), do: n
  defp coerce_task_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _        -> nil
    end
  end
  defp coerce_task_num(_), do: nil

  # `create_task` returns its newly-allocated `task_num` in the tool
  # result (rendered as a JSON blob in the `content` field). Parse
  # it out so `maybe_mutate_anchor` can advance the anchor. Returns
  # nil on parse failure / missing field — ctx stays unchanged then.
  defp extract_task_num_from_success(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"task_num" => n}} when is_integer(n) -> n
      _ -> nil
    end
  end
  defp extract_task_num_from_success(_), do: nil

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

  @doc false
  # Load session model + full session data (messages + context + mode) from DB.
  # Returns {:ok, model, %{"id" => ..., "messages" => [...], "context" => %{...}, "mode" => "confidant"|"assistant"}}
  #
  # The `"id"` field is REQUIRED by ContextEngine.build_assistant_messages/2
  # (needed to load tool_history for the Recently-extracted-files block and
  # tool_call/tool_result interleaving). Omitting it silently disables both
  # features — see the contract assertion in ContextEngine.
  #
  # Exposed as `def` (not `defp`) so the load-contract integration test can
  # exercise the EXACT production code path without manually constructing a
  # session_data map (the failure mode we hit when the id wiring broke).
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
