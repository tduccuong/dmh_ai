# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Sweeper do
  @moduledoc """
  Retention sweeper for completed workflow runs. Wakes hourly,
  finds runs whose `completed_at < now - retention_days`, exports
  each (instance row + step trace) to a per-workflow JSONL file
  at:

      <archive_root>/<org_id>/<workflow_id>/<YYYY-MM-DD>.jsonl

  Then deletes the live DB rows. Webhook-event-id dedupe rows older
  than 24h get cleared in the same pass (those don't need
  archival — they're idempotency markers, not user data).

  Operator can `rsync` / `gzip` the archive tree separately; the
  sweeper itself never deletes archive files.

  Retention window is `AgentSettings.workflow_run_retention_days/0`,
  default 30. Archive root is configured at start (env: defaults to
  `/data/archive/workflow_runs`).
  """

  use GenServer
  require Logger

  alias DmhAi.{Repo, Workflows}
  alias DmhAi.Agent.AgentSettings
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_archive_root "/data/archive/workflow_runs"
  @default_tick_ms 3_600_000      # 1 hour
  @webhook_event_retention_ms 24 * 60 * 60 * 1000

  # ─── Client API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run a sweep immediately. Returns `{archived_runs, deleted_webhook_events}`.
  Test seam + manual operator trigger.
  """
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now, 60_000)
  end

  # ─── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      interval:     Keyword.get(opts, :tick_interval_ms, @default_tick_ms),
      archive_root: Keyword.get(opts, :archive_root, @default_archive_root)
    }
    schedule_next(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    result = sweep_once(state.archive_root)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      sweep_once(state.archive_root)
    rescue
      e -> Logger.error("[Workflows.Sweeper] tick failed: #{Exception.message(e)}")
    end

    schedule_next(state.interval)
    {:noreply, state}
  end

  defp schedule_next(ms), do: Process.send_after(self(), :tick, ms)

  # ─── Sweep logic ──────────────────────────────────────────────────────

  @doc """
  Pure-function sweep — exposed for test invocation. Returns
  `{archived_runs, deleted_webhook_events}`.
  """
  @spec sweep_once(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def sweep_once(archive_root) when is_binary(archive_root) do
    archived = archive_completed_runs(archive_root)
    deleted  = expire_old_webhook_events()
    if archived > 0 or deleted > 0 do
      Logger.info("[Workflows.Sweeper] archived=#{archived} expired_webhook_events=#{deleted}")
    end
    {archived, deleted}
  end

  defp archive_completed_runs(archive_root) do
    retention_ms = AgentSettings.workflow_run_retention_days() * 24 * 60 * 60 * 1000
    cutoff_ms    = System.os_time(:millisecond) - retention_ms

    %{rows: rows} =
      query!(Repo, """
      SELECT id, workflow_id, org_id, completed_at
      FROM workflow_run_state
      WHERE status IN ('completed', 'failed', 'cancelled', 'timed_out')
        AND completed_at IS NOT NULL
        AND completed_at < ?
      ORDER BY completed_at ASC
      LIMIT 1000
      """, [cutoff_ms])

    Enum.reduce(rows, 0, fn [run_id, workflow_id, org_id, completed_at], acc ->
      try do
        archive_one_run(archive_root, run_id, workflow_id, org_id, completed_at)
        delete_run_rows(run_id)
        acc + 1
      rescue
        e ->
          Logger.error("[Workflows.Sweeper] archive failed run=#{run_id}: #{Exception.message(e)}")
          acc
      end
    end)
  end

  defp archive_one_run(archive_root, run_id, workflow_id, org_id, completed_at) do
    run   = Workflows.get_run!(run_id)
    steps = Workflows.list_steps(run_id)

    record = run |> Map.put(:steps, steps) |> Map.delete(:bindings)
    # `bindings` is huge and redundant — steps + trigger_payload + outputs
    # carry the same info. Drop to keep archive lean.

    day  = day_string_utc(completed_at)
    dir  = Elixir.Path.join([archive_root, org_id, workflow_id])
    file = Elixir.Path.join(dir, "#{day}.jsonl")

    File.mkdir_p!(dir)

    json_line = Jason.encode!(record) <> "\n"
    File.write!(file, json_line, [:append])
  end

  defp delete_run_rows(run_id) do
    query!(Repo, "DELETE FROM workflow_run_steps WHERE run_id=?", [run_id])
    query!(Repo, "DELETE FROM workflow_run_waits WHERE run_id=?", [run_id])
    query!(Repo, "DELETE FROM workflow_run_state WHERE id=?",    [run_id])
  end

  defp expire_old_webhook_events do
    cutoff_ms = System.os_time(:millisecond) - @webhook_event_retention_ms

    %{num_rows: n} =
      query!(Repo, "DELETE FROM workflow_webhook_events WHERE received_at < ?", [cutoff_ms])

    n
  end

  defp day_string_utc(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end
end
