# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.WebCrawl.LinkScorer do
  @moduledoc """
  Per-depth relevance filter for the `web_crawl` tool's focused-BFS
  loop. Given the user's question + the candidate outbound links
  found at the current depth, returns the top-K links most likely
  to contain the answer.

  Backed by the Swift-tier LLM (`AgentSettings.swift_model`) — small,
  fast, batches all candidates at one depth boundary into ONE call.
  Latency: ~300 ms per depth boundary.

  Soft-fail philosophy: any error (timeout, transport, parse) returns
  ALL candidates verbatim (no pruning) so a flaky classifier never
  starves the crawl.
  """

  alias DmhAi.Agent.{AgentSettings, LLM}
  require Logger

  @doc """
  Pick up to `top_k` candidate links most relevant to `question`.

    * `question` — the user's exact phrasing, threaded through from the
      `web_crawl` tool's caller.
    * `candidates` — list of `{url, anchor_text}` tuples deduped from
      the current depth's pages.
    * `top_k` — how many to keep.

  Returns a list of `{url, anchor_text}` filtered to the model's
  picks. On any error returns `candidates` verbatim (capped at
  `top_k`) so the crawl still proceeds.
  """
  @spec pick([{String.t(), String.t()}], String.t(), pos_integer(), map()) :: [{String.t(), String.t()}]
  def pick(candidates, question, top_k, meta \\ %{})

  def pick(candidates, question, top_k, meta)
      when is_list(candidates) and is_binary(question) and is_integer(top_k) and is_map(meta) do
    cond do
      candidates == [] ->
        []

      length(candidates) <= top_k ->
        # No pruning needed — fewer candidates than we'd keep anyway.
        candidates

      question == "" ->
        # No question to filter against → fall back to first-N (caller
        # explicitly opted out of focused crawl by passing empty question).
        Enum.take(candidates, top_k)

      true ->
        do_pick(candidates, question, top_k, meta)
    end
  end
  def pick(_, _, _, _), do: []

  defp do_pick(candidates, question, top_k, meta) do
    indexed =
      candidates
      |> Enum.with_index(1)
      |> Enum.map(fn {{url, text}, i} -> {i, url, text} end)

    model = AgentSettings.swift_model()

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user",   content: user_prompt(question, indexed, top_k)}
    ]

    trace = %{
      origin: "system", path: "Tools.WebCrawl.LinkScorer.pick",
      role: "SwiftLinkScorer", phase: "pick",
      session_id: Map.get(meta, :session_id),
      user_id:    Map.get(meta, :user_id),
      tier:       :swift
    }

    case LLM.call(model, messages, options: %{temperature: 0}, trace: trace) do
      {:ok, text} when is_binary(text) ->
        case parse_picks(text, length(candidates)) do
          [] ->
            Logger.warning("[LinkScorer] empty parse from model output #{inspect(String.slice(text, 0, 120))}; keeping first-#{top_k}")
            Enum.take(candidates, top_k)

          picks ->
            picks
            |> Enum.take(top_k)
            |> Enum.map(fn idx -> Enum.at(candidates, idx - 1) end)
            |> Enum.reject(&is_nil/1)
        end

      other ->
        Logger.warning("[LinkScorer] swift call failed: #{inspect(other)}; keeping first-#{top_k}")
        Enum.take(candidates, top_k)
    end
  rescue
    e ->
      Logger.error("[LinkScorer] raised: #{Exception.message(e)}; keeping first-#{top_k}")
      Enum.take(candidates, top_k)
  end

  # ─── prompt ────────────────────────────────────────────────────────────

  defp system_prompt do
    """
    You are a focused-crawl link selector. The user has asked a question; another tool has fetched some web pages and found outbound links on them. Your only job is to pick which links to follow next.

    Rules:
    - Output ONLY a JSON array of integers — the index numbers from the candidate list. Example: [1, 4, 7]. NO prose, NO markdown, NO trailing comma.
    - Pick links whose URL path or anchor text plausibly leads to content that helps answer the question. Prefer specific sub-sections over generic landing / nav / about / contact pages.
    - If two candidates point at the same kind of content (e.g. two news posts), prefer the one whose anchor text mentions a keyword from the question.
    - Do NOT pick links that look like footer / legal / privacy / cookie / login / search / share / language-switch pages — those rarely contain primary content.
    - Stay within the requested count; pick fewer if fewer are truly relevant.
    """
  end

  defp user_prompt(question, indexed, top_k) do
    rows =
      indexed
      |> Enum.map(fn {i, url, text} -> "  [#{i}] #{text} — #{url}" end)
      |> Enum.join("\n")

    """
    Question: #{question}

    Candidate links:
    #{rows}

    Pick the indices (1-based) of up to #{top_k} candidates most likely to help answer the question. Reply with ONLY a JSON array of integers, e.g. [#{Enum.take_random(1..min(length(indexed), top_k), min(length(indexed), top_k)) |> Enum.sort() |> Enum.join(",")}].
    """
  end

  # ─── parse ────────────────────────────────────────────────────────────

  # Tolerant parser: accepts `[1, 2, 3]`, `1, 2, 3`, ` [ 1 ,  2 ]\n`, etc.
  defp parse_picks(text, max_idx) do
    text
    |> String.trim()
    |> extract_array_string()
    |> String.replace(["[", "]"], " ")
    |> String.split([",", " ", "\n", "\t"], trim: true)
    |> Enum.flat_map(fn s ->
      case Integer.parse(s) do
        {n, ""} when n >= 1 and n <= max_idx -> [n]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Pull the `[…]` substring if the model wrapped it in prose; otherwise
  # pass through.
  defp extract_array_string(text) do
    case Regex.run(~r/\[[^\]]*\]/, text) do
      [match] -> match
      _       -> text
    end
  end
end
