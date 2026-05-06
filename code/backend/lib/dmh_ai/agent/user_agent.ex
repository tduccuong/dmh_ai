# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent do
  @idle_timeout :timer.minutes(30)

  @moduledoc """
  Per-user agent (GenServer).

  Lifecycle
  ---------
  Started lazily by DmhAi.Agent.Supervisor.ensure_started/1 on first command.
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
                      A Task runs under DmhAi.Agent.TaskSupervisor, sends
                      {:chunk, text} / {:done, result} directly to reply_pid,
                      then exits. The GenServer monitors it and clears state on done.

  2. Assistant Loop — long/async tasks (the Assistant classifier calls
                      `create_task`; a fresh loop runs under
                      DmhAi.Agent.AssistantLoopSupervisor). The HTTP connection
                      is already closed (ack was sent). When the loop finishes
                      it writes a new assistant message and fires
                      MsgGateway.notify/2.
  """

  use GenServer
  require Logger

  alias DmhAi.Agent.{AgentSettings, AssistantCommand, ConfidantCommand, ContextEngine,
                     LLM, Swift, ProfileExtractor, StreamBuffer, ThinkingBuffer,
                     Supervisor, Tasks, TokenTracker}
  alias DmhAi.Web.Search, as: WebSearchEngine
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.Embedder
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # ─── State ────────────────────────────────────────────────────────────────

  defstruct [
    :user_id,
    # current inline task: nil | {task_ref, task_pid, reply_pid, session_id}
    # - task_pid is the running Task's process. It is never force-killed;
    #   the user redirects the assistant by sending a new message, which
    #   is spliced into the current chain on the next LLM roundtrip. See
    #   architecture.md §Mid-chain user message injection.
    # - session_id is retained so on turn completion we can check
    #   `UserAgentMessages.has_unanswered_user_msg?` (auto-resume a chain
    #   for queued user messages) and `Tasks.fetch_next_due/1` (auto-chain
    #   the next pending task).
    current_task: nil,
    # per-platform opaque state (e.g. %{telegram: %{chat_id: "123"}})
    platform_state: %{},
    # 32-byte raw MMK (master memo key). Set on login by Handlers.Auth
    # via `set_memo_key/2`; nil until then. Wiped on logout, idle
    # timeout, GenServer crash, server restart. See
    # specs/memo_encryption.md § MMK lifecycle.
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

  @doc "Cancel all active tasks for a specific session (called on session delete)."
  @spec cancel_session_tasks(String.t(), String.t()) :: :ok
  def cancel_session_tasks(_user_id, session_id) do
    session_id
    |> Tasks.active_for_session()
    |> Enum.each(fn task -> Tasks.mark_cancelled(task.task_id) end)
    :ok
  end

  @doc """
  Cancel the user's currently-running inline turn (Confidant or
  Assistant), if any. Returns:

    * `{:ok, :stopped}`         — a turn was running, it's now killed
                                  and `current_task` cleared. The
                                  session has a `chain_aborted`
                                  progress row marking the chain end.
    * `{:ok, :no_active_turn}`  — nothing was running; idempotent
                                  no-op.
    * `{:error, :not_started}`  — the user has no agent process yet
                                  (never sent a message).

  Idempotent under concurrency: a second cancel arriving while the
  first is still in flight finds `current_task = nil` and returns
  `:no_active_turn`. A natural task completion arriving as a
  `{ref, result}` or `:DOWN` after a cancel is harmless — its
  pattern doesn't match (current_task already nil) and falls
  through to the catch-all swallow.
  """
  @spec cancel_current_turn(String.t()) :: {:ok, :stopped | :no_active_turn} | {:error, term()}
  def cancel_current_turn(user_id) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, :cancel_current_turn)
      []         -> {:error, :not_started}
    end
  end

  @doc """
  Returns the session_id of the user's currently-running inline turn,
  or nil. Used by `/poll` to surface a per-session busy flag — the FE
  shows the Stop button only on the session that's actually in
  flight, not all of them.

  Returns nil if the user has no agent process yet (never sent a
  message). Read-only; doesn't start the agent.
  """
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

  @doc "Store platform-specific state (e.g. Telegram chat_id) in the agent."
  @spec set_platform_state(String.t(), atom(), map()) :: :ok
  def set_platform_state(user_id, platform, state) when is_atom(platform) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.cast(pid, {:set_platform_state, platform, state})
      [] -> :ok
    end
  end

  @doc "Read platform-specific state. Returns nil if agent not running."
  @spec get_platform_state(String.t(), atom()) :: map() | nil
  def get_platform_state(user_id, platform) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.call(pid, {:get_platform_state, platform})
      [] -> nil
    end
  end

  @doc """
  Read the user's MMK. Lazy: on cache miss, queries
  `users.memo_wrapped_mmk` and unwraps with the deployment master
  key. Caches the result for the lifetime of the GenServer. On a
  fresh GenServer (post-restart, post-idle), the next call repeats
  the lookup transparently — memo access survives across logout,
  login, and BE restart.

  Returns `nil` when the user has no wrapped MMK row (never saved a
  memo), the wrap is the legacy V1 (login migration handles it), or
  unwrap fails (logs a warning — operationally rare; usually means
  the master key file changed).

  See specs/memo_encryption.md § Read path.
  """
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

  @doc """
  Generate a fresh MMK for a user with no existing wrap, persist
  it (wrapped under the master key), and install it in the agent's
  state. Idempotent: if the user already has a V2 wrap, the existing
  MMK is returned. Called from the write path on first save when
  `get_memo_key` returns nil.

  Returns `{:ok, mmk}` or `{:error, reason}`.
  """
  @spec ensure_memo_key(String.t()) :: {:ok, binary()} | {:error, term()}
  def ensure_memo_key(user_id) when is_binary(user_id) do
    with {:ok, pid} <- Supervisor.ensure_started(user_id) do
      try do
        GenServer.call(pid, :ensure_memo_key, 5_000)
      catch
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc """
  Drop the in-memory MMK cache. Called only by **admin password
  reset** — the underlying DB wrap is being destroyed there too, so
  the in-memory cached MMK would otherwise still be used by in-flight
  or scheduled work and produce ciphertext that's unreadable on next
  read (the DB wrap is gone). Dropping the cache forces the next
  memo activity to go through `ensure_memo_key` and generate a
  fresh wrap.

  NOT called by logout — per spec, memos remain accessible across
  logout/login.

  No-op if the agent isn't running.
  """
  @spec wipe_memo_key(String.t()) :: :ok
  def wipe_memo_key(user_id) when is_binary(user_id) do
    case Registry.lookup(DmhAi.Agent.Registry, user_id) do
      [{pid, _}] -> GenServer.cast(pid, :wipe_memo_key)
      [] -> :ok
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
    # `DmhAi.Agent.TaskRuntime` at app startup.
    #
    # Orphan recovery: self-send `:boot_scan` so that any user
    # messages persisted to `session.messages` but never answered
    # (GenServer was down or idle-timed-out while work was queued)
    # are picked up as soon as this instance is alive. Deferred via
    # send so `init/1` returns promptly; the scan runs inside the
    # normal mailbox loop. See architecture.md §Boot scan for orphan
    # recovery.
    send(self(), :boot_scan)
    {:ok, %__MODULE__{user_id: user_id}, @idle_timeout}
  end

  # Assistant path — strictly separated from Confidant. Requires a loaded
  # session in "assistant" mode; mismatched mode is a handler bug and gets
  # refused here as a safety net.
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

  # Platform state
  def handle_call({:get_platform_state, platform}, _from, state) do
    {:reply, Map.get(state.platform_state, platform), state, @idle_timeout}
  end

  # Memo encryption — see specs/memo_encryption.md.
  #
  # Lazy DB unwrap on cache miss: the GenServer's memo_key cache is
  # ephemeral (wiped on idle timeout or restart), but the DB-backed
  # wrap survives. Any cache miss triggers a one-time SELECT + AES-
  # GCM unwrap; the result is cached for the rest of this GenServer's
  # lifetime.
  #
  # Bad-master-key path: same auto-rotation as `:ensure_memo_key`.
  # The wrap is mathematically unrecoverable (master key gone), so
  # every memo encrypted under it is already garbage. Wiping +
  # regenerating gives the user a clean slate so the *next* memo
  # save / retrieval works under the current master key. Without
  # this, the read path silently returns nil and the user sees
  # Confidant blathering with no memo grounding (and no signal that
  # their memos are gone).
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
              "[UserAgent] master-key mismatch on read for user=#{state.user_id} — " <>
                "auto-rotating memo wrap. All previously-encrypted memos are unrecoverable " <>
                "and will be deleted. Persist /data/secrets across deploys to prevent this."
            )
            DmhAi.SysLog.log(
              "[MemoCrypto] master-key mismatch (read) user=#{state.user_id} — wrap + memo rows wiped, fresh MMK generated")

            wipe_user_memo_state(state.user_id)
            generate_and_persist_mmk(state)

          {:error, _r} ->
            {:reply, nil, state, @idle_timeout}
        end
    end
  end

  # First-write path: if the user has no wrapped MMK row yet,
  # generate one, persist it (wrapped under the master key), cache
  # in state, return. If they already have one, return it (idempotent).
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

          # Master-key file changed (or was lost on container rebuild).
          # The existing wrap is mathematically unrecoverable, and so is
          # every memo it ever encrypted. Auto-rotate: wipe the user's
          # stale wrap + memo rows, generate a fresh wrap. Log loud so
          # operators see what happened. See specs/memo_encryption.md
          # § Master-key recovery.
          {:error, :bad_master_key} ->
            Logger.warning(
              "[UserAgent] master-key mismatch for user=#{state.user_id} — auto-rotating " <>
                "memo wrap. All memos previously encrypted under the lost key are unrecoverable " <>
                "and will be deleted. Persist /data/secrets across deploys to prevent this."
            )
            DmhAi.SysLog.log(
              "[MemoCrypto] master-key mismatch user=#{state.user_id} — wrap + memo rows wiped, fresh MMK generated")

            wipe_user_memo_state(state.user_id)
            generate_and_persist_mmk(state)

          {:error, reason} ->
            {:reply, {:error, reason}, state, @idle_timeout}
        end
    end
  end


  # Stop button — kill the inline turn immediately. See
  # `cancel_current_turn/1` for the public-API docstring + invariants.
  #
  # Order matters here, all inside the synchronous handle_call:
  #   1. demonitor with :flush — drops any already-queued :DOWN so
  #      our own kill below doesn't double-fire the :DOWN handler
  #      after we've already cleared state. (Without :flush the
  #      :DOWN clause would land with current_task = nil and fall
  #      through to the catch-all swallow — harmless but noisy.)
  #   2. Process.exit(pid, :kill) — brutal-kill the inline Task.
  #      Closes its Finch socket(s), kills any spawned children,
  #      collapses the LLM stream collector via the Task's
  #      supervision link.
  #   3. Clear stream_buffer + thinking_buffer — wipes any partial
  #      tokens written before the kill. The Task may have written
  #      to these between our kill signal and its actual exit; we
  #      clear AFTER the exit signal has been sent so a final write
  #      from the doomed Task can't race in afterwards.
  #   4. Append `chain_aborted` SessionProgress row. FE-visible
  #      chain-end signal — same shape as the existing
  #      `anchor_task_cancelled?` graceful-end path.
  #   5. Clear current_task in state.
  #
  # `RunningTools` registration (run_script in flight) — left to
  # natural cleanup. The brutal-killed run_script's docker-exec
  # subprocess receives SIGPIPE on its log file pipe and exits;
  # the next /poll's orphan-cleanup sweeper flips its progress
  # row to done. We don't need to touch it here.
  def handle_call(:cancel_current_turn, _from, state) do
    case state.current_task do
      nil ->
        {:reply, {:ok, :no_active_turn}, state, @idle_timeout}

      {ref, task_pid, reply_pid, session_id, _mode} ->
        Process.demonitor(ref, [:flush])

        if is_pid(task_pid) and Process.alive?(task_pid) do
          Process.exit(task_pid, :kill)
        end

        # Notify any synchronous waiter on the original dispatch
        # call. Caller may already be gone (HTTP conn died on
        # FE force-reload), or be `nil` for non-user-initiated
        # dispatches (auto-resume, silent turn) — `safe_reply/2`
        # is a no-op in both cases.
        safe_reply(reply_pid, {:cancelled, "Stopped by user."})

        _ = StreamBuffer.clear(session_id, state.user_id)
        _ = ThinkingBuffer.clear(session_id, state.user_id)
        _ = DmhAi.Agent.ChainInFlight.clear(session_id)

        progress_ctx = %{
          session_id: session_id,
          user_id:    state.user_id,
          task_id:    nil
        }
        _ = DmhAi.Agent.SessionProgress.append(
              progress_ctx, "chain_aborted", "Stopped by user.")

        Logger.info("[UserAgent] cancel_current_turn user=#{state.user_id} session=#{session_id}")
        DmhAi.SysLog.log("[UserAgent] cancel_current_turn user=#{state.user_id} session=#{session_id}")

        {:reply, {:ok, :stopped}, %{state | current_task: nil}, @idle_timeout}
    end
  end

  # Read-only — returns the session_id of the in-flight inline turn,
  # or nil. Used by `/poll` to surface a per-session busy flag.
  def handle_call(:current_turn_session_id, _from, state) do
    sid =
      case state.current_task do
        {_ref, _pid, _reply, session_id, _mode} -> session_id
        nil -> nil
      end

    {:reply, sid, state, @idle_timeout}
  end

  # Auto-chain pickup, synchronous-confirmed path. TaskRuntime calls
  # this from its periodic timer instead of `send/2`, because the
  # bare-send pattern is racy: between `Supervisor.ensure_started`
  # returning the pid and the message being enqueued, the GenServer
  # can finish processing its idle :timeout and stop, leaving the
  # message destined for a defunct mailbox. `GenServer.call/3` raises
  # `:exit` on dead-pid contact so the caller can retry, AND the
  # mailbox is guaranteed to receive the message before the call
  # returns (or the call exits — never silently drops). Reply is
  # `:ok` regardless of busy/idle: the caller's only contract is
  # "did my message land". Idle → start_silent_turn; busy → the
  # post-completion `maybe_trigger_next_due/1` path picks it up
  # naturally on the next chain-complete, so no re-queue needed.
  def handle_call({:task_due, task_id}, _from, state) do
    {reply, new_state} = do_task_due(task_id, state)
    {:reply, reply, new_state, @idle_timeout}
  end

  @impl true
  def handle_cast({:set_platform_state, platform, pstate}, state) do
    {:noreply, %{state | platform_state: Map.put(state.platform_state, platform, pstate)},
     @idle_timeout}
  end

  # Drop the in-memory MMK cache. Called by the admin password reset
  # handler — the underlying DB wrap is also being destroyed there,
  # so the in-memory cached MMK would otherwise still be used by
  # in-flight or scheduled work and produce ciphertext that's
  # unreadable on next read (DB wrap is gone). Dropping the cache
  # forces the next memo activity to go through `ensure_memo_key`
  # and generate a fresh wrap.
  #
  # NOT called by logout — per spec, memos must remain accessible
  # across logout/login. Logout only revokes the auth token.
  def handle_cast(:wipe_memo_key, state) do
    {:noreply, %{state | memo_key: nil}, @idle_timeout}
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
  #   * `{:chain_done, watermark_ts, auto_pivot_signal}` — Assistant
  #     session_chain_loop. Every terminal branch returns this 3-tuple.
  #     `auto_pivot_signal` is one of:
  #       - `false` — normal chain end. Auto-resume only when a new user
  #         message arrived after the chain's watermark.
  #       - `{:auto_pivot, task_id}` — close-verb chain synthesised a
  #         `create_task` for a stashed pivot. The trailing user-role
  #         message in session.messages was the runtime trigger and is
  #         already consumed; the next chain MUST go through the
  #         silent-pickup path so a synthetic kicker overrides the
  #         trailing chat tail. Without this, a normal auto-resume
  #         replays the consumed trigger as a fresh ask and the model
  #         close-verbs the freshly-created task.
  #   * anything else — Confidant path; only `:ok`-like returns reach
  #     here on the error branch. The mode-aware match below skips
  #     auto-resume entirely for Confidant.
  #
  # Auto-resume routing (Assistant only):
  #   - normal user-msg auto-resume → `{:auto_resume_assistant, sid}`
  #     (the existing 2-arity message; rebuilds context from session
  #     and treats the trailing user message as the fresh ask).
  #   - auto-pivot pickup → `{:auto_resume_assistant, sid, {:pickup, task_id}}`
  #     (3-arity; routes to `run_assistant_silent` with kind=:auto_pivot).
  #
  # Both decisions live in the GenServer (this callback) so the
  # message always lands in the right mailbox; the chain Task itself
  # never sends `:auto_resume_assistant` (its `self()` is the Task pid,
  # not the GenServer).
  #
  # The 5-tuple `{ref, pid, reply_pid, session_id, mode}` carries the
  # dispatched mode forward so the hook never has to guess. Auto-resume
  # is an Assistant-only concept — Confidant is single-turn and there
  # is no chain to fold a queued message into.
  @impl true
  def handle_info({ref, result}, %{current_task: {ref, _task_pid, _reply_pid, session_id, mode}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current_task: nil}

    case mode do
      "assistant" ->
        decision =
          case result do
            {:chain_done, _watermark_ts, {:auto_pivot, task_id}} when is_binary(task_id) ->
              {:pickup, task_id}

            {:chain_done, watermark_ts, false} when is_integer(watermark_ts) ->
              if DmhAi.Agent.UserAgentMessages.user_msgs_since(session_id, watermark_ts) != [],
                do: :resume,
                else: :idle
          end

        # No catch-all. The two clauses above cover EVERY legitimate
        # return from `session_chain_loop` / `run_assistant_silent`.
        # Anything else is a shape regression — most recently
        # `{:chain_done, _, {:auto_pivot, nil}}` slipped through the
        # old defensive catch-all and routed to the wrong path,
        # causing the model to close-verb the auto-pivoted task. Let
        # the missing match raise: the supervisor restarts the
        # GenServer (state is small, boot_scan recovers it on next
        # dispatch), the stack trace lands in Logger.error AND the
        # SysLog tail-file, and the bug is loud instead of subtle.
        # If a future return shape becomes legitimate, ADD a clause
        # here — do not paper over with a wildcard.

        case decision do
          :resume ->
            send(self(), {:auto_resume_assistant, session_id})

          {:pickup, task_id} ->
            send(self(), {:auto_resume_assistant, session_id, {:pickup, task_id}})

          :idle ->
            maybe_trigger_next_due(session_id)
        end

      "confidant" ->
        # Confidant is single-turn. Persisting a reply (or an error
        # placeholder, see `run_confidant`'s `{:error, _}` arm) is
        # the pipeline's own responsibility; the chain hook never
        # retries on its behalf.
        :ok

      other ->
        # Unknown mode landing here is a wiring bug — `dispatch_run`
        # only ever stores "assistant" or "confidant" in the
        # current_task tuple, and the HTTP handler validates mode
        # before dispatch. Fail loud so a future mode-add can't
        # silently skip auto-resume.
        msg = "[UserAgent] unknown mode in chain-complete hook: #{inspect(other)} session=#{session_id}"
        Logger.error(msg)
        DmhAi.SysLog.log(msg)
        raise "unknown chain-complete mode: #{inspect(other)}"
    end

    {:noreply, state, @idle_timeout}
  end

  # Stray {ref, _result} from tasks we no longer track — swallow.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state, @idle_timeout}
  end

  # Inline task crashed. Make the failure visible to the FE via the
  # same `chain_aborted` end-signal the Stop-button / per-task cancel
  # path uses, then clear state.
  #
  # `Task.Supervisor.async_nolink/2` registers a `Process.monitor` on
  # the spawned task PID, which delivers `{:DOWN, ref, :process, pid,
  # reason}`. (The `:task` atom spelling here used to make this whole
  # clause dead code: any crashed inline-task `:DOWN` fell through to
  # the catch-all below WITHOUT clearing `current_task`, leaving the
  # per-user agent permanently "busy" until its 30-minute idle
  # timeout. Symptom was a sticky "Agent is busy, please wait" 409
  # even after the task had clearly died long ago.)
  #
  # Why we DON'T auto-resume Assistant on crash — even when the user
  # message is still unanswered. The crash cause is usually
  # deterministic (broken model setting, network down, OOM). An
  # immediate re-dispatch would crash the same way and fire `:DOWN`
  # again → infinite silent retry loop hammering the LLM. The user
  # must see the error row and decide whether to retry. Auto-resume
  # remains for the legitimate paths: mid-chain user-message
  # injection on natural completion (`handle_info({ref, result}, ...)`)
  # and boot-scan recovery after GenServer restart.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task: {ref, _task_pid, reply_pid, session_id, mode}} = state) do
    # Log the crash reason to BOTH Logger (for systemd journals) AND
    # SysLog (for the operator-visible system.log file). Without the
    # SysLog mirror, post-mortem diagnostics depended on having access
    # to the live BEAM stderr — out of reach for most operators.
    crash_summary =
      "[UserAgent] inline task crashed mode=#{mode} user=#{state.user_id} session=#{session_id} reason=#{inspect(reason, limit: 1000)}"
    Logger.error(crash_summary)
    DmhAi.SysLog.log(crash_summary)

    safe_reply(reply_pid, {:error, "Internal error — please try again"})

    _ = StreamBuffer.clear(session_id, state.user_id)
    _ = ThinkingBuffer.clear(session_id, state.user_id)
    _ = DmhAi.Agent.ChainInFlight.clear(session_id)

    progress_ctx = %{session_id: session_id, user_id: state.user_id, task_id: nil}
    _ = DmhAi.Agent.SessionProgress.append(
          progress_ctx, "chain_aborted", "Internal error — please try again.")

    {:noreply, %{state | current_task: nil}, @idle_timeout}
  end

  # Stray DOWN — swallow. TaskRuntime owns worker-like processes.
  def handle_info({:DOWN, _ref, _type, _pid, _reason}, state) do
    {:noreply, state, @idle_timeout}
  end

  # Auto-chain pickup, async path. Fired in-process by
  # `maybe_trigger_next_due/1` (self-send after the previous turn
  # completed). External callers (TaskRuntime) MUST use the
  # `handle_call({:task_due, _}, ...)` clause instead — see comment
  # there for why.
  def handle_info({:task_due, task_id}, state) do
    {_reply, new_state} = do_task_due(task_id, state)
    {:noreply, new_state, @idle_timeout}
  end

  # Auto-resume: after a chain finished while the DB shows an
  # unanswered user message for this session, synthesise a minimal
  # AssistantCommand and run the pipeline. The new turn's context build
  # includes the queued message naturally (it's already in session.messages).
  # If the agent is busy when this message is drained (e.g. the previous
  # auto-resume is still running), the chain-complete hook will re-fire
  # a new auto_resume_assistant on the next completion, so no re-queue is
  # needed here.
  def handle_info({:auto_resume_assistant, session_id}, %{current_task: nil} = state) do
    # Auto-resume is fire-and-forget; there is no synchronous waiter
    # for `{:error, ...}` / `{:cancelled, ...}` replies. `safe_reply/2`
    # treats `nil` as a no-op, so leaving reply_pid unset costs nothing
    # and avoids the wasted process-spawn-then-die cycle.
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
    # Busy — silent drop. When the current turn completes its chain-
    # complete hook will re-check `has_unanswered_user_msg?` and fire
    # another :auto_resume_assistant at that time.
    {:noreply, state, @idle_timeout}
  end

  # Auto-pivot pickup variant. Fired by the chain-complete hook when
  # the previous chain ended with `{:auto_pivot, task_id}`. Routes
  # through the silent-pickup path (kind: :auto_pivot) so the next
  # chain's context build appends a synthetic kicker that names the
  # new task as the directive — overriding the trailing user-role
  # message in session.messages, which was the runtime trigger for
  # the pivot and is already consumed. Skipping this routing makes
  # the model close-verb the freshly-created task because the
  # trailing chat tail looks like a fresh ask.
  def handle_info({:auto_resume_assistant, session_id, {:pickup, task_id}}, %{current_task: nil} = state) do
    case Tasks.get(task_id) do
      %{} = task ->
        DmhAi.SysLog.log("[ASSISTANT:pickup] user=#{state.user_id} session=#{session_id} task=#{task_id} kind=auto_pivot")
        start_silent_turn(task, session_id, state, kind: :auto_pivot)

      nil ->
        Logger.warning("[UserAgent] auto-pivot pickup target task=#{task_id} not found — skipping")
        {:noreply, state, @idle_timeout}
    end
  end

  def handle_info({:auto_resume_assistant, _session_id, {:pickup, _task_id}}, state) do
    # Busy — silent drop, same recovery path as the 2-arity variant.
    # Match the EXACT pickup tag rather than a wildcard `_opts` — any
    # other shape is a wiring bug we'd rather see crash than swallow.
    {:noreply, state, @idle_timeout}
  end

  # Boot scan: find Assistant-mode sessions for this user where the
  # last persisted message is role="user" and self-dispatch an
  # auto-resume for each. Restores responsiveness after GenServer
  # crash or idle-timeout + respawn. See architecture.md §Boot scan
  # for orphan recovery.
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

  # Idle timeout — shut down cleanly.
  # Defensive re-check: in the narrow window where a new user message is
  # persisted right as we're about to time out, trigger one more
  # auto-resume before stopping. The boot scan on the next spawn
  # guarantees we still pick it up, but resuming in-place avoids the
  # spawn round-trip.
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

  # Read the user's wrapped MMK from DB and unwrap with the master
  # key. Used by `handle_call(:get_memo_key, ...)` and
  # `handle_call(:ensure_memo_key, ...)` to lazy-load on cache miss.
  # Outcomes:
  #
  #   {:ok, mmk}        — V2 wrap; unwrapped successfully.
  #   {:error, :no_wrap}    — row is NULL (user has never saved a memo,
  #                           OR admin reset just wiped it).
  #   {:error, :legacy_v1}  — V1 password-wrap; only the login flow
  #                           can migrate it (we don't have the
  #                           password here). Caller fails soft.
  #   {:error, term}        — unwrap failed (master key changed,
  #                           wrap corrupted). Logs a warning.
  defp lazy_load_memo_key(user_id) do
    case query!(Repo, "SELECT memo_wrapped_mmk FROM users WHERE id=?", [user_id]) do
      %{rows: [[nil]]} ->
        {:error, :no_wrap}

      %{rows: [[wrapped]]} when is_binary(wrapped) ->
        case DmhAi.MemoCrypto.wrap_version(wrapped) do
          :v2 ->
            case DmhAi.MemoCrypto.unwrap_with_master(wrapped, DmhAi.MemoCrypto.MasterKey.get()) do
              {:ok, mmk} ->
                {:ok, mmk}

              {:error, reason} ->
                Logger.warning("[UserAgent] master-key unwrap failed user=#{user_id} reason=#{inspect(reason)}")
                {:error, reason}
            end

          :v1 ->
            Logger.warning("[UserAgent] user=#{user_id} still has legacy v1 wrap — needs login to migrate")
            {:error, :legacy_v1}

          :unknown ->
            Logger.warning("[UserAgent] user=#{user_id} memo_wrapped_mmk has unknown version byte")
            {:error, :unknown_format}
        end

      _ ->
        {:error, :no_wrap}
    end
  end

  # Generate a fresh MMK, wrap under the deployment master key, and
  # persist. Reused by `handle_call(:ensure_memo_key, ...)` for the
  # no-wrap (first-time-user) and the bad-master-key (auto-rotate)
  # branches.
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

  # Sweep the user's memo data when the wrap is unrecoverable. The
  # ciphertext is now garbage so deleting it loses nothing. Vec rows
  # share the same id space and get cleaned via explicit DELETE.
  defp wipe_user_memo_state(user_id) do
    try do
      query!(Repo,
        "DELETE FROM kb_vec_memo WHERE rowid IN (SELECT id FROM kb_chunks_meta WHERE scope='memo' AND user_id=?)",
        [user_id])
      query!(Repo, "DELETE FROM kb_chunks_meta WHERE scope='memo' AND user_id=?", [user_id])
      query!(Repo, "DELETE FROM kb_sources WHERE scope='memo' AND user_id=?", [user_id])
    rescue
      e -> Logger.error("[UserAgent] wipe_user_memo_state failed for user=#{user_id}: #{Exception.message(e)}")
    end
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

  # Shared body for the two `:task_due` entry points (handle_info from
  # internal self-sends, handle_call from TaskRuntime). Returns
  # `{reply, new_state}`. Reply is `:ok` so external callers can
  # confirm delivery; the busy/idle distinction is resolved here.
  defp do_task_due(task_id, %{current_task: nil} = state) do
    case Tasks.get(task_id) do
      %{task_status: "pending", session_id: session_id} = task ->
        {:noreply, new_state, _timeout} = start_silent_turn(task, session_id, state)
        {:ok, new_state}

      _ ->
        # Task disappeared, already done, or flipped to paused/cancelled.
        {:ok, state}
    end
  end

  # Agent is busy — drop the message. The post-completion
  # `maybe_trigger_next_due/1` path will pick it up after the current
  # turn finishes, so we don't need to re-queue.
  defp do_task_due(_task_id, state), do: {:ok, state}

  # Start an auto-triggered turn for a task picked off the pending
  # queue OR for an auto-pivot freshly-created task. Output lands in
  # DB (session_progress, sessions.messages, stream_buffer) exactly
  # as for a user-initiated turn; FE polling renders it.
  #
  # Options:
  #   * `:kind` — `:periodic` (default; periodic-task scheduler pickup)
  #     or `:auto_pivot` (one_off task synthesised by the runtime
  #     after a confirmed pivot). Forwarded to `run_assistant_silent`,
  #     which selects the synthetic kicker accordingly. Both kinds
  #     share the same Police-gate scope (silent_turn_task_id) and the
  #     same context-build pipeline; only the kicker prose differs.
  defp start_silent_turn(task, session_id, state, opts \\ []) do
    kind    = Keyword.get(opts, :kind, :periodic)
    task_id = task.task_id

    spawned =
      Task.Supervisor.async_nolink(DmhAi.Agent.TaskSupervisor, fn ->
        case load_session(session_id, state.user_id) do
          {:ok, _model, session_data} ->
            if (session_data["mode"] || "confidant") == "assistant" do
              run_assistant_silent(task, session_data, state.user_id, kind: kind)
            else
              Logger.warning("[UserAgent] skipping auto task-due for non-assistant session=#{session_id}")
            end

          {:error, reason} ->
            Logger.warning("[UserAgent] auto task-due load failed session=#{session_id} task=#{task_id} reason=#{inspect(reason)}")
        end
      end)

    # reply_pid is `nil` for silent turns: there is no synchronous
    # waiter for the busy / cancelled / error replies that the
    # user-initiated path emits. `safe_reply/2` no-ops on nil so the
    # cancel-current-turn and DOWN handlers keep working unchanged.
    # Mode is hard-coded "assistant" — silent turns are scheduler-driven
    # or runtime-synthesised pickups, which only exist for
    # Assistant-mode sessions (start_silent_turn skips non-assistant
    # sessions explicitly).
    {:noreply,
     %{state | current_task: {spawned.ref, spawned.pid, nil, session_id, "assistant"}},
     @idle_timeout}
  end

  # Silent equivalent of run_assistant for auto-triggered task pickups.
  # Builds context like normal BUT appends a synthetic trailing user-role
  # message to the LLM context only (NOT persisted to session.messages)
  # that says "[Task due: …] — pick it up now". The model then responds
  # as it would to a real user ask. The final assistant text IS persisted
  # so next turn's LLM context carries the audit trail.
  defp run_assistant_silent(task, session_data, user_id, opts) do
    kind   = Keyword.fetch!(opts, :kind)
    model   = AgentSettings.assistant_model()
    profile = load_user_profile(user_id)
    email   = Tasks.lookup_user_email(user_id)
    session_id = task.session_id

    active_tasks = Tasks.active_for_session(session_id)
    recent_done  = Tasks.recent_done_for_session(session_id)

    llm_messages =
      ContextEngine.build_assistant_messages(session_data,
        user_id:      user_id,
        profile:      profile,
        active_tasks: active_tasks,
        recent_done:  recent_done,
        files:        [],
        # The silent-pickup task IS the anchor for this chain — pass
        # its `task_num` so the conservative-token-saving filter can
        # drop other-task-tagged history.
        anchor_task_num: Map.get(task, :task_num),
        # Forward the silent-pickup target so the anchor block names
        # this task explicitly (no runtime lookup would otherwise pick
        # a periodic task over other candidates).
        silent_turn_task_id: task.task_id
      )

    # Append synthetic kicker as the last user-role turn so the model
    # knows what to act on. Not persisted — it's an internal prompt,
    # not user input. The model's final assistant text IS persisted
    # via append_session_message below. Kicker prose varies by `kind`:
    #
    #   :periodic — scheduler-driven pickup of an existing periodic
    #     task. Tells the model to deliver this cycle's output and
    #     close with complete_task; runtime auto-reschedules.
    #
    #   :auto_pivot — runtime-synthesised one_off task created from a
    #     user pivot that was just confirmed by a close-verb. Tells
    #     the model to treat the new task's spec as the directive
    #     and ignore the trailing chat tail (which was the runtime
    #     trigger, already consumed). Without this redirect, the
    #     model would misinterpret the trailing close-verb message
    #     as a fresh ask and close-verb the freshly-created task.
    llm_messages = llm_messages ++ [silent_pickup_kicker(task, kind)]

    data_dir      = DmhAi.Constants.session_data_dir(email, session_id)
    workspace_dir = DmhAi.Constants.session_workspace_dir(email, session_id)
    File.mkdir_p(data_dir)
    File.mkdir_p(workspace_dir)

    ctx = %{
      user_id:       user_id,
      user_email:    email,
      user_role:     Tasks.lookup_user_role(user_id),
      session_id:    session_id,
      session_root:  DmhAi.Constants.session_root(email, session_id),
      data_dir:      data_dir,
      workspace_dir: workspace_dir,
      keystore_dir:  DmhAi.Constants.user_keystore_dir(email),
      log_trace:     AgentSettings.log_trace(),
      # Snapshot the initial message count so the duplicate-tool-call
      # police check only sees the within-chain accumulator, never history.
      chain_start_idx: length(llm_messages),
      # Silent-turn scope marker — drives Police gate #9. A scheduler
      # pickup fires for ONE specific task; the model must not use the
      # trigger as an opportunity to create new tasks, cancel the
      # triggered task to start a different one, or touch other tasks'
      # state. Police rule #9 reads this ctx key to enforce the
      # one-task-per-silent-turn invariant.
      silent_turn_task_id: task.task_id,
      # Silent-turn anchor starts at the triggered task's task_num and
      # can flip via back_to_when_done when the model completes /
      # cancels / pauses the pickup inside the chain. See
      # architecture.md §Anchor mutation via back_to_when_done.
      anchor_task_num: Map.get(task, :task_num),
      last_rendered_anchor_task_num: Map.get(task, :task_num),
      # Per-call task_num attribution — every tool_call_id that runs in
      # this chain gets stamped with the task_num it operated on, so
      # `save_tools_result_of_chain` can split the chain's pairs into
      # one tool_history entry per task. Prevents the orphan-task_num
      # bug where chain-spanning operations (cancel→auto-create) would
      # leave entries unflushable. See `execute_tools/3`.
      tool_call_task_nums: %{},
      role:          "assistant",
      model:         model
    }

    DmhAi.SysLog.log("[ASSISTANT:auto] user=#{user_id} session=#{session_id} task=#{task.task_id} title=#{String.slice(task.task_title || "", 0, 60)}")

    # Flip the task to 'ongoing' at pickup start — the silent-turn
    # entry point acts as an implicit `pickup_task` for the triggered
    # row (the model doesn't need to re-pickup a task whose pickup
    # this turn *is*). Closes the cadence-correctness gap for
    # periodic pickups: without it, a silent turn starts with the
    # task `pending` (from the prior pickup's mark_done) and relies
    # on the model calling `complete_task(...)` to advance it. If the
    # model skips that, `auto_close_ongoing_tasks` at text-turn end
    # filters for status=="ongoing" and finds nothing → `mark_done`
    # never fires → `time_to_pickup` stays in the past →
    # `maybe_trigger_next_due` re-dispatches {:task_due} immediately
    # → burst fire until the model eventually complies. Marking
    # ongoing here guarantees auto_close catches the pickup's
    # completion and reschedules for the next intvl_sec window
    # regardless of model behaviour.
    Tasks.mark_ongoing(task.task_id)

    # Mark the chain as in-flight so /poll exposes it to the FE; the
    # FE's pollTurnToCompletion uses this to avoid tearing down the
    # streaming placeholder on intermediate-text turns. See
    # architecture.md §Polling-based delivery.
    DmhAi.Agent.ChainInFlight.set(session_id)

    result =
      try do
        session_chain_loop(llm_messages, model, ctx, 0)
      after
        DmhAi.Agent.ChainInFlight.clear(session_id)
      end

    Task.start(fn -> maybe_compact(session_id, user_id) end)

    # Same watermark plumbing as `run_assistant/3` — returned to the
    # chain-complete hook so a silent pickup that landed at the same
    # time as a user message still auto-resumes for the user.
    result
  end

  # Build the synthetic trailing user-role message that drives a
  # silent pickup. The same message structure for both kinds; the
  # prose differs because the two pickup contexts impose different
  # workflow expectations on the model.
  defp silent_pickup_kicker(task, :periodic) do
    task_num = Map.get(task, :task_num)

    %{role: "user",
      content:
        "<silent_pickup>\n\n" <>
        "**Task due: (#{task_num}) — #{task.task_title}**\n\n" <>
        "This is a PICKUP of the EXISTING periodic task (#{task_num}). " <>
        "The runtime has already flipped it to `ongoing` for you — " <>
        "you do NOT need to call `pickup_task`. (Calling it is a harmless " <>
        "no-op; skipping it is preferred to save a turn.)\n\n" <>
        "**STAY IN LANE** — a silent pickup is scoped to THIS ONE TASK. " <>
        "Even if the user asked about a different task in an earlier " <>
        "conversational turn, do NOT act on that here. The user will " <>
        "re-ask on their next message; wait for it. Forbidden this turn: " <>
        "`create_task` (any type), `pickup_task` / `complete_task` / " <>
        "`pause_task` / `cancel_task` on ANY task_num other than " <>
        "#{task_num}, and cancelling (#{task_num}) itself to " <>
        "free the periodic slot.\n\n" <>
        "**Workflow:**\n\n" <>
        "1. Run whatever execution tools you need (web_fetch, run_script, etc.) " <>
        "to produce this cycle's fresh output.\n" <>
        "2. Close (#{task_num}) with `complete_task` — passing the task's " <>
        "number and a one-line short summary. The runtime auto-reschedules the next cycle.\n" <>
        "3. Your final text IS the task output (the joke, the quote, the status — " <>
        "whatever this task produces). Write it directly in the user's language. " <>
        "NO meta-prefix like \"Joke delivered:\", \"Task complete\", \"Here is your...\", " <>
        "\"Your update:\". The user just wants the content.\n\n" <>
        "</silent_pickup>"}
  end

  defp silent_pickup_kicker(task, :auto_pivot) do
    task_num = Map.get(task, :task_num)
    spec     = String.slice(task.task_spec || "", 0, 400)

    %{role: "user",
      content:
        "<auto_pivot_pickup>\n\n" <>
        "**Anchor moved to (#{task_num}) — #{inspect(spec)}**\n\n" <>
        "The previous chain consumed the user's pivot signal by closing the prior " <>
        "anchor. The trailing user-role message in your context above is the " <>
        "runtime's already-handled trigger, NOT a fresh ask. Treat (#{task_num})'s " <>
        "spec as the directive and begin execution work on it.\n\n" <>
        "**STAY IN LANE** — a runtime-synthesised pickup is scoped to THIS ONE TASK. " <>
        "Forbidden this turn: any close-verb on (#{task_num}) before producing " <>
        "real work for it; `create_task` (any type); `pickup_task` / " <>
        "`complete_task` / `pause_task` / `cancel_task` on any other task_num. " <>
        "Do NOT respond to the trailing chat-tail — it is consumed.\n\n" <>
        "**Workflow:**\n\n" <>
        "1. Run whatever execution tools the spec requires (web_fetch, " <>
        "run_script, MCP integrations, etc.) to deliver the answer.\n" <>
        "2. Close (#{task_num}) with `complete_task` — passing the task's " <>
        "number and a one-line short result.\n" <>
        "3. Your final text IS the answer. Write it directly in the user's " <>
        "language. No meta-prefix, no bookkeeping line.\n\n" <>
        "</auto_pivot_pickup>"}
  end

  # Mid-chain splice: return `messages` with any newly-arrived user
  # messages appended. "Newly arrived" = rows in `session.messages`
  # whose role="user" and whose `ts` is greater than the greatest `ts`
  # of any user-role entry already present in `messages`. Entries
  # without a `ts` (synthetic `[Task due:]` injections, Police nudges
  # injected as role=user) don't count toward the floor — they have no
  # DB representation, so they must not block a genuine DB message
  # from being spliced in. See architecture.md §Mid-chain user
  # message injection.
  defp splice_mid_chain_user_msgs(messages, %{session_id: session_id}) do
    floor_ts = max_user_ts_in_messages(messages)

    case DmhAi.Agent.UserAgentMessages.user_msgs_since(session_id, floor_ts) do
      [] ->
        messages

      new_msgs ->
        DmhAi.SysLog.log("[ASSISTANT] mid-chain splice: #{length(new_msgs)} new user msg(s) since ts=#{floor_ts}")
        messages ++ Enum.map(new_msgs, &normalize_spliced_msg/1)
    end
  end

  # Max `ts` of any user-role message in a message list. Used both as
  # the splice-floor in `splice_mid_chain_user_msgs` and as the chain
  # watermark returned with `{:chain_done, ts, auto_pivot?}`. Entries
  # without a `ts` (synthetic injections — Police nudges,
  # `[Task due: ...]` markers) are ignored.
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

  # Refresh the prompt's `## Active task` block mid-chain when the
  # runtime anchor has moved. Appends a synthetic user/assistant pair
  # to `messages` naming the current anchor (or a "none / free mode"
  # notice when the anchor has gone nil). Updates ctx's
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
      DmhAi.SysLog.log("[ASSISTANT] anchor refresh (#{inspect(last)}) → (#{inspect(current)}) — injecting prompt block")
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
      "<active_task_update>\n\n" <>
        "- Current task: none (free mode).\n" <>
        "- The chain's pickup task is closed and no back-reference " <>
        "remains. **Emit your final user-facing text and end the " <>
        "chain.** No more tool calls.\n\n" <>
        "</active_task_update>"

    [%{role: "user", content: body}]
  end

  defp render_anchor_refresh_block(n) when is_integer(n) do
    body =
      "<active_task_update>\n\n" <>
        "- Current task: (#{n}).\n" <>
        "- The previous task in this chain is closed; focus has " <>
        "returned to (#{n}) via its back-reference. Continue the " <>
        "work or emit your final text.\n\n" <>
        "</active_task_update>"

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
  #
  # Returns `{result, new_state}`. Callers wrap into the appropriate
  # GenServer reply tuple — `handle_call` uses `{:reply, result, new_state, t}`,
  # `handle_info` uses `{:noreply, new_state, t}` (and ignores result).
  # OTP forbids `{:reply, ...}` from `handle_info`; returning it crashes the
  # GenServer, the supervisor respawns it, and any `async_nolink` task spawned
  # before the crash keeps running — which previously allowed multiple
  # `auto_resume_assistant` messages to each spawn parallel chains.
  defp dispatch_run(command, state, run_fn, opts) do
    required_mode = Keyword.fetch!(opts, :required_mode)
    reply_pid     = command.reply_pid

    cond do
      state.current_task && required_mode == "assistant" ->
        # The user message is already persisted to `session.messages`
        # by the HTTP handler. The in-flight chain's
        # `session_chain_loop` will splice it into the next LLM roundtrip
        # (mid-chain), or the chain-complete hook will auto-resume if
        # the chain finishes before the LLM call picks it up. Either
        # way, the FE gets a 202-like ack here. See architecture.md
        # §Mid-chain user message injection.
        safe_reply(reply_pid, {:error, :queued})
        {{:error, :queued}, state}

      state.current_task ->
        # Confidant still uses a synchronous busy reject (its one-shot
        # streaming contract has no chain to fold messages into).
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
                  # Shouldn't happen — the HTTP handler checks mode before
                  # building the command. Refuse loudly if it does.
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

  # Send a reply to a `reply_pid` slot that may be a live pid, a dead
  # pid (HTTP conn died), or `nil` (auto-resume / silent turn — no
  # synchronous waiter). All three are valid: live pids receive the
  # message, dead pids drop it (Erlang `send` is a no-op for dead
  # pids), nil takes the no-op clause here. Use this anywhere
  # `command.reply_pid` or the `reply_pid` slot of `current_task` is
  # contacted, so changing the "no waiter" representation never has
  # to touch every send site.
  defp safe_reply(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp safe_reply(_, _), do: :ok

  # ─── Confidant pipeline ─────────────────────────────────────────────────
  # Fire-and-forget: detect web search → maybe fetch → stream LLM tokens
  # into `sessions.stream_buffer`. FE polls the column for progressive text.

  defp run_confidant(%ConfidantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.confidant_model()

    # Run the two pre-step retrievals (web search + memo auto-retrieve)
    # in PARALLEL so total wall time is max(t_web, t_memo) rather than
    # the sum. Both bail to nil when their gating logic decides nothing
    # to fetch (web: WebSearchEngine.search returns :no_search; memo:
    # vector search produces no
    # above-threshold hits). See specs/commands.md §Confidant memo
    # auto-retrieve.
    {web_context, memo_context} =
      if command.content != "" do
        user_msgs = extract_user_messages(session_data)

        # Memo retrieval runs FIRST (synchronously) so its hits can be
        # passed into the web-search planner prompt. The planner then
        # decides SEARCH:YES/NO with full visibility of what the user
        # has saved — Rule 0 in the planner template tells it to skip
        # the web when a saved memo answers the question. This deletes
        # the entire homophone-confusion class of false-positives
        # (e.g. unaccented "con cho" → "con chợ" → market-closure
        # queries) and saves SearXNG + page-fetch wall time on every
        # memo-answerable turn.
        #
        # See specs/commands.md § Confidant memo auto-retrieve and
        # specs/commands.md § Memo-aware web planner.
        {memo_context, memo_hits} = build_memo_context(command.content, user_msgs, user_id)

        web_task =
          Task.async(fn ->
            # Two-phase to keep the FE honest:
            #   1. classify (cheap LLM call) — decide YES/NO, pick category & queries.
            #   2. only if YES → append a `kind: "confidant_websearch"`
            #      session_progress row and run SearXNG + page fetches.
            # Creating the row before classify would make a "WebSearch → q"
            # row briefly flash on no-search turns ("why moon goes around
            # sun?"), which is misleading UX.
            #
            # Kind `confidant_websearch` is intentionally distinct from
            # `kind: "tool"` (Assistant LLM tool_call invocations) so audit
            # / Police queries never conflate the two paths. FE renders
            # both identically via `_TOOL_LIKE_KINDS` in manager-chat.js.
            case WebSearchEngine.generate_search_queries(command.content, user_msgs, :confidant, memo_hits) do
              {:no_search} ->
                nil

              {:search, category, queries} ->
                DmhAi.SysLog.log("[SEARCH] category=#{category} queries=#{inspect(Enum.map(queries, & &1.text))}")

                progress_ctx = %{session_id: session_id, user_id: user_id, task_id: nil}
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
        web_context:        web_context,
        memo_context:       memo_context,
        timezone:           command.timezone,
        local_date:         command.local_date
      )

    DmhAi.SysLog.log("[CONFIDANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)} web_search=#{web_context != nil} memo_context=#{memo_context != nil}")
    DmhAi.SysLog.log("[CONFIDANT] sending #{length(llm_messages)} msgs to model=#{model}\n  #{log_llm_messages(llm_messages)}")

    # Stream collector: tokens from LLM.stream flow here, where they are
    # appended to the per-session stream_buffer column. FE polling reads
    # the column and renders progressive text. Thinking tokens flow into
    # the parallel thinking_buffer column on the same path.
    collector = spawn_confidant_stream_collector(session_id, user_id)

    on_tokens = fn rx, tx -> TokenTracker.add_master(session_id, user_id, rx, tx) end
    trace     = %{origin: "confidant", path: "UserAgent.run_confidant", role: "ConfidantMaster", phase: "single-turn"}

    result = LLM.stream(model, llm_messages, collector, on_tokens: on_tokens, trace: trace)
    # Synchronously wait for the collector to drain any in-flight chunks
    # and exit — prevents its final `flush/1` from racing with our clear/2
    # below, which would leave a stale (possibly empty) buffer behind.
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

        Task.start(fn -> maybe_compact(session_id, user_id) end)

        Task.start(fn -> ProfileExtractor.extract_and_merge(user_id) end)

      {:ok, ""} ->
        StreamBuffer.clear(session_id, user_id)
        ThinkingBuffer.clear(session_id, user_id)
        DmhAi.SysLog.log("[CONFIDANT] empty response — no message persisted")

      {:error, reason} ->
        StreamBuffer.clear(session_id, user_id)
        ThinkingBuffer.clear(session_id, user_id)
        DmhAi.SysLog.log("[CONFIDANT] ERROR: #{inspect(reason)}")

        # Persist a localized error placeholder so session.messages
        # doesn't end with role="user". Without this the chain hook's
        # last-message check (pre-A' was the trigger) would loop, and
        # the user would see no feedback at all. Distinct from the
        # Assistant chain's richer error handling at session_chain_loop
        # `{:error, _}` arm — Confidant has no chain semantics, no
        # task_num to tag, no system-error vs generic classification.
        # A short Oracle-localized apology is enough.
        ack = Swift.localize(
          "Sorry — couldn't reach the model. Please try again.",
          command.content
        )

        append_session_message(session_id, user_id, %{role: "assistant", content: ack})
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

  # ─── Assistant collector ──────────────────────────────────────────────
  #
  # Loop process that accumulates {:chunk, token} into the
  # `stream_buffer` column AND {:thinking, token} into the
  # `thinking_buffer` column. FE polls both for progressive answer +
  # live thinking-of-thought rendering.
  #
  # Kept as a separate loop from the Confidant collector
  # (`spawn_confidant_stream_collector`) so changes to one pipeline's
  # streaming behavior never bleed into the other.
  defp spawn_assistant_stream_collector(session_id, user_id) do
    spawn(fn ->
      assistant_stream_collector_loop(
        StreamBuffer.new(session_id, user_id),
        ThinkingBuffer.new(session_id, user_id)
      )
    end)
  end

  defp assistant_stream_collector_loop(answer_buf, thinking_buf) do
    receive do
      {:chunk, token} when is_binary(token) ->
        new_answer = answer_buf |> StreamBuffer.append(token) |> StreamBuffer.maybe_flush()
        assistant_stream_collector_loop(new_answer, thinking_buf)

      {:thinking, token} when is_binary(token) ->
        new_thinking = thinking_buf |> ThinkingBuffer.append(token) |> ThinkingBuffer.maybe_flush()
        assistant_stream_collector_loop(answer_buf, new_thinking)

      :flush_and_stop ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
        :ok

      _ ->
        assistant_stream_collector_loop(answer_buf, thinking_buf)
    after
      120_000 ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
    end
  end

  # ─── Confidant collector ──────────────────────────────────────────────
  #
  # Mirror of the Assistant collector, kept separate per the
  # "Confidant and Assistant pipelines stay isolated" rule. Behavior is
  # identical today but each can evolve independently.
  defp spawn_confidant_stream_collector(session_id, user_id) do
    spawn(fn ->
      confidant_stream_collector_loop(
        StreamBuffer.new(session_id, user_id),
        ThinkingBuffer.new(session_id, user_id)
      )
    end)
  end

  defp confidant_stream_collector_loop(answer_buf, thinking_buf) do
    receive do
      {:chunk, token} when is_binary(token) ->
        new_answer = answer_buf |> StreamBuffer.append(token) |> StreamBuffer.maybe_flush()
        confidant_stream_collector_loop(new_answer, thinking_buf)

      {:thinking, token} when is_binary(token) ->
        new_thinking = thinking_buf |> ThinkingBuffer.append(token) |> ThinkingBuffer.maybe_flush()
        confidant_stream_collector_loop(answer_buf, new_thinking)

      :flush_and_stop ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
        :ok

      _ ->
        confidant_stream_collector_loop(answer_buf, thinking_buf)
    after
      120_000 ->
        StreamBuffer.flush(answer_buf)
        ThinkingBuffer.flush(thinking_buf)
    end
  end

  # ─── Assistant pipeline ─────────────────────────────────────────────────
  #
  # The conversational session sees the stored user message (which already
  # contains `📎 workspace/<name>` lines for any attachment — inlined at
  # /agent/chat entry) and decides what to do turn-by-turn. It does NOT
  # receive inline image bytes — pixels come via `extract_content` when
  # the model decides to read a particular attachment.

  # ─── Assistant pipeline — conversational session turn ─────────────
  #
  # One LLM handles the whole conversation: sees the task list + history +
  # current input and decides what to do turn-by-turn. No plan/exec/signal
  # protocol, no classifier/loop split.

  @doc false
  # Public for unit testing in `itgr_pivot_two_chains.exs`. Not part
  # of the module's user-facing API; subject to change without notice.
  #
  # Direct synchronous entry point for chain-driver tests. Skips the
  # GenServer + `dispatch_run` plumbing so tests don't have to orchestrate
  # `current_task` watch + `auto_resume_assistant` messages. Production
  # callers still go through `dispatch_assistant/2`.
  def run_for_test(%AssistantCommand{} = command, user_id, session_data) when is_binary(user_id) do
    state = %__MODULE__{user_id: user_id}
    run_assistant(command, state, session_data)
  end

  defp run_assistant(%AssistantCommand{session_id: session_id} = command, state, session_data) do
    user_id = state.user_id
    model   = AgentSettings.assistant_model()
    profile = load_user_profile(user_id)
    email   = Tasks.lookup_user_email(user_id)

    active_tasks = Tasks.active_for_session(session_id)
    recent_done  = Tasks.recent_done_for_session(session_id)

    # Resolve the active-task anchor at chain start. Mutates during
    # the chain via `maybe_mutate_anchor/4` inside `execute_tools`:
    # pickup_task pushes the prior anchor as the picked-up task's
    # `back_to_when_done_task_num`; complete / cancel / pause of the
    # current anchor flips back to that stored back-reference. Drives
    # persisted-message tagging AND gets refreshed into the prompt's
    # `## Active task` block at the next turn boundary. See
    # architecture.md §Anchor mutation via back_to_when_done back-stack.
    #
    # Resolved BEFORE `build_assistant_messages` so the chain-start
    # anchor can be passed in for the conservative-token-saving
    # filter — that filter needs the anchor to decide which tagged
    # messages to drop.
    anchor = DmhAi.Agent.Anchor.resolve(session_id)
    anchor_task_num = anchor && anchor.task_num

    llm_messages =
      ContextEngine.build_assistant_messages(session_data,
        user_id:         user_id,
        profile:         profile,
        active_tasks:    active_tasks,
        recent_done:     recent_done,
        files:           command.files,
        timezone:        command.timezone,
        local_date:      command.local_date,
        # Pass the chain-start anchor so the conservative-token-saving
        # filter can drop persisted messages tagged with other tasks
        # at chain start. nil = free-mode → filter is a no-op.
        anchor_task_num: anchor_task_num
      )

    data_dir      = DmhAi.Constants.session_data_dir(email, session_id)
    workspace_dir = DmhAi.Constants.session_workspace_dir(email, session_id)
    File.mkdir_p(data_dir)
    File.mkdir_p(workspace_dir)

    # Snapshot the set of `📎 [newly attached]` paths injected by
    # ContextEngine into the current chain's latest user message.
    # Police's check_fresh_attachments_read/2 uses this at the text
    # turn (chain end) to enforce that each fresh attachment was
    # actually extract_content'd during this chain.
    fresh_attachment_paths = DmhAi.Agent.Police.extract_fresh_attachment_paths(llm_messages)

    ctx = %{
      user_id:       user_id,
      user_email:    email,
      user_role:     Tasks.lookup_user_role(user_id),
      session_id:    session_id,
      session_root:  DmhAi.Constants.session_root(email, session_id),
      data_dir:      data_dir,
      workspace_dir: workspace_dir,
      keystore_dir:  DmhAi.Constants.user_keystore_dir(email),
      log_trace:     AgentSettings.log_trace(),
      fresh_attachment_paths: fresh_attachment_paths,
      # Snapshot the initial message count so the duplicate-tool-call
      # police check can slice `messages[chain_start_idx..]` and see only
      # the in-chain accumulator — never cross-chain repeats.
      chain_start_idx: length(llm_messages),
      anchor_task_num: anchor_task_num,
      # Track the anchor value most recently rendered into the prompt's
      # `## Active task` block. Starts equal to the chain-start anchor
      # (ContextEngine already emitted that block). When
      # `anchor_task_num` diverges — because a pickup / complete /
      # cancel / pause inside this chain mutated it —
      # `session_chain_loop` appends a refresh block before the NEXT
      # LLM call and syncs this field, keeping the prompt-side anchor
      # coherent with the runtime ctx.
      last_rendered_anchor_task_num: anchor_task_num,
      # Per-call task_num attribution — see periodic-pickup branch above
      # for the full rationale; same field, same downstream consumer
      # (`save_tools_result_of_chain` at chain end).
      tool_call_task_nums: %{},
      # Model-behaviour telemetry inputs — every Police rejection bumps a
      # counter row for this (role, model, issue_type, tool_name).
      role:          "assistant",
      model:         model
    }

    DmhAi.SysLog.log("[ASSISTANT] user=#{user_id} session=#{session_id} msg=#{String.slice(command.content, 0, 200)} fresh_attachments=#{inspect(fresh_attachment_paths)} anchor=#{inspect(anchor_task_num)}")

    # Fire the Swift classifier in parallel with the chain so its
    # latency overlaps the first assistant LLM call. Skipped when no
    # anchor is set (RELATED/UNRELATED would be meaningless), and
    # also when the anchor's task_spec can't be resolved (e.g. the
    # anchored row was deleted between resolve and dispatch — soft
    # fail). The verdict is awaited lazily inside Police's pivot
    # gate. If no gate ever awaits it (e.g. the model only emitted
    # exempt verbs, or went text-only on a fast LLM), the Task is
    # left running on its own — its body is bounded by `LLM.call`'s
    # HTTP timeout and `Task.Supervisor` reaps it on exit. The
    # pending-pivot stash side effect inside `maybe_start_swift/3`
    # MUST be allowed to complete on `:unrelated` chains; killing
    # the Task at chain end races that write and strands the user.
    # See the cleanup block below for the full rationale.
    {swift_task, _anchor_task_spec} = maybe_start_swift(anchor, command.content, ctx)

    ctx = Map.put(ctx, :swift_task, swift_task)

    # Mark the chain as in-flight so /poll exposes it to the FE; the
    # FE's pollTurnToCompletion uses this to avoid tearing down the
    # streaming placeholder on intermediate-text turns. See
    # architecture.md §Polling-based delivery.
    DmhAi.Agent.ChainInFlight.set(session_id)

    result =
      try do
        session_chain_loop(llm_messages, model, ctx, 0)
      after
        DmhAi.Agent.ChainInFlight.clear(session_id)
      end

    # Do NOT kill the Swift Task here even if it's still running. Its
    # body has a load-bearing side effect — when the verdict resolves
    # to `:unrelated`, it writes the user's pivot message to
    # `PendingPivots`, which the NEXT chain's `do_auto_create_task`
    # reads to synthesise an auto-pivot `create_task`. A brutal_kill
    # at chain end races that write whenever the chain finished
    # without ever awaiting Swift via Police's gate (e.g. the model
    # only emitted exempt verbs like `pause_task`, or went text-only
    # on a fast LLM). Killing wins → stash never written → user types
    # "pause it" → no auto-pivot → user frozen.
    #
    # Letting Swift outlive the chain is safe:
    #   * `Task.Supervisor.async_nolink/2` is unlinked, so the chain
    #     Task's exit doesn't propagate.
    #   * The Task body is bounded by `LLM.call`'s HTTP timeout —
    #     can't run forever.
    #   * The `{ref, result}` message is destined for the chain Task's
    #     mailbox, which is gone by the time Swift completes; the
    #     unread message is GC'd with the dead mailbox. No leak.
    #   * `DmhAi.Agent.TaskSupervisor` reaps the process on exit.
    #
    # See architecture.md §Auto-pivot stash for the full chain.

    Task.start(fn ->
      maybe_compact(session_id, user_id)
      ProfileExtractor.extract_and_merge(user_id)
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
  # Returns `{:chain_done, watermark_ts, auto_pivot?}` from every
  # terminal branch. `watermark_ts` is the max user-ts in the final
  # messages list the chain worked with — i.e. the highest user-message
  # ts the chain's LLM calls actually saw. The GenServer's chain-complete
  # hook uses it against DB state to detect "a new user message arrived
  # AFTER the chain had finished consuming input" and needs an auto-resume.
  # `auto_pivot?` is `true` ONLY on the close-verb branch when the chain
  # synthesised a `create_task` for a stashed pivot — that flag tells the
  # GenServer to fire `:auto_resume_assistant` directly even though no
  # new user message arrived.
  defp session_chain_loop(messages, model, ctx, turn) do
    max_turns = AgentSettings.max_assistant_turns_per_chain()

    # Mid-chain splice: fold any user messages that were persisted to
    # `session.messages` after this chain started (or after the
    # previous turn's LLM call returned) into the working messages
    # list, so the next turn's LLM call sees them as context. Safe
    # here because we're between turns; any prior tool_call /
    # tool_result pair has already been paired up, so OpenAI's
    # sequencing rule isn't violated.
    messages = splice_mid_chain_user_msgs(messages, ctx)

    # Anchor refresh: if the runtime anchor has moved from what the
    # prompt currently says (because a pickup / complete / cancel /
    # pause in a prior turn of THIS chain mutated it), append a
    # refreshed `## Active task` block so the next LLM call sees the
    # updated value. Keeps prompt-side anchor coherent with the
    # runtime ctx. See architecture.md §Anchor mutation.
    {messages, ctx} = maybe_refresh_anchor_block(messages, ctx)

    # User-initiated chain cancellation: if the anchor task's
    # task_status flipped to "cancelled" since the last turn (typically
    # because the user clicked the sidebar Stop button → POST
    # /tasks/:task_id/cancel → Tasks.mark_cancelled/2), end the chain
    # here. The DB row is the truth-source — no GenServer signal, no
    # message-text parsing. We append a `kind="chain_aborted"`
    # session_progress row as the FE-visible chain-end signal (rendered
    # as a small status line, not a fabricated assistant message), clear
    # the stream buffer, and return like any normal completion. See
    # architecture.md §User-initiated chain cancellation.
    if anchor_task_cancelled?(ctx) do
      _ = StreamBuffer.clear(ctx.session_id, ctx.user_id)
      _ = ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
      progress_ctx = %{
        session_id: ctx.session_id,
        user_id:    ctx.user_id,
        task_id:    anchor_task_id_from_ctx(ctx)
      }
      {:ok, _} = DmhAi.Agent.SessionProgress.append(
        progress_ctx, "chain_aborted", "Stopped by user.")
      {:chain_done, max_user_ts_in_messages(messages), false}
    else

    if turn >= max_turns do
      msg = DmhAi.I18n.t("turn_cap_reached", "en", %{max: max_turns})
      cap_msg = maybe_tag_task_num(%{role: "assistant", content: msg}, ctx)
      {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, cap_msg)
      {:chain_done, max_user_ts_in_messages(messages), false}
    else
      tools = DmhAi.Tools.Registry.all_definitions(ctx.user_id, anchor_task_id_from_ctx(ctx))

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
      collector = spawn_assistant_stream_collector(ctx.session_id, ctx.user_id)
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
          DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} tool_calls=[#{call_names}]")

          # Capture any narration the model streamed before emitting
          # tool_calls ("Let me search for that first…"). Persisting it
          # fixes the "half-rendered reasoning, rest renders after tool
          # finishes" visual glitch: without persistence, FE saw partial
          # text in stream_buffer, then the clear wiped it, then the
          # NEXT turn's fresh narration filled the buffer and the FE
          # perceived it as a continuation. Persisting makes the
          # narration a permanent part of the chat timeline.
          #
          # EXCEPTION: when this turn's tool_calls include a CLOSE verb
          # (complete_task / cancel_task / pause_task), skip
          # persistence. Models tend to write the user-facing
          # conclusion right before closing — then re-write the same
          # conclusion as final text on the next turn, producing two
          # near-identical assistant bubbles. Suppressing here drops
          # the duplicate; the close-verb's progress row plus the next
          # turn's final text together convey the same information.
          # Mid-chain narrations before non-closing tools (run_script,
          # web_fetch, extract_content, etc.) still persist normally so
          # the "tries X, fails, explains, tries Y" flow is preserved.
          raw_narration  = StreamBuffer.read(ctx.session_id, ctx.user_id)
          clean_narration = DmhAi.Agent.TextSanitizer.strip_task_bookkeeping(raw_narration)
          StreamBuffer.clear(ctx.session_id, ctx.user_id)
          ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

          closes_chain? = Enum.any?(calls, fn c ->
            (get_in(c, ["function", "name"]) || "") in ~w(complete_task cancel_task pause_task)
          end)

          # Chain-terminating-with-form tools: `request_input` always
          # emits a form; `connect_mcp` may emit one (the
          # `needs_setup` branch). Suppress separate narration
          # persistence for both — when a form lands in the tool
          # results, the narration rides on the form-bearing assistant
          # message; when no form lands (e.g. `connect_mcp` returns
          # `needs_auth` or `connected`), the chain recurses and the
          # narration sits in the in-memory `assistant_msg` for the
          # next LLM call without being shown to the user.
          may_emit_form? = Enum.any?(calls, fn c ->
            (get_in(c, ["function", "name"]) || "") in ~w(request_input connect_mcp)
          end)

          if String.trim(clean_narration) != "" and not closes_chain? and not may_emit_form? do
            DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} narration(#{String.length(clean_narration)} chars) persisted")

            narration_msg = %{role: "assistant", content: clean_narration}
            narration_msg = maybe_tag_task_num(narration_msg, ctx)

            {:ok, _} =
              append_session_message(ctx.session_id, ctx.user_id, narration_msg)
          end

          # In-memory assistant_msg carries the narration in its `content`
          # so subsequent LLM calls in this chain see the model's own
          # reasoning alongside its tool_calls — without it the LLM
          # would lose track of why it picked a particular tool.
          # Capture the pre-call anchor so the conservative-token-saving
          # mid-chain refilter (below) can detect anchor flips.
          prev_anchor_task_num = Map.get(ctx, :anchor_task_num)
          {tool_result_msgs_raw, tagged_calls, ctx} = execute_tools(calls, messages, ctx)
          assistant_msg = %{role: "assistant", content: clean_narration, tool_calls: tagged_calls}

          # Tally any tagged Police rejections from this turn and bump
          # the matching nudge counters. Returns the cleaned messages
          # with the internal `[[ISSUE:...]]` marker stripped so the
          # model just sees the nudge prose.
          {ctx, tool_result_msgs} = bump_nudge_counters(ctx, tool_result_msgs_raw)

          form = if may_emit_form?, do: extract_form_from_results(tool_result_msgs), else: nil

          # Close-verb chain termination (Y rule). Detect successful close-verb
          # tool calls (Police-rejected ones don't count). The chain ends right
          # here — next user (or auto_resume) chain starts with a clean
          # tool_history because the verb's `mark_*` already flushed the
          # closed task's entries to task_chain_archive.
          #
          #   pause_task / cancel_task → end immediately. Persist any
          #     narration as the final assistant message (an explicit
          #     acknowledgment from the model). If auto-pivot synthesised
          #     a create_task as a side-effect, fire :auto_resume_assistant
          #     so a fresh chain spawns to work on the new task with
          #     clean context.
          #
          #   complete_task with NON-empty narration → end immediately.
          #     The narration IS the answer (Y rule trusts what the model
          #     wrote alongside the close-verb).
          #
          #   complete_task with EMPTY narration → fall through to normal
          #     recursion. The next LLM turn delivers the answer; chain
          #     ends naturally when the model emits no tool_calls. This is
          #     the only case under Y where a complete_task chain pays
          #     one extra LLM call — paid on the delivery turn.
          successful_close_verbs = successful_close_verbs(tagged_calls)
          close_terminates_chain? = close_verbs_terminate_chain?(successful_close_verbs, clean_narration)

          cond do
            form != nil ->
              # Persist a single assistant message carrying both the
              # narration (the prompt text shown above the form) and
              # the form spec extracted from the tool result. End the
              # chain. The next chain — auto-resumed when the user
              # submits — picks up either the synthesised user-role
              # message (request_input) or the service_connected
              # message (connect_mcp api_key submission).
              #
              # Inject a placeholder when the model's narration was
              # empty: an assistant message with `content: ""` and no
              # `tool_calls` slot is invalid input to most chat-
              # completion APIs (Ollama rejects with "Assistant
              # message must have either content or tool_calls"),
              # which would crash the next chain when this message
              # gets replayed as context.
              content =
                case String.trim(clean_narration) do
                  "" -> fallback_content_for_form(form)
                  s  -> s
                end

              msg = %{role: "assistant", content: content, form: form}
              msg = maybe_tag_task_num(msg, ctx)
              {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, msg)
              DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} form persisted (kind=#{form["kind"] || "request_input"} token=#{form["token"] || form[:token]})")

              {:chain_done, max_user_ts_in_messages(messages), false}

            close_terminates_chain? ->
              # Persist whatever narration the model wrote alongside the
              # close-verb (Y rule: trust it as the answer / acknowledgment).
              # `clean_narration` may be empty for pause/cancel — that's OK,
              # the progress row already shows the verb fired.
              final_assistant_ts =
                if String.trim(clean_narration) != "" do
                  msg = maybe_tag_task_num(%{role: "assistant", content: clean_narration}, ctx)
                  case append_session_message(ctx.session_id, ctx.user_id, msg) do
                    {:ok, ts} -> ts
                    _         -> System.os_time(:millisecond)
                  end
                else
                  System.os_time(:millisecond)
                end

              StreamBuffer.clear(ctx.session_id, ctx.user_id)
              ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

              finalise_chain_tool_history(messages, ctx, final_assistant_ts, clean_narration)

              # If pause/cancel triggered the auto-pivot's synthetic
              # `create_task`, signal it to the GenServer's chain-complete
              # hook via the return tuple. The hook routes the next chain
              # through the silent-pickup path (NOT a normal user-message
              # auto-resume), because the trailing user-role message in
              # session.messages was the runtime trigger for the pivot
              # and has already been consumed — replaying it as a fresh
              # ask would make the model close-verb the freshly-created
              # task. The silent-pickup path appends a synthetic kicker
              # naming the new task as the directive, overriding the
              # trailing chat tail.
              #
              # The new task's id rides along in the tuple so the GenServer
              # can `Tasks.get(task_id)` without re-deriving from session
              # state. After auto-pivot fires, `execute_tools` has already
              # called `maybe_mutate_anchor("create_task", ...)` for the
              # synthesised create_task, so `ctx.anchor_task_num` points
              # at the freshly-created task. We resolve the row id via
              # `anchor_task_id_from_ctx/1` (the same derived-getter the
              # rest of the codebase uses — `:anchor_task_id` is NOT a
              # stored ctx field). DB resolves at this hop are cheap;
              # caching the id in ctx would be a separate refactor.
              #
              # The signal MUST flow through the return tuple, not via
              # `send(self(), ...)` from inside the chain Task — `self()`
              # here is the Task pid (spawned by `dispatch_run`), not the
              # GenServer, so a direct send lands in the dying Task's
              # mailbox and is silently lost. See the
              # `handle_info({ref, result}, ...)` callback for how the
              # GenServer turns this flag into an auto-resume.
              auto_pivot_signal =
                if auto_pivot_fired?(tagged_calls) do
                  {:auto_pivot, anchor_task_id_from_ctx(ctx)}
                else
                  false
                end

              DmhAi.SysLog.log(
                "[ASSISTANT] turn=#{turn} chain ends on close-verb " <>
                  "#{inspect(successful_close_verbs)} (narration_chars=#{String.length(clean_narration)}, " <>
                  "auto_pivot=#{inspect(auto_pivot_signal)})"
              )

              {:chain_done, max_user_ts_in_messages(messages), auto_pivot_signal}

            true ->
              case maybe_abort_on_model_behavior_issue(ctx, model) do
                :continue ->
                  new_messages = messages ++ [assistant_msg] ++ tool_result_msgs

                  # Mid-chain conservative-token-saving refilter. When
                  # the user opted in AND the anchor just flipped to a
                  # different non-nil task (create_task or pickup_task
                  # success), drop persisted messages tagged with other
                  # task_nums from the in-memory list. The freshly-
                  # created task starts its first turn with clean
                  # context. Closing verbs that flip anchor → nil are a
                  # no-op here so follow-up questions on the just-
                  # closed task retain its messages. See
                  # specs/architecture.md §Conservative token saving.
                  new_messages =
                    maybe_conservative_refilter(
                      new_messages, ctx, prev_anchor_task_num)

                  session_chain_loop(new_messages, model, ctx, turn + 1)

                :aborted ->
                  {:chain_done, max_user_ts_in_messages(messages), false}
              end
          end

        {:ok, text} when is_binary(text) and text != "" ->
          case DmhAi.Agent.Police.check_assistant_text(text) do
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

              DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} rejected text='#{String.slice(text, 0, 80)}' — nudging for retry")
              StreamBuffer.clear(ctx.session_id, ctx.user_id)
              ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

              # Record telemetry + bump nudge counter for this non-tool issue.
              ctx = record_non_tool_issue(ctx, issue_atom)

              new_messages =
                messages ++ [
                  %{role: "assistant", content: text},
                  %{role: "user",      content: wrap_runtime_correction(reason)}
                ]

              case maybe_abort_on_model_behavior_issue(ctx, model) do
                :continue -> session_chain_loop(new_messages, model, ctx, turn + 1)
                :aborted  -> {:chain_done, max_user_ts_in_messages(messages), false}
              end

            :ok ->
              # Before accepting the final text, enforce that every
              # `📎 [newly attached]` path in the current turn's user
              # message was passed to `extract_content` at some point
              # during this turn. Catches the "model acknowledges the
              # attachment in prose but never actually reads it" failure.
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
                    :continue -> session_chain_loop(new_messages, model, ctx, turn + 1)
                    :aborted  -> {:chain_done, max_user_ts_in_messages(messages), false}
                  end

                :ok ->
                  # Strip tool-call bookkeeping annotations the model may
                  # have tacked on to its answer ("[used: complete_task(…)]",
                  # "[via: web_search]", etc.). Police already rejected
                  # flagrant cases at stream-end; this is the belt-and-
                  # braces strip for anything that slipped through.
                  clean_text = DmhAi.Agent.TextSanitizer.strip_task_bookkeeping(text)
                  if clean_text != text do
                    Logger.info("[UserAgent] stripped task-bookkeeping (#{String.length(text) - String.length(clean_text)} chars) from assistant text at persistence")
                  end
                  DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} text(#{String.length(clean_text)} chars)")
                  # Capture the streamed thinking text and pin it to
                  # the persisted assistant message so the static
                  # `<details>` block in `buildMessageEntryNode` has
                  # the same content the user just saw streaming.
                  thinking_text = ThinkingBuffer.read(ctx.session_id, ctx.user_id)
                  base_msg = %{role: "assistant", content: clean_text}
                  base_msg = if thinking_text != "",
                                do: Map.put(base_msg, :thinking, thinking_text),
                                else: base_msg
                  final_msg = maybe_tag_task_num(base_msg, ctx)
                  {:ok, assistant_ts} =
                    append_session_message(ctx.session_id, ctx.user_id, final_msg)
                  # Stream buffer had the progressive text; clear it now that
                  # the permanent message is persisted, so the FE's streaming
                  # placeholder gives way to the real message on next poll.
                  StreamBuffer.clear(ctx.session_id, ctx.user_id)
                  ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
                  # Snapshot this chain's tool_call/tool_result messages
                  # into the session's rolling tool-history window so the
                  # NEXT chain's context builder can inject them back and
                  # answer immediate follow-ups without re-running tools.
                  #
                  # The chain's pairs are pre-split per task_num before
                  # save (see `group_pairs_by_task_num/2`), so a chain
                  # that spans multiple tasks (e.g. cancel→auto-create)
                  # produces ONE tool_history entry per task. That makes
                  # `flush_for_task(N)` evict cleanly when N closes —
                  # without per-call attribution, mid-chain anchor
                  # transitions left chain-end task_num=nil orphans that
                  # never flushed.
                  #
                  # IMPORTANT: slice by `chain_start_idx` FIRST. `messages`
                  # at this point contains (a) the tool_history re-injected
                  # from prior chains by `ContextEngine.build_assistant_messages`
                  # PLUS (b) this chain's own new tool_calls. Without the
                  # slice, `collect_tool_messages` would capture (a) too,
                  # and subsequent entries would accumulate prior-chain
                  # history — causing messages to appear duplicated in
                  # future context builds. The slice ensures one chain's
                  # entries contain only THAT chain's work.
                  # `chain_start_idx` is the length of `llm_messages`
                  # captured when `run_assistant` (or
                  # `run_assistant_silent`) entered the loop — everything
                  # after index is what this chain produced.
                  finalise_chain_tool_history(messages, ctx, assistant_ts, clean_text)

                  {:chain_done, max_user_ts_in_messages(messages), false}
              end
          end

        {:ok, ""} ->
          DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} empty response — no message persisted")
          StreamBuffer.clear(ctx.session_id, ctx.user_id)
          ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
          {:chain_done, max_user_ts_in_messages(messages), false}

        {:error, reason} ->
          DmhAi.SysLog.log("[ASSISTANT] turn=#{turn} ERROR: #{inspect(reason)}")
          StreamBuffer.clear(ctx.session_id, ctx.user_id)
          ThinkingBuffer.clear(ctx.session_id, ctx.user_id)

          # Classify the error. Transient infra issues (API-key
          # exhaustion, rate-limits, provider 5xx, timeouts) are
          # treated as a SYSTEM-ERROR class — the runtime auto-pauses
          # the active task so the user's work is preserved, and
          # surfaces a localised, non-jargon message asking them to
          # ping when resolved. Everything else falls back to the
          # generic `llm_error` render.
          err_msg_payload =
            case classify_llm_error(reason) do
              {:system_error, cause_key} ->
                build_system_error_reply(ctx, cause_key)

              :generic ->
                %{role: "assistant",
                  content: DmhAi.I18n.t("llm_error", "en", %{reason: inspect(reason)})}
            end

          err_msg = maybe_tag_task_num(err_msg_payload, ctx)
          {:ok, _} = append_session_message(ctx.session_id, ctx.user_id, err_msg)
          {:chain_done, max_user_ts_in_messages(messages), false}
      end
    end
    end
  end

  # Decide whether an LLM-error reason is a SYSTEM-class failure
  # (transient infra we can't self-recover from — user needs to fix
  # something upstream) vs. a generic error (surface as-is). Returns
  # `{:system_error, i18n_cause_key}` or `:generic`. The cause_key
  # drives the humanised phrase inserted into the user-facing message.
  # See architecture.md §Error handling + `DmhAi.I18n` keys starting
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
    reason_phrase = DmhAi.I18n.t(cause_key, lang)

    case Map.get(ctx, :anchor_task_num) do
      n when is_integer(n) ->
        auto_pause_active_task(ctx, n)

        content = DmhAi.I18n.t("system_error_paused", lang, %{
          reason: reason_phrase, task_num: n})

        %{role: "assistant", content: content}

      _ ->
        content = DmhAi.I18n.t("system_error_no_active_task", lang, %{
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
      DmhAi.SysLog.log("[ASSISTANT] auto-paused task (#{task_num}) due to system error")
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

  # Tag an assistant message with the chain's anchor `task_num` when
  # one is set. Called at every `append_session_message` site in
  # `session_chain_loop` so archived slices can be partitioned
  # per-task by `ContextEngine.compact!`. Free-mode chains (no anchor)
  # leave the message untagged — they compact into the master session
  # summary like any pure-chat exchange. See architecture.md
  # §Per-message task tag.
  defp maybe_tag_task_num(message, ctx) do
    case Map.get(ctx, :anchor_task_num) do
      n when is_integer(n) -> Map.put(message, :task_num, n)
      _                     -> message
    end
  end

  # Pull the `form` spec out of a `request_input` call's tool result.
  # The tool returns `{:ok, %{token, expires_at, form}}`; the runtime
  # JSON-encodes that into the tool message's content. Match the
  # tool_call by name + id, decode its tool_result, return the `form`
  # Look at every tool result in the batch and return the first one
  # whose JSON-encoded content carries a top-level `"form"` field.
  # Tool-name-agnostic — works for both `request_input` (always
  # form-bearing) and `connect_mcp` (form-bearing only on the
  # `needs_setup` branch). Returns the form map (string keys) ready
  # for embedding in `session.messages`, or `nil` when no result in
  # the batch carried a form.
  defp extract_form_from_results(tool_result_msgs) do
    Enum.find_value(tool_result_msgs, fn m ->
      decode_form_from_content(m[:content] || m["content"])
    end)
  end

  defp decode_form_from_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"form" => form}} when is_map(form) -> form
      _                                            -> nil
    end
  end

  defp decode_form_from_content(_), do: nil

  # Conservative-token-saving mid-chain refilter. Fires once per
  # `session_chain_loop` iteration AFTER `execute_tools` returns,
  # checking whether the anchor just flipped to a different non-nil
  # task. When it has AND the user opted into the toggle, drop
  # persisted messages tagged with `task_num != new_anchor` from the
  # in-memory list. In-chain pairs (assistant tool_calls, tool
  # results) carry no `task_num` field at the message level so they
  # always survive — `tool_call_task_nums` attribution is on the call
  # id, not the message map.
  #
  # The filter is a NO-OP when:
  #   * User has not opted in (default).
  #   * Anchor is unchanged (no transition).
  #   * Anchor flipped to nil (close-verb without back-ref) — preserves
  #     the just-closed task's messages so follow-up questions still
  #     have context.
  #   * Anchor flipped from nil to a value (rare — happens mid-chain
  #     after `create_task` from free mode). The chain-start build
  #     also runs the filter, so this case is handled there too; we
  #     re-apply here for the inline-create scenario where the
  #     chain-start anchor was nil.
  defp maybe_conservative_refilter(messages, ctx, prev_anchor_task_num) do
    new_anchor = Map.get(ctx, :anchor_task_num)
    user_id    = Map.get(ctx, :user_id)

    cond do
      not is_binary(user_id) ->
        messages

      not is_integer(new_anchor) ->
        messages

      new_anchor == prev_anchor_task_num ->
        messages

      not DmhAi.Auth.UserPreferences.conservative_token_saving?(user_id) ->
        messages

      true ->
        DmhAi.Agent.ContextEngine.filter_other_tasks(messages, new_anchor)
    end
  end

  # Resolve the chain's anchor task to its internal task_id (UUID) so
  # downstream callers (Tools.Registry, Police, MCP.Registry.attach)
  # can key on the stable identifier. `nil` when no anchor task is
  # active — those callers treat that as "no task scope".
  defp anchor_task_id_from_ctx(%{} = ctx) do
    session_id = Map.get(ctx, :session_id)
    n          = Map.get(ctx, :anchor_task_num)

    cond do
      not (is_binary(session_id) and is_integer(n)) ->
        nil

      true ->
        case Tasks.resolve_num(session_id, n) do
          {:ok, task_id} -> task_id
          _              -> nil
        end
    end
  end

  # User-initiated chain cancellation: the sidebar Stop button POSTs
  # `/tasks/:task_id/cancel` which flips `task_status` to `cancelled`.
  # `session_chain_loop` calls this at the top of every turn iteration to
  # decide whether to keep going. DB row is the truth-source. Returns
  # false when there's no anchor (no chain to cancel) or the task is
  # still ongoing/paused/done. See architecture.md
  # §User-initiated chain cancellation.
  defp anchor_task_cancelled?(%{} = ctx) do
    case anchor_task_id_from_ctx(ctx) do
      nil -> false
      task_id ->
        case Tasks.get(task_id) do
          %{task_status: "cancelled"} -> true
          _                            -> false
        end
    end
  end

  defp fallback_content_for_form(form) when is_map(form) do
    case form["kind"] || form[:kind] do
      "connect_mcp_setup" -> "Setting up the connection — please fill in the form below."
      _                        -> "Please fill in the form below."
    end
  end

  defp fallback_content_for_form(_), do: "Please fill in the form below."

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

  # Slice the chain's tool messages, partition into call blocks, group
  # by per-call task_num, persist via `ToolHistory.save_tools_result_of_chain`,
  # and run the periodic auto-close sweep. Called from every chain-end
  # path (close-verb termination + text-only-final-turn).
  #
  # `final_text` feeds `auto_close_ongoing_tasks` as the task_result for
  # any periodic task the model worked on but forgot to close.
  defp finalise_chain_tool_history(messages, ctx, assistant_ts, final_text) do
    tool_msgs =
      messages
      |> Enum.drop(ctx.chain_start_idx)
      |> collect_tool_messages()

    groups =
      tool_msgs
      |> DmhAi.Agent.ToolMessageGrouper.partition_into_call_blocks()
      |> DmhAi.Agent.ToolMessageGrouper.group_blocks_by_task_num(
        Map.get(ctx, :tool_call_task_nums, %{})
      )

    DmhAi.Agent.ToolHistory.save_tools_result_of_chain(
      ctx.session_id, ctx.user_id, assistant_ts, groups
    )

    # Runtime auto-close: if the model worked on any periodic task this
    # turn but forgot to call `complete_task`, close them now using the
    # final answer as task_result. One_off tasks intentionally NOT swept
    # — the user's `<task_completion>` rule says they may legitimately
    # span multiple chains (e.g. clarifying-question pauses).
    auto_close_ongoing_tasks(ctx.session_id, final_text)
    :ok
  end

  # ── close-verb chain termination helpers (Y rule) ─────────────────────

  @close_verbs ~w(complete_task cancel_task pause_task)

  # List the close-verbs from `tagged_calls` that ran successfully (i.e.
  # weren't stamped with `_rejected: true` by Police). Returns a list of
  # tool-call name strings; empty list when no close-verb ran or all
  # were rejected.
  defp successful_close_verbs(tagged_calls) when is_list(tagged_calls) do
    Enum.flat_map(tagged_calls, fn c ->
      rejected = Map.get(c, "_rejected", false)
      name = get_in(c, ["function", "name"]) || ""
      if not rejected and name in @close_verbs, do: [name], else: []
    end)
  end

  defp successful_close_verbs(_), do: []

  # Decide whether a chain should terminate immediately given which
  # close-verbs succeeded and the model's narration this turn.
  #
  #   pause_task / cancel_task in any combination → terminate (no answer
  #     to deliver; progress row carries the acknowledgment).
  #
  #   complete_task with non-empty narration → terminate (Y rule: trust
  #     the narration as the final answer).
  #
  #   complete_task with empty narration → DON'T terminate; the chain
  #     recurses for one more LLM turn so the model can deliver the
  #     answer it didn't include in the close-verb turn.
  #
  #   No close-verbs succeeded → don't terminate.
  defp close_verbs_terminate_chain?([], _narration), do: false

  defp close_verbs_terminate_chain?(verbs, narration) when is_list(verbs) do
    has_pause_or_cancel? =
      Enum.any?(verbs, &(&1 in ["pause_task", "cancel_task"]))

    has_complete? = "complete_task" in verbs
    narration_non_empty? = String.trim(narration || "") != ""

    cond do
      has_pause_or_cancel? -> true
      has_complete? and narration_non_empty? -> true
      true -> false
    end
  end

  # Detect whether `maybe_auto_create_task/3` synthesised a `create_task`
  # in this turn — those carry a `tool_call_id` prefixed `auto_pivot_*`
  # (see `do_auto_create_task/1`). Used by the close-verb termination
  # branch to decide whether to fire `:auto_resume_assistant` so a fresh
  # chain spawns to progress the newly-created task.
  defp auto_pivot_fired?(tagged_calls) when is_list(tagged_calls) do
    Enum.any?(tagged_calls, fn c ->
      id = Map.get(c, "id") || Map.get(c, :id) || ""
      is_binary(id) and String.starts_with?(id, "auto_pivot_")
    end)
  end

  defp auto_pivot_fired?(_), do: false

  # NOTE: tool-message partitioning + per-task grouping moved to
  # `DmhAi.Agent.ToolMessageGrouper`. The old positional pair_up logic
  # silently dropped tool_results when an assistant message carried
  # >1 tool_calls (e.g. the auto-pivot's compound `cancel_task` +
  # synthesised `create_task`). The new walker matches by
  # `tool_call_id`, not position. See that module's @moduledoc.

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
            DmhAi.Agent.ModelBehaviorStats.record(role, model, atom_name, tool_name)
            cleaned = String.replace_prefix(raw, full, "")
            {Map.put(msg, :content, cleaned), new_acc}

          _ ->
            {msg, acc}
        end
      end)
      |> then(fn {msgs, acc} -> {acc, msgs} end)

    {Map.put(ctx, :nudges, nudges_after), clean_msgs}
  end

  # Wrap a Police text-rejection reason in a runtime-correction marker
  # before injecting it as a synthetic user message. The model can't
  # tell a synthetic correction apart from a real user interruption
  # by message shape alone — both arrive as `role: "user"`. The
  # marker prefix gives it an unambiguous signal so it doesn't
  # mistake the nudge for a fresh user request and reset the chain.
  #
  # Phrasing is positive ("apply and continue") and uses the system-
  # prompt's own primitive ("chain"). Negative framing (e.g. "do NOT
  # call create_task") would prime the model toward the prohibited
  # verb — attention latches onto the keyword regardless of negation.
  defp wrap_runtime_correction(reason) do
    "[ Runtime correction - Apply the below and continue your current chain ]\n\n" <> reason
  end

  # Non-tool-call Police rejections (check_assistant_text,
  # check_fresh_attachments_read) don't flow through execute_tools, so they
  # can't use the marker-in-content trick. This helper does the equivalent
  # counter bump + telemetry record inline in the text-turn handler.
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
        DmhAi.SysLog.log(
          "[CRITICAL] ModelBehaviorIssue type=#{issue} model=#{model} " <>
            "session=#{ctx.session_id} count=#{count}"
        )
        # Record the escalation as its own telemetry row ('escalated_<issue>')
        # so the admin UI can see how often each rule trips the 3-strike limit.
        DmhAi.Agent.ModelBehaviorStats.record(
          role, model, "escalated_#{issue}", "")

        user_msg = "Internal AI model error — we're investigating and working to fix. " <>
                     "Sorry for the inconvenience."
        StreamBuffer.clear(ctx.session_id, ctx.user_id)
        ThinkingBuffer.clear(ctx.session_id, ctx.user_id)
        {:ok, _} = append_session_message(ctx.session_id, ctx.user_id,
                                          %{role: "assistant", content: user_msg})
        :aborted
    end
  end

  # Auto-close runs at end of text turn (chain end). PERIODIC-ONLY —
  # one_off tasks stay `ongoing` across chains until the model
  # explicitly calls `complete_task`, which is the only reliable
  # signal that the objective is done. A one_off task may legitimately
  # span multiple chains (e.g. the assistant asks a clarifying
  # question and waits on the user's next reply), so sweeping ongoing
  # one_offs would close conversations prematurely.
  #
  # For periodic tasks, auto-close is the right thing: the pickup's
  # "done" = "reschedule next cycle", a structural event the runtime
  # owns. `Tasks.mark_done/2` dispatches periodic → pending +
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
      DmhAi.SysLog.log("[ASSISTANT] auto-closing PERIODIC pickup task=#{t.task_id} — model did not call complete_task; runtime reschedules")
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

    {pairs, {_final_prior, final_ctx}} =
      Enum.flat_map_reduce(calls, {in_chain_prior, ctx}, fn call, {prior_acc, ctx} ->
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
          with :ok <- DmhAi.Agent.Police.check_tool_known(name, ctx.user_id, anchor_task_id_from_ctx(ctx)),
               # Police gate 2 — task discipline. Silent to the user. Same
               # self-correction pattern.
               :ok <- DmhAi.Agent.Police.check_task_discipline(name, ctx, prior_acc),
               # Police gate 3 — tool-call schema compliance. Generic check
               # against the tool's own definition (required fields + types).
               # Schema-driven nudge example returned on failure.
               :ok <- DmhAi.Agent.Police.check_tool_call_schema(name, args),
               # Police gate 4 — within-chain duplicate-tool-call. Blocks
               # the "create_task twice with same title" / "extract_content
               # the same PDF twice" misbehaviour.
               :ok <- DmhAi.Agent.Police.check_no_duplicate_tool_call(name, args, prior_acc),
               # Police gate 5 — no two `web_search` calls in a row. A single
               # web_search already fans out 2-3 parallel queries in the BE,
               # so back-to-back web_searches are redundant. Catches the
               # "model spams web_search with slightly reworded queries
               # instead of digesting the first result" failure mode. The
               # nudge TEACHES the correct loop: digest → dig with a
               # different tool → re-search only if a genuine gap remains.
               :ok <- DmhAi.Agent.Police.check_no_consecutive_web_search(name, args, prior_acc),
               # Police gate 6 — `run_script` probe budget. Caps total
               # `run_script` calls per chain at AgentSettings.run_script_probe_budget()
               # (default 5). The (N+1)th run_script is rejected with a
               # nudge teaching the model to either compose the rest into
               # ONE more script OR ask the user the specific question
               # probes can't answer. Backstop for the prompt rule
               # "Three probe-batches max" in §Working with external APIs.
               :ok <- DmhAi.Agent.Police.check_run_script_probe_budget(name, args, prior_acc),
               # Police gate 7 — one periodic task per session. Rejects
               # create_task(task_type: "periodic") when the session
               # already has an active periodic. Without this a model
               # can spawn multiple periodics for one user ask, each
               # firing on its own timer → compounding silent turns.
               # The nudge is user-facing: it tells the model exactly
               # what to reply so the user sees a coherent explanation
               # naming the existing task's (N).
               :ok <- DmhAi.Agent.Police.check_no_duplicate_periodic_task_in_session(name, args, ctx),
               # Police gate 7 — silent-turn scope lock. During a
               # scheduler-triggered silent pickup (ctx carries
               # :silent_turn_task_id), forbid create_task and the
               # pickup / complete / pause / cancel verbs on any task
               # OTHER than the triggered one. A pickup fires for ONE
               # specific task; the model must not use that trigger as
               # license to spawn new tasks or touch unrelated ones.
               :ok <- DmhAi.Agent.Police.check_silent_turn_scope(name, args, ctx),
               # Police gate 8 — Oracle-backed anchor pivot / knowledge
               # check. A small classifier model runs in parallel with
               # the assistant LLM at chain start; this gate consults
               # its verdict. UNRELATED tool calls are rejected with a
               # nudge to confirm the pivot first AND stash the user's
               # pivot message in `PendingPivots` so a later
               # `pause_task` / `cancel_task` triggers `maybe_auto_create_task`
               # which synthesises the new `create_task` from the
               # stashed message. KNOWLEDGE-class messages are
               # rejected for ALL tools — those should be answered in
               # plain text from training. RELATED passes through.
               :ok <- DmhAi.Agent.Police.check_pivot(name, args, ctx),
               # Police gate 9 — one ongoing one_off task per session.
               # Mirror image of the single-periodic gate (gate 6).
               # Rejects a new `create_task` (default `task_type:
               # "one_off"`) when the session already has an ONGOING
               # one_off task — but ONLY for the residual case where
               # the Swift pivot gate above didn't already catch it
               # (i.e. Swift classified RELATED yet the model still
               # tried to branch off a second task). The pivot gate's
               # auto-pivot path (stash → user confirms with pause/
               # cancel → synthetic create_task) is the canonical
               # branching flow; this gate just nudges the model to
               # ask the user when neither path applied.
               #
               # ORDERING IS LOAD-BEARING: this gate MUST run AFTER
               # `check_pivot`. If it ran first on a UNRELATED message,
               # the pivot stash would never be written and the
               # subsequent pause/cancel would have nothing to auto-
               # create from — leaving the user stranded after they
               # said "pause it" with no follow-up chain spawned.
               :ok <- DmhAi.Agent.Police.check_no_duplicate_one_off_task_in_session(name, args, ctx) do
            progress_label = DmhAi.Agent.ProgressLabel.format(name, args)
            # `complete_task` is pure cleanup — the final assistant
            # message IS the completion event from the user's
            # perspective. Hide the row so it doesn't appear as noise
            # before the final answer renders. Other verbs (pickup /
            # pause / cancel) stay visible so the user sees state
            # transitions happen in the chat timeline.
            hide_row = name == "complete_task"
            {:ok, row} = DmhAi.Agent.SessionProgress.append(progress_ctx, "tool", progress_label,
                                                            status: "pending", hidden: hide_row)

            args_log = args |> Jason.encode!() |> String.slice(0, 600)
            DmhAi.SysLog.log("[ASSISTANT] tool=#{name} args=#{args_log}")
            # Thread the progress row id AND the tool_call_id through
            # ctx so:
            #   • tools with parallel internals (web_search, OCR extract)
            #     can stream sub-activity labels into
            #     session_progress.sub_labels for the FE to rotate.
            #   • long-running tools (`run_script`) can register
            #     themselves in `DmhAi.Agent.RunningTools` keyed by
            #     {session_id, tool_call_id} so the `/poll` handler
            #     surfaces an in-flight marker. See architecture.md
            #     §Long-running tool execution.
            tool_ctx =
              ctx
              |> Map.put(:progress_row_id, row.id)
              |> Map.put(:tool_call_id, tool_call_id)

            exec_started_ms = System.system_time(:millisecond)
            exec_result = DmhAi.Tools.Registry.execute(name, args, tool_ctx)
            duration_ms = System.system_time(:millisecond) - exec_started_ms

            # Trace the tool execution (gated on the same `logTrace`
            # admin setting that traces LLM calls). Captures the
            # exact `{name, args, result, duration}` so operators can
            # debug "model emitted X → got Y" without grepping for it
            # in the next LLM call's message history.
            if DmhAi.Agent.AgentSettings.log_trace() do
              DmhAi.Agent.LogTrace.write_tool(
                %{origin: "assistant", path: "UserAgent.execute_tools", role: "ToolExec"},
                name, args, exec_result, duration_ms
              )
            end

            # Flip to 'done' on BOTH success and error. A non-zero exit
            # from `run_script` (or any other tool error) is still a
            # completed tool invocation — the script ran, produced
            # output, exited with a code. Persists the wall-clock
            # `duration_ms` on the same row so the FE can render a
            # frozen "(Ns)" suffix on the tool bubble after completion
            # (see architecture.md §Long-running tool execution).
            content =
              case exec_result do
                {:ok, result} ->
                  DmhAi.Agent.SessionProgress.mark_tool_done(row.id, duration_ms)
                  format_tool_result(result)

                {:error, reason} ->
                  DmhAi.Agent.SessionProgress.mark_tool_done(row.id, duration_ms)
                  "Error: #{reason}"
              end

            # Soft post-execution nudges — Police inspects the call
            # against `prior_acc` (per-call accumulator, INCLUDES
            # sibling tool_msgs from this batch's earlier calls so
            # intra-batch consecutive run_scripts also trigger) and
            # may return an educational note that we prepend to the
            # result. No `[[ISSUE:...]]` marker, no escalation
            # counter — just an in-band hint the LLM reads on its
            # next turn. Currently one rule: consecutive `run_script`
            # → "fold remaining commands into ONE script next time".
            content =
              case DmhAi.Agent.Police.consecutive_run_script_advisory(name, prior_acc) do
                nil       -> content
                advisory  -> advisory <> content
              end

            %{role: "tool", content: content, tool_call_id: tool_call_id}
          else
            # Plain string rejection — return as a tool-result message,
            # no issue tracking.
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

        # Police rejections leave a `[[ISSUE:...]]` marker on the
        # tool_msg's content; tag the call so dedup checks (both
        # within this batch and across turns once the call lands in
        # `assistant_msg.tool_calls`) can skip it. Rejection means
        # the call never actually ran; the next attempt with the
        # same args is a legitimate retry, not a duplicate.
        rejected? = is_binary(tool_msg.content) and String.starts_with?(tool_msg.content, "[[ISSUE:")
        tagged_call = if rejected?, do: Map.put(call, "_rejected", true), else: call

        pseudo = %{"role" => "assistant", "tool_calls" => [tagged_call]}

        # Update ctx.anchor_task_num based on the verb and its outcome.
        # Also persists back_to_when_done on pickup_task success. See
        # architecture.md §Anchor mutation via back_to_when_done back-stack.
        new_ctx = maybe_mutate_anchor(ctx, name, args, tool_msg)

        # Per-call task_num attribution. The (assistant_tool_call,
        # tool_result) pair we just produced is stamped with the
        # task_num it operated on, looked up later by tool_call_id at
        # chain end so `save_tools_result_of_chain` can split the
        # chain into one tool_history entry per task. See `tool_num_for_pair/3`.
        new_ctx =
          stamp_tool_call_task_num(new_ctx, tool_call_id, name, args)

        # Auto-create-task hook: if this call was a successful
        # `pause_task` or `cancel_task` AND the session has a pending
        # pivot stashed by Police's Oracle gate, synthesize a fresh
        # `create_task` call with the user's earlier off-topic message
        # as the spec, execute it through the normal Tools.Registry
        # path, and emit it alongside the original call so the model
        # sees both events. Returns `{extra_pairs, extra_pseudos,
        # ctx''}`; empty when the trigger doesn't match.
        {extra_pairs, extra_pseudos, new_ctx} =
          maybe_auto_create_task(name, tool_msg, new_ctx)

        # Stamp every extra (synthetic auto-create_task) pair too —
        # its post-mutation anchor is the just-created task, which is
        # the right tag for the pair.
        new_ctx =
          Enum.reduce(extra_pairs, new_ctx, fn {_extra_msg, extra_call}, acc ->
            extra_id   = Map.get(extra_call, "id") || Map.get(extra_call, :id) || ""
            extra_name = get_in(extra_call, ["function", "name"]) || ""
            extra_args = get_in(extra_call, ["function", "arguments"]) || %{}
            stamp_tool_call_task_num(acc, extra_id, extra_name, extra_args)
          end)

        pairs    = [{tool_msg, tagged_call}] ++ extra_pairs
        pseudos  = [pseudo] ++ extra_pseudos

        {pairs, {prior_acc ++ pseudos, new_ctx}}
      end)

    tool_msgs    = Enum.map(pairs, fn {m, _} -> m end)
    tagged_calls = Enum.map(pairs, fn {_, c} -> c end)

    {tool_msgs, tagged_calls, final_ctx}
  end

  # Stamp the (assistant_tool_call, tool_result) pair we just produced
  # with the task_num it operated on. Looked up later (by tool_call_id)
  # at chain end by `save_tools_result_of_chain` so the chain's pairs
  # split into one tool_history entry per task.
  #
  # Caller MUST invoke this AFTER `maybe_mutate_anchor/4`, so that for
  # `create_task` the post-mutation `ctx.anchor_task_num` is the
  # newly-created task (and the default-branch task_num lookup picks
  # that up).
  defp stamp_tool_call_task_num(ctx, "", _name, _args), do: ctx
  defp stamp_tool_call_task_num(ctx, nil, _name, _args), do: ctx
  defp stamp_tool_call_task_num(ctx, tool_call_id, name, args)
       when is_binary(tool_call_id) do
    task_num = tool_num_for_pair(name, args, ctx)
    put_in(ctx, [:tool_call_task_nums, tool_call_id], task_num)
  end

  # Decide which task_num the pair belongs to:
  #
  #   * Task-acting verbs (`complete_task` / `cancel_task` / `pause_task`
  #     / `pickup_task` / `fetch_task`) — the pair's contribution belongs
  #     to the task NAMED IN THE ARGS, not the post-mutation anchor.
  #     `complete_task(N)`'s pair is the closing action of N's work, so
  #     it should be tagged N — even though after the call the anchor
  #     resets to `back_to_when_done` (often nil).
  #
  #   * Everything else (including `create_task`) — the pair's contribution
  #     belongs to whatever the anchor is AFTER the call. For
  #     `create_task` that's the newly-created task. For execution tools
  #     (`run_script`, `web_search`, …) the anchor is unchanged, so the
  #     active task gets its work attributed correctly.
  defp tool_num_for_pair(name, args, post_ctx) do
    case name do
      n when n in ~w(complete_task cancel_task pause_task pickup_task fetch_task) ->
        Map.get(args, "task_num") || Map.get(args, :task_num)

      _ ->
        Map.get(post_ctx, :anchor_task_num)
    end
  end

  # Apply anchor transitions based on tool verb + outcome. Only mutates
  # ctx on SUCCESSFUL task-verb calls; rejections and execution-tool
  # calls pass ctx through unchanged. See §Anchor mutation via
  # back_to_when_done back-stack.

  # `create_task`: the tool inserts with `status='ongoing'` and the
  # runtime advances the anchor in lockstep — functionally equivalent
  # to what `pickup_task` does for an existing task, but wrapped into
  # the same LLM roundtrip. The previous anchor becomes the new
  # task's `back_to_when_done_task_num` so complete / cancel / pause
  # can pop back to it. `last_rendered_anchor` is advanced too
  # (EXPLICIT model-driven transition — no refresh block needed; the
  # model knows it just created this task).
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
              DmhAi.SysLog.log("[ASSISTANT] anchor_back_ref set on create task=(#{n}) ← was_anchor=(#{prev})")

            _ ->
              :ok
          end
        end

        DmhAi.SysLog.log("[ASSISTANT] anchor create+pickup: (#{inspect(prev)}) → (#{n})")
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
              DmhAi.SysLog.log("[ASSISTANT] anchor_back_ref set task=(#{n}) ← was_anchor=(#{prev})")

            {:error, :not_found} ->
              :ok
          end
        end

        DmhAi.SysLog.log("[ASSISTANT] anchor pickup: (#{inspect(prev)}) → (#{n})")
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
            DmhAi.SysLog.log("[ASSISTANT] anchor #{verb} on current: (#{n}) → back=(#{inspect(back)})")
            # Clear the back-ref on the closed task so a future
            # re-pickup starts clean.
            case Tasks.resolve_num(ctx.session_id, n) do
              {:ok, task_id} ->
                Tasks.set_back_ref(task_id, nil)

              {:error, _} = err ->
                # The task we just closed ALSO can't be re-resolved by
                # number? Either the row was deleted mid-chain (race) or
                # the session_id is wrong. Log loudly — this contradicts
                # the success? path having just passed.
                Logger.error("[UserAgent] anchor #{verb}: resolve_num failed for current anchor (#{n}) session=#{ctx.session_id} err=#{inspect(err)}")
                DmhAi.SysLog.log("[ASSISTANT] anchor #{verb} resolve_num failed task_num=(#{n}) — back_ref left dangling")
            end
            Map.put(ctx, :anchor_task_num, back)

          nil ->
            # `lookup_by_num` returns nil when the row was deleted mid-
            # chain — extremely rare race. Best-effort: drop the anchor
            # so the next chain doesn't act on a dangling task_num.
            Logger.warning("[UserAgent] anchor #{verb}: lookup_by_num returned nil for (#{n}) session=#{ctx.session_id} — dropping anchor")
            Map.put(ctx, :anchor_task_num, nil)

          other ->
            # Anything else from lookup_by_num is a contract violation
            # (Tasks.lookup_by_num is documented to return %Task{} | nil).
            # Fail loud so the schema regression surfaces in tests, not
            # in prod after subtle anchor corruption.
            raise "Tasks.lookup_by_num returned unexpected shape #{inspect(other)} for session=#{ctx.session_id} num=#{n}"
        end

      _ ->
        # Either the verb was rejected / Police-blocked (success? = false),
        # or it targeted some OTHER task_num (c != n) which is allowed —
        # the model can close non-anchor rows without disturbing focus.
        # Both are legitimate; ctx passes through unchanged.
        ctx
    end
  end

  # Absolute fallback for `maybe_mutate_anchor`. We only reach here
  # for verbs OUTSIDE the dispatch table above — execution tools
  # (web_search, run_script, ...), MCP-namespaced tools, fetch_task,
  # request_input, etc. None of them mutate the anchor, so passing
  # ctx through is correct.
  #
  # If a NEW task-management verb gets added (e.g. resume_task,
  # archive_task), wire it into the dispatch above with explicit
  # mutation rules; do not rely on this fallback. To keep the
  # invariant tight, a future audit can constrain `name` here to a
  # pattern-match on the known non-mutating verbs and raise on
  # genuinely-unknown ones, but that requires a single source of
  # truth for verb names which doesn't exist today (tools are
  # plugin-registered).
  defp maybe_mutate_anchor(ctx, _name, _args, _tool_msg), do: ctx

  @doc false
  # Public for unit testing in `itgr_oracle_pivot.exs`. Not part of
  # the module's user-facing API; subject to change without notice.
  #
  # When the model successfully closes the active anchor with
  # `pause_task` or `cancel_task` AND the chain-start Oracle gate
  # had stashed a pending pivot for this session (because the
  # user's chain-start message was off-topic to the prior anchor),
  # synthesise a fresh `create_task` for that off-topic message and
  # execute it through the normal tool dispatch. The model sees the
  # result on its next roundtrip — the anchor flips to the new
  # task, and the model proceeds against it (its first call against
  # the new anchor is exactly what it originally wanted to do
  # before being told to confirm the pivot).
  #
  # Returns `{extra_pairs, extra_pseudos, ctx_after}`. `extra_pairs`
  # is a list of `{tool_msg, tool_call}` to splice into the
  # iteration output; `extra_pseudos` is the matching list of
  # `assistant` pseudo-messages for the duplicate-tool-call gate's
  # in-chain accumulator. Empty lists when no auto-create fires.
  def maybe_auto_create_task(name, %{content: content} = _tool_msg, ctx)
       when name in ~w(pause_task cancel_task) and is_binary(content) do
    if pause_or_cancel_succeeded?(content) do
      do_auto_create_task(ctx)
    else
      {[], [], ctx}
    end
  end
  def maybe_auto_create_task(_, _, ctx), do: {[], [], ctx}

  # Wait up to ~5 s for the chain's Oracle classification Task to
  # finish, so its `:unrelated` side-effect (writing the pivot stash
  # to `PendingPivots`) lands before we read the stash. Bounded to
  # avoid hanging the chain if Oracle is genuinely down. No-op when
  # the chain didn't start an Oracle (no anchor) or when the task
  # has already completed.
  @auto_pivot_oracle_await_ms 5_000

  defp await_pending_swift(%{swift_task: %Task{} = task}) do
    _ = Task.yield(task, @auto_pivot_oracle_await_ms)
    :ok
  end

  defp await_pending_swift(_), do: :ok

  @doc false
  # Public for unit testing in `itgr_oracle_pivot.exs`. Not part of
  # the module's user-facing API; subject to change without notice.
  #
  # Detects the success shape of a `pause_task` / `cancel_task` tool
  # result. Used by `maybe_auto_create_task/3` to decide whether the
  # auto-create-task hook should fire after the model closes the
  # current anchor on a confirmed pivot.
  #
  # Returns true when:
  #   * `content` is a binary, AND
  #   * the JSON payload carries `"ok": true`, AND
  #   * the content does NOT start with the `[[ISSUE:...]]` Police
  #     rejection marker, AND
  #   * the content does NOT start with the `Error:` prefix used by
  #     execute-tools' `{:error, reason}` branch.
  def pause_or_cancel_succeeded?(content) do
    is_binary(content) and
      String.contains?(content, "\"ok\": true") and
      not String.starts_with?(content, "[[ISSUE:") and
      not String.starts_with?(content, "Error:")
  end

  defp do_auto_create_task(ctx) do
    session_id = Map.get(ctx, :session_id)

    # If the chain's Oracle classification Task is still in flight,
    # wait briefly for it before reading PendingPivots. The stash is
    # written inside the Swift Task's body when the verdict is
    # `:unrelated`. Police's earlier `check_pivot` gate uses a quick
    # yield (3s) and does NOT shut down the task on timeout — this
    # means the stash CAN still arrive after the chain's tool-call
    # decision but before the user's pause/cancel handler runs.
    # However, a fast user typing "pause" within milliseconds of
    # "check my X" could outrun the Oracle. Yielding here once more
    # closes that window.
    await_pending_swift(ctx)

    case DmhAi.Agent.PendingPivots.get(session_id) do
      %{user_msg: user_msg} when is_binary(user_msg) and user_msg != "" ->
        args = %{
          "task_type"  => "one_off",
          "task_spec"  => user_msg,
          "task_title" => derive_task_title(user_msg),
          "language"   => "en"
        }

        synthetic_tool_call_id =
          "auto_pivot_" <>
            (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

        # Surface the auto-create as a real progress row so the FE
        # timeline shows it next to the pause_task / cancel_task that
        # triggered it. Without this, the user sees pause → silence →
        # the model suddenly working on a different task, with no
        # explanation. The row is appended pending-then-done so the
        # spinner-to-check transition matches a normal tool call.
        progress_label = DmhAi.Agent.ProgressLabel.format("create_task", args)
        progress_ctx = %{
          session_id: ctx.session_id,
          user_id:    ctx.user_id,
          task_id:    nil
        }

        {:ok, progress_row} =
          DmhAi.Agent.SessionProgress.append(progress_ctx, "tool", progress_label, status: "pending")

        case DmhAi.Tools.Registry.execute("create_task", args, ctx) do
          {:ok, result} ->
            DmhAi.Agent.SessionProgress.mark_tool_done(progress_row.id)
            content = format_tool_result(result)
            tool_msg = %{role: "tool", content: content, tool_call_id: synthetic_tool_call_id}

            tagged_call = %{
              "id" => synthetic_tool_call_id,
              "function" => %{"name" => "create_task", "arguments" => args}
            }

            pseudo = %{"role" => "assistant", "tool_calls" => [tagged_call]}

            ctx_after =
              ctx
              |> maybe_mutate_anchor("create_task", args, tool_msg)

            DmhAi.Agent.PendingPivots.clear(session_id)
            # Verdict against the OLD anchor is now stale (the
            # anchor just flipped). Clear the cache so subsequent
            # tool calls in this chain pass through Police's pivot
            # gate (no swift_task → :related fallback).
            Process.put(:dmh_ai_swift_verdict_cached, {:resolved, :related})

            DmhAi.SysLog.log(
              "[ASSISTANT] auto-create-task: session=#{session_id} " <>
                "spec=#{inspect(String.slice(user_msg, 0, 80))}"
            )

            {[{tool_msg, tagged_call}], [pseudo], ctx_after}

          {:error, reason} ->
            DmhAi.Agent.SessionProgress.mark_tool_done(progress_row.id)
            DmhAi.Agent.PendingPivots.clear(session_id)
            DmhAi.SysLog.log("[ASSISTANT] auto-create-task FAILED: #{inspect(reason)}")
            {[], [], ctx}
        end

      _ ->
        {[], [], ctx}
    end
  end

  @doc false
  # Public for unit testing in `itgr_oracle_pivot.exs`. Not part of
  # the module's user-facing API; subject to change without notice.
  #
  # First line, trimmed, capped at 60 chars — same shape as the
  # naming flow uses for one_off tasks. Operator can rename later
  # via the sidebar.
  def derive_task_title(user_msg) when is_binary(user_msg) do
    user_msg
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.slice(0, 60)
  end

  # Kick off the Swift classifier in the background when an anchor
  # is set. Returns `{task | nil, anchor_task_spec | nil}`. The
  # task body classifies AND, on `:unrelated`, stashes a pending
  # pivot record in `PendingPivots` as a side effect — so the
  # auto-create-task hook fires later even if the model went text-
  # only on the off-topic chain (no Police gate ever ran). Police
  # awaits the same task value lazily inside its pivot gate.
  defp maybe_start_swift(nil, _user_msg, _ctx), do: {nil, nil}
  defp maybe_start_swift(%{task_id: task_id, task_num: anchor_task_num}, user_msg, ctx)
       when is_binary(task_id) and is_binary(user_msg) and user_msg != "" do
    case Tasks.get(task_id) do
      %{task_spec: spec} when is_binary(spec) and spec != "" ->
        session_id = ctx.session_id
        prev_assistant_msg = last_assistant_msg_for(session_id)

        task =
          Task.Supervisor.async_nolink(DmhAi.Agent.TaskSupervisor, fn ->
            verdict = DmhAi.Agent.Swift.classify(user_msg, spec, prev_assistant_msg)

            # Only :unrelated stashes a pending pivot — that signals
            # "user is pivoting to a NEW task". :done means "user wants
            # to close the active task with NO follow-up" (no auto-
            # create-task should fire). See specs/architecture.md
            # §Oracle DONE verdict.
            if verdict == :unrelated do
              DmhAi.Agent.PendingPivots.put(session_id, %{
                user_msg: user_msg,
                anchor_task_num: anchor_task_num
              })
            end

            verdict
          end)

        {task, spec}

      _ ->
        {nil, nil}
    end
  end
  defp maybe_start_swift(_, _, _), do: {nil, nil}

  # Read the most recent assistant message from the session — Oracle's
  # pivot classifier uses it to recognise "user is answering my prior
  # clarifying question" as RELATED rather than misreading a terse
  # reply (a status name, a "yes", an account number) as DONE/UNRELATED.
  # Filtered to plain assistant text — we drop kind-tagged rows
  # (`command_ack` from /wiki, /memo) since those aren't conversational.
  # Returns nil when no usable prior assistant text exists.
  defp last_assistant_msg_for(session_id) when is_binary(session_id) do
    try do
      %{rows: rows} = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

      case rows do
        [[json]] when is_binary(json) ->
          msgs = Jason.decode!(json || "[]")

          msgs
          |> Enum.reverse()
          |> Enum.find_value(fn m ->
            cond do
              m["role"] != "assistant" -> nil
              m["kind"] in ["command_ack"] -> nil
              not is_binary(m["content"]) or m["content"] == "" -> nil
              true -> m["content"]
            end
          end)

        _ ->
          nil
      end
    rescue
      _ -> nil
    end
  end

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

  # Confidant memo auto-retrieve. Always embeds + searches — no LLM
  # gate. The retrieval is bounded only by `memo_context_top_k` (the
  # K in vector ANN). See specs/commands.md § Confidant memo
  # auto-retrieve.
  #
  # No score-threshold filter — top-K already bounds the count, and
  # the downstream consumers (web-search planner + Confidant model)
  # judge relevance from content. A score floor on top of top-K only
  # served to hide weak-but-still-best matches from the LLM, which
  # is the opposite of what we want when the LLM is the smart
  # filter. Concretely: on small embedders (qwen3-0.6B etc.) and
  # cross-lingual / unaccented input, a relevant memo can score
  # ~0.45 — below any reasonable threshold yet clearly the right
  # match by content. Top-K + LLM judgment handles this correctly.
  #
  # Pronoun resolution falls out implicitly: the embed input
  # concatenates the last 1–2 prior user turns with the current
  # message, so "and his email?" embeds with the prior "what's
  # John's birthday?" in scope.
  #
  # `recent_user_msgs` is `extract_user_messages/1`'s output — last
  # ~10 user turns INCLUDING the current. We drop the last entry
  # (already in `current_content`) and take up to 2 prior.
  #
  # Returns `{memo_block, memo_hits}`:
  #   * `memo_block` — the formatted `[memo context]` string for the
  #                    Confidant LLM prompt; populated with all
  #                    decrypted top-K hits (the framing tells the
  #                    model "use any that are relevant; ignore the
  #                    rest"). `nil` only on retrieval infrastructure
  #                    error (embed / search RPC failure).
  #   * `memo_hits`  — the same decrypted hits, used by the web-search
  #                    planner (Rule 0 of `@confidant_prompt`) to skip
  #                    web search when a memo already answers.
  #                    Always a list — `[]` on no-key / empty / error.
  defp build_memo_context(current_content, recent_user_msgs, user_id) do
    # Memo content is AES-GCM ciphertext at rest; we need the user's
    # MMK to surface plaintext to the model. No key → user is offline
    # / token expired / never logged in this BE process. Skip the
    # whole `[memo context]` block in that case (fail soft — the
    # Confidant turn just answers without memo grounding, exactly as
    # if the user had no relevant memos saved).
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
            line = "[Memo auto] search failed: #{inspect(reason, limit: 80)}"
            Logger.warning(line)
            DmhAi.SysLog.log(line)
            {nil, []}
        end

      {:error, reason} ->
        line = "[Memo auto] embed failed: #{inspect(reason, limit: 80)}"
        Logger.warning(line)
        DmhAi.SysLog.log(line)
        {nil, []}
    end
  end

  # Diagnostic line for memo retrieval — mirrored to SysLog so
  # operators can grep `system.log` to see actual cosine scores per
  # hit when tuning embedders / debugging recall.
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

  # Decrypt a single memo hit. Mirrors `Tools.FetchMemo.decrypt_hit` —
  # tag mismatch drops the row (corruption / cross-user attempt);
  # legacy plaintext (pre-encryption migration) is trusted as-is.
  defp decrypt_memo_hit(hit, mmk) do
    # Map.get/3 (NOT dot-access) — BM25-leg hits historically didn't
    # carry chunk_idx; missing-key raises BadKeyError on `hit.chunk_idx`,
    # which crashes the whole memo retrieval. Defensive fallback to 0
    # means tag-mismatched rows just drop cleanly via :bad_key below.
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

  # `[memo context]` block — two states. See specs/commands.md.
  #
  # FOUND state: bullets of hit chunk_text + language rule (cosine
  # retrieval is multilingual via qwen3-embedding so a VN question
  # can hit an EN memo; without the rule weak models echo the memo's
  # language back).
  #
  # EMPTY state: lexical-trigger rule. The model is told to fall
  # back to "honest no memo" ONLY when the user's message itself
  # references the memo store (words like "memo", "search memo",
  # "find in memo", "memo about", etc.). For everything else, the
  # block is a no-op signal — the model answers per its usual
  # system-prompt rules. This avoids putting a "is this a personal
  # question?" classification burden on the model, which is exactly
  # the gate problem we hit before.
  defp format_memo_context_block([]) do
    "[memo context]\n" <>
      "We checked the user's saved memos for this question. Nothing relevant found.\n\n" <>
      "How to use this signal:\n" <>
      "- IF the user's message itself references their memo store (e.g. words like \"memo\", \"saved\", phrases like \"search memo …\", \"find in memo …\", \"look up memo …\", \"do I have a memo on …\", \"memo about …\", \"memo contains …\"): you MUST tell the user honestly that no saved memo matches their question. Do NOT substitute general knowledge, do NOT invent.\n" <>
      "- OTHERWISE (the user is asking a normal question or chatting and never mentioned the memo store): ignore this block entirely and answer per your usual system-prompt instructions.\n" <>
      "[/memo context]"
  end

  defp format_memo_context_block(hits) do
    bullets =
      hits
      |> Enum.map_join("\n", fn h ->
        "- " <> String.replace(h.chunk_text || "", "\n", " ")
      end)

    "[memo context]\n" <>
      "The user previously saved these personal notes. Use any that are relevant to the question; ignore the rest. The notes may be in a different language than the user's question — translate any facts you cite. Reply in the user's question language, NOT the notes' language.\n\n" <>
      bullets <>
      "\n[/memo context]"
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
