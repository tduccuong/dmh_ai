# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.TokenTracker do
  @moduledoc """
  Per-(session, tier) and per-(user, tier) token-usage accounting.

  Every LLM call site reports `(rx, tx)` against a tier atom:

      :master    — the user-facing assistant chain
      :swift     — short single-shot calls (Compactor, Swift.localize,
                   session-naming, query planner, link scorer, KB tagger)
      :oracle    — ProfileExtractor and friends
      :vision    — image / video / OCR describers
      :embedding — embedding endpoint usage (kb_embedding_model)

  Reports land in `session_token_stats`. A session-scoped call writes
  to the row keyed by its `session_id`; a session-less call (e.g.
  ProfileExtractor or KB ingest tagging that runs at user-global
  scope) writes to a sentinel row keyed by `@user_global_sentinel`.
  `get_session_stats/1` exposes the per-session totals; `get_global_stats/1`
  sums across ALL rows for the user, including the sentinel row.

  ## DB-write hygiene

  These helpers run from inside the LLM adapter's streaming loop. If
  the SQLite writer slot is briefly held by another process, an
  Exqlite.Error here would propagate up uncaught and kill the agent's
  inline task, taking the whole chain down with it. Stat rows are
  non-critical accounting — degrade gracefully (Logger.warning, skip
  the row) rather than crash. See architecture.md §DB-write hygiene
  for the SQLite writer slot.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @tiers [:master, :swift, :oracle, :vision, :embedding]

  # Sentinel session_id for LLM calls that have no session context
  # (ProfileExtractor extraction, KB ingest tagging, etc). Same row
  # shape as a real session — the FE never displays it under a session
  # name; only `get_global_stats/1` reads it.
  @user_global_sentinel "_user_global"

  @doc "The canonical list of tier atoms understood by `add/5`."
  def tiers, do: @tiers

  @doc """
  Credit `(rx, tx)` tokens against `(session_id, user_id, tier)`. When
  `session_id` is `nil`, the credit lands on the per-user sentinel row
  so `get_global_stats/1` can still see it.

  Skips the write when both rx and tx are 0 (LLM call returned no
  usage — common for streaming endpoints that don't emit usage). Logs
  and swallows on any DB error.
  """
  @spec add(String.t() | nil, String.t(), atom(), non_neg_integer(), non_neg_integer()) :: :ok
  def add(session_id, user_id, tier, rx, tx) when tier in @tiers and (rx > 0 or tx > 0) do
    rx_col = "#{tier}_rx_tokens"
    tx_col = "#{tier}_tx_tokens"
    sid    = session_id || @user_global_sentinel
    now    = System.os_time(:millisecond)

    sql =
      "INSERT INTO session_token_stats (session_id, user_id, #{rx_col}, #{tx_col}, updated_at) " <>
        "VALUES (?,?,?,?,?) " <>
        "ON CONFLICT(session_id) DO UPDATE SET " <>
        "  #{rx_col} = #{rx_col} + excluded.#{rx_col}, " <>
        "  #{tx_col} = #{tx_col} + excluded.#{tx_col}, " <>
        "  updated_at = excluded.updated_at"

    try do
      query!(Repo, sql, [sid, user_id, rx, tx, now])
    rescue
      e ->
        Logger.warning(
          "[TokenTracker] add tier=#{tier} session=#{sid} skipped: #{Exception.message(e)}"
        )
    end

    :ok
  end

  def add(_, _, _, _, _), do: :ok

  @doc """
  Read per-tier rx/tx totals for `session_id`. Returns a map keyed by
  the tier atoms in `tiers/0`; missing tiers return `%{rx: 0, tx: 0}`.
  """
  @spec get_session_stats(String.t()) :: %{atom() => %{rx: integer(), tx: integer()}}
  def get_session_stats(session_id) do
    cols = tier_select_cols()

    row =
      try do
        r = query!(Repo, "SELECT #{cols} FROM session_token_stats WHERE session_id=?", [session_id])
        case r.rows do
          [vals] when is_list(vals) -> vals
          _                          -> List.duplicate(0, length(@tiers) * 2)
        end
      rescue
        _ -> List.duplicate(0, length(@tiers) * 2)
      end

    decode_tier_row(row)
  end

  @doc """
  Read per-tier rx/tx totals for `user_id`, summed across ALL
  session_token_stats rows (every real session plus the per-user
  sentinel row).
  """
  @spec get_global_stats(String.t()) :: %{atom() => %{rx: integer(), tx: integer()}}
  def get_global_stats(user_id) do
    sum_cols =
      @tiers
      |> Enum.flat_map(fn tier ->
        ["COALESCE(SUM(#{tier}_rx_tokens),0)", "COALESCE(SUM(#{tier}_tx_tokens),0)"]
      end)
      |> Enum.join(", ")

    row =
      try do
        r = query!(Repo, "SELECT #{sum_cols} FROM session_token_stats WHERE user_id=?", [user_id])
        case r.rows do
          [vals] when is_list(vals) -> vals
          _                          -> List.duplicate(0, length(@tiers) * 2)
        end
      rescue
        _ -> List.duplicate(0, length(@tiers) * 2)
      end

    decode_tier_row(row)
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp tier_select_cols do
    @tiers
    |> Enum.flat_map(fn tier -> ["#{tier}_rx_tokens", "#{tier}_tx_tokens"] end)
    |> Enum.join(", ")
  end

  # Decode the flat [rx0, tx0, rx1, tx1, ...] row into the per-tier map.
  defp decode_tier_row(values) do
    @tiers
    |> Enum.with_index()
    |> Enum.into(%{}, fn {tier, i} ->
      rx = Enum.at(values, i * 2) || 0
      tx = Enum.at(values, i * 2 + 1) || 0
      {tier, %{rx: to_int(rx), tx: to_int(tx)}}
    end)
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(_), do: 0
end
