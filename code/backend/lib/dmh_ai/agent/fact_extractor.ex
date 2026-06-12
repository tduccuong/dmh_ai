# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.FactExtractor do
  @moduledoc """
  Continuously distils atomic facts about the user from their own messages
  and indexes them into facts.db. Runs as a background Task after each user
  message persists; never blocks a reply.

  Batched, watermark-driven (watermark lives in `facts.db`'s `facts_watermark`
  table, keyed by user). On each fire it walks `sessions.messages` for all of
  this user's sessions and counts user-role entries above the watermark; below
  `AgentSettings.fact_extract_batch_size/0` (default 3) → no-op. At or above →
  one SWIFT LLM call over the oldest N, parse the returned atomic facts, and
  `Kb.index` each into facts.db (deduped). Slash commands are excluded from the
  batch but still advance the watermark.

  See arch_wiki/dmh_ai/facts_memos.md.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]
  alias DmhAi.{Repo, FactsRepo, Kb}
  alias DmhAi.Agent.{AgentSettings, LLM}
  alias DmhAi.Commands.Parser, as: CommandParser
  require Logger

  @spec extract(String.t()) :: :ok
  def extract(user_id) when is_binary(user_id) do
    batch_size = AgentSettings.fact_extract_batch_size()
    watermark = load_watermark(user_id)

    case collect_unprocessed(user_id, watermark) do
      msgs when length(msgs) < batch_size ->
        :ok

      msgs ->
        run_batch(user_id, Enum.take(msgs, batch_size))
    end

    :ok
  end

  # ─── Batch collection ──────────────────────────────────────────────────────

  defp collect_unprocessed(user_id, watermark) do
    query!(
      Repo,
      "SELECT messages FROM sessions WHERE user_id=? AND messages IS NOT NULL AND messages != ''",
      [user_id]
    ).rows
    |> Enum.flat_map(fn [json] -> decode_user_msgs(json) end)
    |> Enum.filter(fn %{ts: ts} -> ts > watermark end)
    |> Enum.sort_by(fn %{ts: ts} -> ts end)
  end

  defp decode_user_msgs(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.flat_map(list, fn
          %{"role" => "user", "content" => content, "ts" => ts}
          when is_binary(content) and is_integer(ts) ->
            [%{ts: ts, content: content}]

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp decode_user_msgs(_), do: []

  # ─── Batch processing ──────────────────────────────────────────────────────

  defp run_batch(user_id, batch) do
    last_ts = batch |> List.last() |> Map.fetch!(:ts)

    extractable =
      batch
      |> Enum.reject(fn %{content: c} -> CommandParser.parse(c) != :not_a_command end)
      |> Enum.map(& &1.content)
      |> Enum.reject(&(&1 == ""))

    if extractable == [] do
      save_watermark(user_id, last_ts)
    else
      do_extract(user_id, extractable, last_ts)
    end

    :ok
  end

  defp do_extract(user_id, msgs, last_ts) do
    model = AgentSettings.swift_model()

    numbered =
      msgs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {m, i} -> "#{i}. \"#{m}\"" end)

    trace = %{
      origin: "system",
      path: "FactExtractor.extract",
      role: "FactExtractor",
      phase: "extract",
      session_id: nil,
      user_id: user_id,
      tier: :swift
    }

    case LLM.call(model, [%{role: "user", content: fact_prompt(numbered)}],
           options: %{temperature: 0, num_predict: 500},
           trace: trace
         ) do
      {:ok, reply} when is_binary(reply) and reply != "" ->
        facts = parse_facts(reply)
        indexed = Enum.count(facts, fn f -> Kb.index(FactsRepo, "facts", user_id, f, "extractor") == :ok end)
        Logger.info("[FactExtractor] user=#{user_id} batch=#{length(msgs)} facts=#{length(facts)} new=#{indexed}")
        save_watermark(user_id, last_ts)

      _ ->
        :ok
    end

    :ok
  end

  defp fact_prompt(numbered) do
    """
    [USER MESSAGES — most recent across this user's conversations]
    #{numbered}
    [END USER MESSAGES]

    Distil every durable fact about the USER that could help personalise future replies. Write each as one short, self-contained statement, phrased in the third person and in English.

    Capture anything that reveals who they are or what they care about:
    - Stable traits and life facts — a family detail, where they live, what they do for work.
    - Preferences, tastes, and opinions — what they like, dislike, or favour.
    - Interests and topics they engage with — subjects, hobbies, or media they follow.
    - Actions and events — something they did or that happened, with the date when one is given (ISO format, e.g. 2025-09-01).
    - Goals, plans, and things they have asked about — what they intend to do or are looking into.

    Rules:
    - One fact per line, each prefixed with "- ". Keep each under about 15 words and specific.
    - Cover facts the user states directly AND clear signals from what they do or ask.
    - Output only the fact lines. Write NONE when there is nothing worth remembering.

    Messages may be in any language; always output English. Plain text only.
    """
  end

  defp parse_facts(reply) do
    reply
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "-"))
    |> Enum.map(fn line ->
      line
      |> String.trim_leading("- ")
      |> String.trim_leading("-")
      |> String.trim()
      |> String.replace(~r/\*{1,3}([^*]*)\*{1,3}/, "\\1")
    end)
    |> Enum.reject(&(&1 == "" or String.downcase(&1) == "none"))
    |> Enum.uniq()
  end

  # ─── Watermark (lives in facts.db) ──────────────────────────────────────────

  defp load_watermark(user_id) do
    case FactsRepo.query!("SELECT last_ts FROM facts_watermark WHERE user_id=?", [user_id]).rows do
      [[ts]] when is_integer(ts) -> ts
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp save_watermark(user_id, ts) when is_integer(ts) do
    FactsRepo.query!(
      "INSERT INTO facts_watermark(user_id, last_ts) VALUES (?, ?) " <>
        "ON CONFLICT(user_id) DO UPDATE SET last_ts=excluded.last_ts",
      [user_id, ts]
    )

    :ok
  rescue
    _ -> :ok
  end
end
