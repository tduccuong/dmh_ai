# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Compactor do
  @moduledoc """
  Conversation-history compaction for Assistant chains.

  The runtime keeps the conversation tail bounded by replacing the oldest
  rounds with an LLM-generated summary message at chain start. A **round**
  is one user message plus the assistant chain it triggered (an assistant
  chain is one or more LLM turns ending in user-facing text).

  Triggered before the first LLM call of a chain (pre-LLM step) by
  `DmhAi.Agent.UserAgent.run_assistant`. Subsequent turns within the same
  chain do NOT re-compact — once a chain starts, its tail grows
  monotonically until end. See architecture.md §Compaction.

  Thresholds + budget are configurable via `DmhAi.Agent.AgentSettings`:

    * `compaction_high_water_chars` — trigger threshold
    * `compaction_low_water_chars`  — tail target after compaction
    * `compaction_keep_recent_rounds` — floor of rounds preserved verbatim
    * `compaction_summary_max_tokens` — LLM summary budget

  The cut point sits at a user-message boundary (start of a round), so a
  `tool_call` and its corresponding `tool_result` never straddle the
  summary boundary. The floor (`compaction_keep_recent_rounds`) wins over
  the low-water target — if preserving N rounds keeps the tail above
  low-water, the cut stays at the floor.
  """

  alias DmhAi.{Agent.AgentSettings, Agent.LLM, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Compact the session's history if total tail chars exceed
  `compaction_high_water_chars`. No-op when below threshold or when there
  aren't enough rounds to safely cut.

  On success, writes the new summary to `sessions.context.summary` and the
  cut point to `sessions.context.summary_up_to_index`.

  Returns `{:compacted, kept_chars}`, `:skipped`, or `:error`.
  """
  @spec maybe_compact(String.t(), String.t()) :: {:compacted, non_neg_integer()} | :skipped | :error
  def maybe_compact(session_id, user_id) when is_binary(session_id) and is_binary(user_id) do
    case load_session(session_id) do
      {:ok, msgs, ctx} ->
        do_maybe_compact(session_id, user_id, msgs, ctx)

      :error ->
        :error
    end
  rescue
    e ->
      Logger.error("[Compactor] crashed session=#{session_id}: #{Exception.message(e)}")
      :error
  end

  defp do_maybe_compact(session_id, user_id, msgs, ctx) do
    cutoff = ctx["summary_up_to_index"] || -1
    tail = Enum.drop(msgs, cutoff + 1)
    tail_chars = total_chars(tail)
    high_water = AgentSettings.compaction_high_water_chars()

    if tail_chars <= high_water do
      :skipped
    else
      do_compact(session_id, user_id, msgs, tail, ctx, cutoff, tail_chars)
    end
  end

  defp do_compact(session_id, user_id, all_msgs, tail, ctx, cutoff, tail_chars) do
    keep_rounds = AgentSettings.compaction_keep_recent_rounds()
    low_water = AgentSettings.compaction_low_water_chars()

    case pick_cut_index(tail, keep_rounds, low_water) do
      {:cut, local_cut} when local_cut > 0 ->
        # `local_cut` is the FIRST tail index to PRESERVE verbatim.
        # Everything before it (in the tail) gets summarised, plus
        # whatever was already covered by a prior summary.
        absolute_cut = cutoff + 1 + local_cut
        to_summarise = Enum.slice(all_msgs, 0, absolute_cut)
        kept = Enum.slice(all_msgs, absolute_cut..-1//1) || []

        case run_summary_llm(to_summarise, ctx["summary"], session_id, user_id) do
          {:ok, summary} ->
            new_ctx = %{
              "summary" => summary,
              "summary_up_to_index" => absolute_cut - 1
            }

            persist_context(session_id, user_id, new_ctx)
            kept_chars = total_chars(kept)

            Logger.info(
              "[Compactor] session=#{session_id} tail_before=#{tail_chars} " <>
                "kept_chars=#{kept_chars} cut=#{absolute_cut} summary_chars=#{String.length(summary)}"
            )

            {:compacted, kept_chars}

          :error ->
            Logger.warning("[Compactor] summary LLM failed session=#{session_id}; keeping tail intact")
            :error
        end

      _ ->
        # Not enough rounds in the tail to safely cut without violating
        # the keep-recent floor. Skip.
        :skipped
    end
  end

  # Walk the tail and identify the cut index in tail-local coordinates.
  # Returns:
  #   * `{:cut, idx}` — tail messages [0..idx-1] become the summary;
  #     [idx..] stay verbatim. `idx` lands at a user-message boundary,
  #     so tool_call/tool_result pairs never straddle the cut.
  #   * `:skip` — tail has fewer than `keep_rounds + 1` user messages,
  #     not enough to cut anything while preserving the floor.
  @spec pick_cut_index([map()], pos_integer(), pos_integer()) :: {:cut, non_neg_integer()} | :skip
  def pick_cut_index(tail, keep_rounds, low_water) do
    user_indices =
      tail
      |> Enum.with_index()
      |> Enum.filter(fn {m, _i} -> role_of(m) == "user" end)
      |> Enum.map(fn {_m, i} -> i end)

    n = length(user_indices)

    cond do
      n <= keep_rounds ->
        # Not enough rounds in tail to cut anything.
        :skip

      true ->
        # The keep-recent-rounds floor wins: keep the LAST `keep_rounds`
        # user messages (and everything that follows them). Cut at the
        # user-message index that starts the FIRST kept round.
        floor_cut = Enum.at(user_indices, n - keep_rounds)

        # If keeping only `floor_cut` is enough to satisfy low-water,
        # we could cut MORE (earlier rounds further). But the spec says
        # the floor wins over low-water — so we don't go past `floor_cut`.
        # The `low_water` arg is purely informational here: future
        # tuning could expand cuts when low-water is wildly exceeded.
        _ = low_water

        {:cut, floor_cut}
    end
  end

  # ─── LLM call ─────────────────────────────────────────────────────────

  defp run_summary_llm(to_summarise, prior_summary, session_id, user_id) do
    msgs =
      prior_prefix(prior_summary) ++
        Enum.map(to_summarise, fn m ->
          %{role: role_of(m), content: m["content"] || ""}
        end) ++
        [
          %{
            role: "user",
            content:
              "Summarise the conversation above concisely but completely. " <>
                "Preserve: user goals, decisions made, tool calls and their notable findings, " <>
                "files / references / identifiers worth carrying forward, ongoing context. " <>
                "Discard: repetitive exchanges, restated facts, false starts, conversational filler. " <>
                "Be dense and factual."
          }
        ]

    opts = [
      max_tokens: AgentSettings.compaction_summary_max_tokens(),
      trace: %{
        origin: "system",
        path: "Agent.Compactor.summarise",
        role: "Compactor",
        phase: "compact",
        session_id: session_id,
        user_id: user_id,
        tier: :swift
      }
    ]

    case LLM.call(AgentSettings.swift_model(), msgs, opts) do
      {:ok, text} when is_binary(text) and byte_size(text) > 0 ->
        {:ok, String.trim(text)}

      other ->
        Logger.warning("[Compactor] LLM call failed: #{inspect(other)}")
        :error
    end
  end

  defp prior_prefix(nil), do: []
  defp prior_prefix(""), do: []

  defp prior_prefix(summary) when is_binary(summary) do
    [
      %{role: "user", content: "[Previous summary]\n" <> summary},
      %{role: "assistant", content: "Understood."}
    ]
  end

  # ─── DB I/O ──────────────────────────────────────────────────────────

  defp load_session(session_id) do
    case query!(Repo, "SELECT messages, context FROM sessions WHERE id=?", [session_id]) do
      %{rows: [[msgs_json, ctx_json]]} ->
        msgs = Jason.decode!(msgs_json || "[]")

        ctx =
          case Jason.decode(ctx_json || "{}") do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        {:ok, msgs, ctx}

      _ ->
        :error
    end
  end

  defp persist_context(session_id, _user_id, ctx) do
    query!(Repo, "UPDATE sessions SET context=?, updated_at=? WHERE id=?", [
      Jason.encode!(ctx),
      :os.system_time(:millisecond),
      session_id
    ])

    :ok
  end

  # ─── Helpers ─────────────────────────────────────────────────────────

  defp role_of(m), do: m["role"] || m[:role] || "user"

  defp total_chars(msgs) do
    Enum.reduce(msgs, 0, fn m, acc ->
      acc + byte_size(to_string(m["content"] || ""))
    end)
  end
end
