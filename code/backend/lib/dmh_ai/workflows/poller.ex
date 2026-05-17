# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Poller do
  @moduledoc """
  Tick-driven dispatcher for armed workflow triggers. Wakes every
  `tick_interval_ms` (default 60_000 = 1 minute), iterates the
  `workflows` table for rows with non-NULL `active_version`, reads
  each workflow version's `trigger` field, decides whether it's
  due to fire, and on fire opens a one-off task with the workflow
  IR + trigger payload embedded in the task spec.

  The task's executor IS the Assistant LLM — the existing
  pending-task pickup path fires once the user's session is alive.
  No separate workflow-execution engine in v1.

  Trigger kinds supported in v1:

    * `schedule` with `every_seconds: N` — fires every N seconds
      after the workflow was armed. v2 will add full cron parsing.
    * `poll` with `every_seconds: N` — same cadence semantics; the
      `source` query (e.g. `hubspot.deal.find` with a filter) is
      embedded in the task spec so the Assistant executes it +
      fans out per-result downstream.
    * `manual` — never fires from here (manual is `invoke_workflow`).
    * `webhook` — never fires from here (webhook ingress is
      Primitive 0.8 Phase B; until that lands the compiler falls
      back to poll).

  State (in-memory ETS, lost on restart in v1):

    * `last_fired_at_ms{workflow_id_org_key => millis}` — when
      this workflow last fired. The next fire is gated on
      `now - last_fired_at_ms >= every_seconds * 1000`.

  v2 will persist last-fire state in a `workflow_triggers` table so
  a node restart doesn't replay or skip ticks.
  """

  use GenServer
  require Logger

  alias DmhAi.{Workflows, Repo}
  alias DmhAi.Agent.Tasks
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_tick_ms 60_000
  @ets_table :dmh_ai_workflow_poller_state

  # ─── Client API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force a tick now (test + manual debugging). Returns the count of
  workflows fired on this tick.
  """
  def tick_now do
    GenServer.call(__MODULE__, :tick_now, 30_000)
  end

  # ─── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :tick_interval_ms, @default_tick_ms)
    :ets.new(@ets_table, [:public, :named_table, :set])
    schedule_next(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    n = run_tick()
    {:reply, n, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_tick()
    schedule_next(state.interval)
    {:noreply, state}
  end

  defp schedule_next(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  # ─── Tick logic ───────────────────────────────────────────────────────

  defp run_tick do
    now = System.os_time(:millisecond)

    armed_workflows()
    |> Enum.reduce(0, fn wf, fired_count ->
      case Workflows.get_version(wf.org_id, wf.id, wf.active_version) do
        nil ->
          # Active_version points at a missing row — defensive log + skip.
          Logger.warning("[Workflows.Poller] workflow #{wf.org_id}/#{wf.id} active_version=#{wf.active_version} but version row missing; skipping")
          fired_count

        version ->
          if should_fire?(wf, version, now) do
            fire(wf, version, now)
            fired_count + 1
          else
            fired_count
          end
      end
    end)
  end

  # All workflows in the system with a non-NULL active_version. Bypasses
  # `Workflows.list_workflows/1` because that's per-org; the poller is
  # install-wide.
  defp armed_workflows do
    %{rows: rows, columns: cols} = query!(Repo, """
    SELECT id, org_id, display_name, current_version, active_version,
           created_at, updated_at
    FROM workflows WHERE active_version IS NOT NULL
    """, [])

    Enum.map(rows, fn row ->
      Enum.zip(cols, row) |> Map.new() |> atom_keys()
    end)
  end

  defp atom_keys(m) do
    Enum.into(m, %{}, fn {k, v} -> {String.to_atom(k), v} end)
  end

  # ─── Fire decision ────────────────────────────────────────────────────

  defp should_fire?(wf, version, now_ms) do
    trigger = Map.get(version.ir, "trigger", %{})
    kind    = Map.get(trigger, "kind")

    case kind do
      k when k in ["schedule", "poll"] ->
        every_seconds = Map.get(trigger, "every_seconds")
        case every_seconds do
          n when is_integer(n) and n > 0 ->
            interval_ms = n * 1000
            elapsed_since_last_fire(wf, now_ms) >= interval_ms

          _ ->
            # Schedule without every_seconds (e.g. cron-only) — v1 unsupported.
            Logger.debug("[Workflows.Poller] workflow #{wf.id}: trigger.kind=#{k} but no every_seconds; cron-only triggers not supported in v1")
            false
        end

      _ ->
        # manual, webhook, or missing — not the poller's job.
        false
    end
  end

  defp elapsed_since_last_fire(wf, now_ms) do
    key = state_key(wf)
    case :ets.lookup(@ets_table, key) do
      [] ->
        # Never fired — treat as "infinitely overdue" → fire on first tick after arm.
        :infinity_ms

      [{^key, last}] ->
        now_ms - last
    end
  end

  defp state_key(wf), do: {wf.org_id, wf.id}

  # ─── Fire ─────────────────────────────────────────────────────────────

  defp fire(wf, version, now_ms) do
    Logger.info("[Workflows.Poller] firing workflow=#{wf.org_id}/#{wf.id} v#{version.version}")

    task_spec = build_task_spec(wf, version)
    task_title = "#{wf.display_name} run"

    user_id = version.compiled_by_user_id
    session_id = find_or_pick_session(user_id)

    case session_id do
      nil ->
        Logger.warning("[Workflows.Poller] no session for user=#{user_id}; can't fire workflow=#{wf.id} — skipping until user opens a session")

      sid ->
        _task_id = Tasks.insert(
          user_id:    user_id,
          session_id: sid,
          task_type:   "one_off",
          intvl_sec:  0,
          task_title:  task_title,
          task_spec:   task_spec,
          attachments: [],
          task_status: "pending",
          language:   "en"
        )

        :ets.insert(@ets_table, {state_key(wf), now_ms})
    end
  end

  # The task spec the Assistant reads. Carries the IR + a marker so the
  # Assistant knows to walk the workflow instead of treating this as a
  # generic user ask.
  defp build_task_spec(wf, version) do
    """
    [Workflow run — autonomous trigger fired]

    Workflow: #{wf.display_name}
    Slug: #{wf.id}
    Version: #{version.version}
    Trigger: #{Jason.encode!(Map.get(version.ir, "trigger", %{}))}

    Walk the workflow nodes below in order, calling the named connector
    functions with bindings resolved per layer-W.md's Mustache rules.
    Use the existing connector tools (e.g. hubspot.contact.find,
    calendly.single_use_link.create) directly. Honour branches, gates,
    waits, and outputs as declared.

    IR (full):
    #{Jason.encode!(version.ir, pretty: true)}
    """
  end

  # Pick any session belonging to the user — v1 uses the most-recently-
  # active. v2 will create a dedicated "workflow runs" session per user
  # so workflow-fired tasks don't pollute the user's regular chats.
  defp find_or_pick_session(user_id) do
    case query!(Repo, """
    SELECT id FROM sessions WHERE user_id=? ORDER BY updated_at DESC LIMIT 1
    """, [user_id]).rows do
      [[sid]] -> sid
      _       -> nil
    end
  end
end
