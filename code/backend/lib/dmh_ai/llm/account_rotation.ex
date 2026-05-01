# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.LLM.AccountRotation do
  @moduledoc """
  Picks one account from a pool's account list under a configurable
  strategy (`least_used` | `round_robin` | `random`), and persists
  throttle state when the LLM client reports rate-limiting / quota
  exhaustion against the chosen account.

  Throttled = `throttled_until` is in the future. Throttled accounts are
  filtered out of pick(); when every account is throttled, returns
  `{:error, :all_throttled, retry_after_ms}` so the caller can surface
  honestly to the user — never silent failover to a different pool.
  """

  alias DmhAi.LLM.Pools

  @doc """
  Pick one account from `pool` per its strategy. Marks the picked
  account's `last_used_ts` so the next `least_used` pick rotates fairly.
  """
  @spec pick(Pools.pool()) :: {:ok, map()} | {:error, :all_throttled, non_neg_integer()}
  def pick(pool) do
    now = System.os_time(:millisecond)
    {active, throttled} = partition(pool.accounts, now)

    cond do
      active != [] ->
        chosen = pick_strategy(pool.strategy, active, pool)
        Pools.update_account(pool.name, chosen["name"] || chosen["api_key"] || "",
                             mark_used: true,
                             rr_cursor: maybe_advance_cursor(pool, active, chosen))
        {:ok, chosen}

      throttled == [] ->
        # Empty pool — surface as :all_throttled with retry=0 so caller
        # asks the operator (no accounts configured at all).
        {:error, :all_throttled, 0}

      true ->
        retry_after = soonest_recovery_ms(throttled, now)
        {:error, :all_throttled, retry_after}
    end
  end

  @doc """
  Mark the named account in the named pool as throttled until
  `until_ms` (unix milliseconds). Persists onto the pool row so the
  block survives across BE restarts.
  """
  @spec mark_throttled(String.t(), String.t(), non_neg_integer()) :: :ok
  def mark_throttled(pool_name, account_name, until_ms) do
    Pools.update_account(pool_name, account_name, throttled_until: until_ms)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp partition(accounts, now) do
    Enum.split_with(accounts, fn acc ->
      tu = acc["throttled_until"]
      is_nil(tu) or tu <= now
    end)
  end

  defp pick_strategy("least_used", active, _pool) do
    # Smallest last_used_ts wins. nil counts as 0, ensuring fresh
    # accounts are picked first.
    Enum.min_by(active, fn acc -> acc["last_used_ts"] || 0 end)
  end

  defp pick_strategy("round_robin", active, pool) do
    cursor = pool.rr_cursor || 0
    idx    = rem(cursor, length(active))
    Enum.at(active, idx)
  end

  defp pick_strategy("random", active, _pool) do
    Enum.random(active)
  end

  defp pick_strategy(_unknown, active, _pool) do
    # Unknown strategy → fallback to least_used so we never crash on a
    # mis-configured pool. Operator sees the chosen one and edits.
    pick_strategy("least_used", active, nil)
  end

  defp maybe_advance_cursor(pool, active, chosen) do
    case pool.strategy do
      "round_robin" ->
        idx = Enum.find_index(active, &(&1["name"] == chosen["name"])) || 0
        rem(idx + 1, max(length(active), 1))

      _ ->
        nil
    end
  end

  defp soonest_recovery_ms(throttled, now) do
    earliest =
      throttled
      |> Enum.map(fn acc -> acc["throttled_until"] || (now + 60_000) end)
      |> Enum.min(fn -> now + 60_000 end)

    max(earliest - now, 0)
  end
end
