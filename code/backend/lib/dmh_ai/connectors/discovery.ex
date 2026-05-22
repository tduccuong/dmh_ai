# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Discovery do
  @moduledoc """
  Runner for admin **Discover <Layer>** clicks. Each invocation:

    1. Records a `connector_discovery_runs` row in `:running` state.
    2. Calls the connector module's `Discoverable.discover_<layer>/N`
       callback (Layer A: `discover_functions/0`; Layer B + C land
       behind this same shape).
    3. On success: atomically swaps the slug's `connector_functions`
       rows via `Manifest.replace_all/3` (Layer A) — leaving every
       other slug untouched. Stamps the run row `:success` with
       `records_affected`.
    4. On failure: leaves existing rows intact, stamps the run row
       `:failed` with `error_text`. Admin can click Discover again.

  Concurrency: one in-flight run per (slug, layer) at a time. A
  second click while a run is in-flight returns `:already_running`
  rather than starting a parallel run — protects against accidental
  double-clicks and runaway probe traffic against the vendor.

  Runs are background `Task`s under the application supervisor.
  The HTTP handler returns immediately after `run_async/3`; the FE
  polls `state_for/1` (1-second cadence) while the layer is
  `:running` and stops when it flips to `:success` or `:failed`.
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Connectors.{Discoverable, Manifest, Registry}
  alias DmhAi.Repo

  import Ecto.Adapters.SQL, only: [query!: 3]

  require Logger

  @table :connector_discovery_inflight

  @layers [:functions, :metadata, :docs]

  @typedoc "Per-layer state surfaced to the admin FE."
  @type layer_state :: %{
          status:           :idle | :running | :success | :failed,
          freshness:        :fresh | :warn | :stale | nil,
          last_run_at:      integer() | nil,
          records_affected: non_neg_integer() | nil,
          error_text:       String.t() | nil,
          triggered_by:     String.t() | nil
        }

  @doc """
  Idempotent ETS bootstrap. Called from the supervision tree on app
  start so a re-init (test reruns, hot reload) doesn't crash.
  """
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Kick off a discovery run in the background. Returns `{:ok, :started}`
  on accept, `{:error, :already_running}` when a prior run for the
  same `(slug, layer)` is still in flight, `{:error, :unsupported_layer}`
  when the connector module hasn't implemented the layer's callback.
  """
  @spec run_async(String.t(), atom(), String.t()) ::
          {:ok, :started}
          | {:error, :already_running | :unsupported_layer | :unknown_slug}
  def run_async(slug, layer, triggered_by)
      when is_binary(slug) and layer in @layers and is_binary(triggered_by) do
    init()

    case Registry.module_for_slug(slug) do
      nil ->
        {:error, :unknown_slug}

      mod ->
        cond do
          not Discoverable.implements?(mod, layer) ->
            {:error, :unsupported_layer}

          in_flight?(slug, layer) ->
            {:error, :already_running}

          true ->
            mark_in_flight(slug, layer, triggered_by)

            Task.start(fn ->
              try do
                do_run(slug, layer, mod, triggered_by)
              after
                clear_in_flight(slug, layer)
              end
            end)

            {:ok, :started}
        end
    end
  end

  @doc """
  Per-layer state for one slug. Reads the in-flight ETS slot first,
  then the most recent `connector_discovery_runs` row for the layer.
  Returns one entry per `@layers` so the FE can render every button
  with deterministic shape.
  """
  @spec state_for(String.t()) :: %{atom() => layer_state()}
  def state_for(slug) when is_binary(slug) do
    init()
    inflight = inflight_for_slug(slug)
    history  = history_for_slug(slug)
    now      = System.os_time(:millisecond)
    warn_ms  = AgentSettings.discovery_warn_after_days() * 86_400_000
    stale_ms = AgentSettings.discovery_stale_after_days() * 86_400_000

    Enum.into(@layers, %{}, fn layer ->
      state =
        case Map.get(inflight, layer) do
          nil ->
            case Map.get(history, layer) do
              nil ->
                %{status: :idle, freshness: nil, last_run_at: nil,
                  records_affected: nil, error_text: nil, triggered_by: nil}

              row ->
                Map.put(row, :freshness, classify_freshness(row, now, warn_ms, stale_ms))
            end

          %{started_at: at, triggered_by: by} ->
            %{status: :running, freshness: nil, last_run_at: at,
              records_affected: nil, error_text: nil, triggered_by: by}
        end

      {layer, state}
    end)
  end

  # Freshness applies only to successful runs. A failed run leaves
  # `freshness: nil` so the FE can show the red ✗ without conflating
  # it with the time-based stale signal — they're orthogonal concerns
  # (the row may have last succeeded weeks ago, but the latest
  # *failed* attempt is what the admin needs to know about now).
  defp classify_freshness(%{status: :success, last_run_at: at}, now, warn_ms, stale_ms)
       when is_integer(at) do
    age = now - at

    cond do
      age >= stale_ms -> :stale
      age >= warn_ms  -> :warn
      true            -> :fresh
    end
  end

  defp classify_freshness(_, _, _, _), do: nil

  # ─── private ─────────────────────────────────────────────────────────

  defp do_run(slug, :functions, mod, triggered_by) do
    started_at = System.os_time(:millisecond)
    run_id     = insert_run_row(slug, "functions", "running", started_at, triggered_by)

    case safe_call(mod, :discover_functions, []) do
      {:ok, rows} when is_list(rows) ->
        try do
          {:ok, n} = Manifest.replace_all(slug, rows, triggered_by)
          complete_run_row(run_id, "success", started_at, n, nil)

          Logger.info(
            "[Connectors.Discovery] slug=#{slug} layer=functions ok rows=#{n} by=#{triggered_by}"
          )
        rescue
          e ->
            msg = Exception.message(e)
            complete_run_row(run_id, "failed", started_at, 0, "replace_all crashed: #{msg}")

            Logger.error(
              "[Connectors.Discovery] slug=#{slug} layer=functions replace_all_crash: #{msg}"
            )
        end

      {:error, reason} ->
        msg = inspect(reason)
        complete_run_row(run_id, "failed", started_at, 0, msg)

        Logger.warning(
          "[Connectors.Discovery] slug=#{slug} layer=functions failed: #{msg}"
        )

      other ->
        msg = "discover_functions/0 returned non-conforming shape: #{inspect(other)}"
        complete_run_row(run_id, "failed", started_at, 0, msg)

        Logger.error("[Connectors.Discovery] slug=#{slug} #{msg}")
    end
  end

  # Layers B + C wire here when their callbacks ship — same shape:
  # call → swap → log. Until then they remain `:unsupported_layer`
  # at the entry point.
  defp do_run(slug, layer, _mod, _triggered_by) do
    Logger.error("[Connectors.Discovery] slug=#{slug} layer=#{layer} not implemented")
  end

  defp safe_call(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    e ->
      Logger.error(
        "[Connectors.Discovery] #{inspect(mod)}.#{fun}/#{length(args)} crashed: " <>
          Exception.message(e)
      )

      {:error, {:callback_crash, Exception.message(e)}}
  end

  # ─── ETS in-flight tracking ─────────────────────────────────────────

  defp in_flight?(slug, layer) do
    :ets.lookup(@table, {slug, layer}) != []
  end

  defp mark_in_flight(slug, layer, triggered_by) do
    :ets.insert(@table, {{slug, layer}, %{
      started_at:   System.os_time(:millisecond),
      triggered_by: triggered_by
    }})
  end

  defp clear_in_flight(slug, layer) do
    :ets.delete(@table, {slug, layer})
  end

  defp inflight_for_slug(slug) do
    :ets.match_object(@table, {{slug, :_}, :_})
    |> Enum.into(%{}, fn {{_slug, layer}, info} -> {layer, info} end)
  end

  # ─── DB run rows ────────────────────────────────────────────────────

  defp insert_run_row(slug, layer, status, started_at, triggered_by) do
    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO connector_discovery_runs
        (connector_slug, layer, status, started_at, completed_at,
         error_text, records_affected, triggered_by, created_at)
      VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
      RETURNING id
      """, [slug, layer, status, started_at, triggered_by, started_at])

    id
  end

  defp complete_run_row(run_id, status, started_at, records, error_text) do
    completed_at = System.os_time(:millisecond)

    query!(Repo, """
    UPDATE connector_discovery_runs
       SET status=?, completed_at=?, records_affected=?, error_text=?
     WHERE id=?
    """, [status, completed_at, records, error_text, run_id])

    _ = started_at
    :ok
  end

  # Most recent terminal run (success | failed) per layer for the slug.
  # `:running` rows are sourced from ETS in `state_for/1`; if a run row
  # is stuck in `running` due to a crash, the ETS slot is gone, so the
  # FE sees the previous terminal state instead of a dangling spinner.
  defp history_for_slug(slug) do
    %{rows: rows} =
      query!(Repo, """
      SELECT layer, status, completed_at, records_affected, error_text, triggered_by
      FROM connector_discovery_runs
      WHERE connector_slug=? AND status IN ('success', 'failed')
      ORDER BY completed_at DESC
      """, [slug])

    rows
    |> Enum.reduce(%{}, fn [layer, status, completed_at, records, err_text, by], acc ->
      key = String.to_atom(layer)

      Map.put_new(acc, key, %{
        status:           String.to_atom(status),
        last_run_at:      completed_at,
        records_affected: records,
        error_text:       err_text,
        triggered_by:     by
      })
    end)
  end
end
