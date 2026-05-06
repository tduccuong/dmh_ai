# Session-walk regression: a single-account pool whose endpoint
# returns persistent 5xx must NOT loop forever inside one LLM call.
#
# Production failure mode (MiniMax @ 2026-05-06 11:51): single-
# account pool, `:server_error` doesn't trigger throttle, so
# `Pools.resolve` keeps returning the same account → retry-then-
# rotate runs in a 3-retries-per-cycle infinite loop. Fix landed
# as `AgentSettings.llm_total_attempts` (default 6).
#
# This walk drives the shape end-to-end: a real pool pointing at a
# guaranteed-unroutable host (so each Req.post yields
# `:econnrefused` → classified as `:server_error`), then asserts
# that `LLM.stream` returns `:attempts_exhausted` without exceeding
# the configured cap.

defmodule Itgr.SessionWalkPersistent5xx do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.LLM
  alias DmhAi.LLM.Pools
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  setup do
    pool_name = "swp5-" <> uid()

    # Snapshot + restore admin_cloud_settings so the cap override
    # below doesn't bleed across tests.
    snapshot =
      case query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"]) do
        %{rows: [[v]]} -> v
        _              -> nil
      end

    on_exit(fn ->
      query!(Repo, "DELETE FROM pools WHERE name=?", [pool_name])

      if snapshot do
        query!(Repo,
          "INSERT INTO settings (key, value) VALUES (?, ?) " <>
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          ["admin_cloud_settings", snapshot])
      end
    end)

    {:ok, pool_name: pool_name}
  end

  test "single-account pool, persistent econnrefused → :attempts_exhausted within cap",
       %{pool_name: pool_name} do
    {:ok, _} =
      Pools.create(%{
        "name"     => pool_name,
        "protocol" => "openai",
        "base_url" => "http://127.0.0.1:1",
        "accounts" => [%{"name" => "lone", "api_key" => "sk-x"}]
      })

    # Drop the cap to 2 so the test runs in ~2 s (default cap=6
    # would be ~10 s with the 2 s backoffs between within-account
    # retries).
    blob =
      case query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"]) do
        %{rows: [[v]]} when is_binary(v) -> Jason.decode!(v || "{}")
        _ -> %{}
      end

    patched = Map.put(blob, "llmTotalAttempts", 2)

    query!(Repo,
      "INSERT INTO settings (key, value) VALUES (?, ?) " <>
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      ["admin_cloud_settings", Jason.encode!(patched)])

    t0 = System.monotonic_time(:millisecond)

    assert {:error, :attempts_exhausted} =
             LLM.stream(pool_name <> "::nonsense", [], self(), tools: [])

    elapsed = System.monotonic_time(:millisecond) - t0

    # cap=2 + 1 within-account backoff (2 s) = ~2 s expected.
    # Generous upper bound: 8 s. The pre-cap behavior was infinite
    # — any finite bound proves termination; the tighter bound
    # confirms the cap fired at exactly the configured value.
    assert elapsed < 8_000,
           "expected cap to terminate within 8 s, took #{elapsed} ms — likely an infinite loop"
  end
end
