# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.MMR do
  @moduledoc """
  Maximum Marginal Relevance (MMR) re-ranker for retrieval results.
  Used to diversify the top-N hits returned by `DmhAi.VectorDB.search/4`
  so near-duplicate chunks don't crowd out genuinely different
  perspectives on the query.

  Concrete failure mode this fixes (observed in production trace,
  see specs/vector_kb.md §retrieval): a query like "Bitrix24 REST API
  automation endpoint" returned 4 chunks of nearly-identical
  error-handling boilerplate copied across different Bitrix24 doc
  pages. Pure cosine ranking happily returns four near-clones; MMR
  recognises the redundancy and replaces three of them with the next
  best non-redundant candidates.

  ## Algorithm

  Iterative pick:

      while |selected| < final_k:
        pick c ∈ candidates \\ selected maximising
          λ · rel(c) - (1 - λ) · max_{s ∈ selected} sim(c, s)

  - `rel(c)` = the candidate's cosine score from the vector search.
  - `sim(c, s)` = pairwise text similarity between two candidates,
    measured as Jaccard overlap of word-token sets. Cheap, deterministic,
    and exactly catches the "different doc, same boilerplate" failure
    mode (verbatim text overlap → high Jaccard → MMR drops the dup).
    Chunk *embeddings* would be the textbook similarity signal but our
    backend doesn't surface them on the search result, and Jaccard on
    chunk_text is sufficient for the workload.
  - λ ∈ [0, 1]: 1.0 = pure relevance (no diversification — equivalent
    to top-k cosine), 0.0 = pure novelty.

  ## Complexity

  O(pool_size × final_k) Jaccard evaluations. Each Jaccard is over
  pre-tokenised MapSets so the inner step is O(|tokens|). For
  pool=30, final=8, ~250-token chunks → a few ms per search call.
  No persistence; tokens computed on the fly per query.
  """

  @doc """
  Re-rank `hits` from highest combined score to lowest, returning at
  most `final_k`. Each hit must carry `:chunk_text` (binary) and
  `:score` (float). On a list shorter than or equal to `final_k`,
  returned as-is.

  `lambda_val` is the relevance / diversity trade-off.
  """
  @spec rerank([map()], pos_integer(), float()) :: [map()]
  def rerank(hits, final_k, lambda_val)
      when is_list(hits) and is_integer(final_k) and final_k > 0 and is_float(lambda_val) do
    cond do
      length(hits) <= final_k -> hits

      lambda_val >= 1.0 ->
        # Pure relevance — MMR collapses to top-k by cosine. Skip
        # the work, just take the head.
        Enum.take(hits, final_k)

      true ->
        do_rerank(hits, final_k, lambda_val)
    end
  end

  defp do_rerank(hits, final_k, lambda_val) do
    # Pre-tokenise once. Carry the token set on the hit map under a
    # private key — it's never returned to callers.
    pool =
      Enum.map(hits, fn h ->
        Map.put(h, :__mmr_tokens, tokens(h.chunk_text))
      end)

    {selected_rev, _remaining} =
      Enum.reduce(1..final_k, {[], pool}, fn _i, {selected, remaining} ->
        case remaining do
          [] ->
            {selected, []}

          _ ->
            {best, rest} = pick_best(remaining, selected, lambda_val)
            {[best | selected], rest}
        end
      end)

    selected_rev
    |> Enum.reverse()
    |> Enum.map(&Map.delete(&1, :__mmr_tokens))
  end

  # Walk every remaining candidate, score it via the MMR formula
  # against the already-selected set, return the winner + the
  # remaining-minus-winner list. O(pool · |selected| · |tokens|).
  defp pick_best(remaining, selected, lambda_val) do
    {best, _best_score} =
      Enum.reduce(remaining, {nil, :neg_infinity}, fn cand, {curr_best, curr_score} ->
        rel = cand.score || 0.0

        max_redundancy =
          case selected do
            [] ->
              0.0

            _ ->
              Enum.reduce(selected, 0.0, fn s, acc ->
                j = jaccard(cand.__mmr_tokens, s.__mmr_tokens)
                if j > acc, do: j, else: acc
              end)
          end

        score = lambda_val * rel - (1.0 - lambda_val) * max_redundancy

        if curr_score == :neg_infinity or score > curr_score do
          {cand, score}
        else
          {curr_best, curr_score}
        end
      end)

    {best, List.delete(remaining, best)}
  end

  # Word-level token set: lowercase, strip punctuation, drop
  # length-1 tokens (mostly noise). Punctuation-stripping uses a
  # regex split that is fast in practice for chunks under ~2000
  # chars.
  @doc false
  def tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) <= 1))
    |> MapSet.new()
  end

  def tokens(_), do: MapSet.new()

  # Jaccard index. 1.0 = identical token sets, 0.0 = disjoint.
  @doc false
  def jaccard(a, b) do
    sa = MapSet.size(a)
    sb = MapSet.size(b)

    cond do
      sa == 0 and sb == 0 -> 0.0
      sa == 0 or sb == 0  -> 0.0
      true ->
        inter = MapSet.intersection(a, b) |> MapSet.size()
        union = sa + sb - inter
        inter / union
    end
  end
end
