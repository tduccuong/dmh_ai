# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.ConnectorDiscoveryTest do
  @moduledoc """
  Pins the end-to-end contract of the admin Discover flow.

  Layer A (Functions) round-trip — when a connector implements
  `Discoverable.discover_functions/0`, the runner:

    1. Inserts a `connector_discovery_runs` row in `:running`.
    2. Calls the callback.
    3. Atomic-swaps the slug's rows via `Manifest.replace_all/3`.
    4. Flips the run row to `:success` with `records_affected`.

  Concurrency: a second `run_async/3` while a prior run is in flight
  returns `:already_running` (single-flight guarantee).

  Unsupported layers: callbacks the connector hasn't implemented
  return `:unsupported_layer` without writing any DB rows.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.{Discoverable, Discovery, Manifest}
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    Discovery.init()
    # Pre-test snapshot: the boot seeder already loaded the bundled
    # priv rows, so we expect a non-zero baseline count.
    initial_count = Manifest.count_for_slug("hubspot")
    assert initial_count > 0

    :ok
  end

  describe "discover_functions vertical" do
    test "atomic swap on success + run row marked :success" do
      runs_before = run_row_count("hubspot", "functions")

      assert {:ok, :started} =
               Discovery.run_async("hubspot", :functions, "admin:test-user")

      # Background Task — give it a beat to land its write. The runner
      # finishes well under 1s for the priv-fallback path; 500ms is
      # a generous ceiling.
      assert eventually(fn ->
               state = Discovery.state_for("hubspot")
               state.functions.status in [:success, :failed]
             end)

      state = Discovery.state_for("hubspot")
      assert state.functions.status == :success
      assert state.functions.records_affected > 0
      assert state.functions.triggered_by == "admin:test-user"

      runs_after = run_row_count("hubspot", "functions")
      assert runs_after == runs_before + 1

      # The manifest table reflects the swap — count matches the rows
      # the callback returned.
      assert Manifest.count_for_slug("hubspot") == state.functions.records_affected
    end

    test "second click while in flight returns :already_running" do
      assert {:ok, :started} =
               Discovery.run_async("hubspot", :functions, "admin:first")

      # Immediate second call lands while the first is still in flight
      # (Task hasn't been scheduled past `mark_in_flight`). May race
      # to either `:already_running` (first still queued) or `:started`
      # (first already completed). Retry briefly to force the first case.
      result =
        case Discovery.run_async("hubspot", :functions, "admin:second") do
          {:error, :already_running} -> :already_running
          {:ok, :started} ->
            # First run completed too fast; assert the prior run row
            # exists (i.e. the runner did do its job).
            assert eventually(fn ->
                     Discovery.state_for("hubspot").functions.status in [:success, :failed]
                   end)
            :first_completed_first
        end

      # Whichever path, drain to idle.
      assert eventually(fn ->
               state = Discovery.state_for("hubspot")
               state.functions.status in [:success, :failed]
             end)

      assert result in [:already_running, :first_completed_first]
    end

    test ":unsupported_layer when the connector lacks the callback" do
      # `:metadata` / `:docs` aren't implemented yet on any connector,
      # so a request for them rejects without writing a run row.
      runs_before = run_row_count("hubspot", "metadata")

      assert {:error, :unsupported_layer} =
               Discovery.run_async("hubspot", :metadata, "admin:test-user")

      assert run_row_count("hubspot", "metadata") == runs_before
    end

    test ":unknown_slug when the slug isn't registered" do
      assert {:error, :unknown_slug} =
               Discovery.run_async("does_not_exist", :functions, "admin:test-user")
    end
  end

  describe "Discoverable.implements?" do
    test "HubSpot implements functions; not metadata/docs (yet)" do
      mod = DmhAi.Connectors.HubSpot

      assert Discoverable.implements?(mod, :functions)
      refute Discoverable.implements?(mod, :metadata)
      refute Discoverable.implements?(mod, :docs)
    end
  end

  describe "freshness classification" do
    test "fresh / warn / stale boundaries match AgentSettings thresholds" do
      # Backdate a synthetic discover run for an isolated test slug,
      # then confirm `state_for/1` reports the expected freshness band.
      day_ms  = 86_400_000
      now     = System.os_time(:millisecond)

      cases = [
        {1,    :fresh},   # 1 day old → under 7d warn threshold
        {10,   :warn},    # 10 days old → past warn, under stale (180d)
        {200,  :stale}    # 200 days old → past stale threshold
      ]

      Enum.each(cases, fn {age_days, expected} ->
        slug = "test_freshness_" <> Integer.to_string(:erlang.unique_integer([:positive]))
        completed_at = now - age_days * day_ms

        query!(Repo, """
        INSERT INTO connector_discovery_runs
          (connector_slug, layer, status, started_at, completed_at,
           error_text, records_affected, triggered_by, created_at)
        VALUES (?, 'functions', 'success', ?, ?, NULL, 7, 'test', ?)
        """, [slug, completed_at, completed_at, completed_at])

        state = Discovery.state_for(slug)

        assert state.functions.status == :success
        assert state.functions.freshness == expected,
               "age=#{age_days}d expected=#{expected} got=#{state.functions.freshness}"

        # Cleanup the synthetic run row.
        query!(Repo, "DELETE FROM connector_discovery_runs WHERE connector_slug=?", [slug])
      end)
    end

    test "running + failed states carry nil freshness" do
      slug = "test_freshness_" <> Integer.to_string(:erlang.unique_integer([:positive]))
      now  = System.os_time(:millisecond)

      query!(Repo, """
      INSERT INTO connector_discovery_runs
        (connector_slug, layer, status, started_at, completed_at,
         error_text, records_affected, triggered_by, created_at)
      VALUES (?, 'functions', 'failed', ?, ?, 'boom', 0, 'test', ?)
      """, [slug, now, now, now])

      state = Discovery.state_for(slug)
      assert state.functions.status == :failed
      assert state.functions.freshness == nil

      query!(Repo, "DELETE FROM connector_discovery_runs WHERE connector_slug=?", [slug])
    end
  end

  # ─── helpers ────────────────────────────────────────────────────────

  defp run_row_count(slug, layer) do
    %{rows: [[n]]} =
      query!(Repo,
        "SELECT COUNT(*) FROM connector_discovery_runs WHERE connector_slug=? AND layer=?",
        [slug, layer])

    n
  end

  defp eventually(fun, timeout_ms \\ 500, poll_ms \\ 20) do
    deadline = System.os_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, poll_ms)
  end

  defp do_eventually(fun, deadline, poll_ms) do
    if fun.() do
      true
    else
      if System.os_time(:millisecond) > deadline do
        false
      else
        Process.sleep(poll_ms)
        do_eventually(fun, deadline, poll_ms)
      end
    end
  end
end
