# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.VectorDB do
  @moduledoc """
  Vector knowledge base facade. Two responsibilities:

    1. Pick the active backend (`SqliteVec` in production, `Memory`
       in tests) per `:dmhai, :vector_db_backend` config and proxy
       the four behaviour methods.
    2. Expose `ingest/2` — the high-level pipeline that runs chunk →
       embed → tag → centroid-merge → upsert in one shot. The
       runtime command path (`/wiki`) and the `save_memo` LLM tool
       both call this.

  See `specs/vector_kb.md` for the full design.
  """

  alias Dmhai.Agent.AgentSettings
  alias Dmhai.VectorDB.{Backend, Chunker, Embedder, MMR, Sources, Tagger}

  @default_backend Dmhai.VectorDB.SqliteVec

  # ─── Backend proxies ───────────────────────────────────────────────────────

  @spec add([Backend.chunk_row()]) :: :ok | {:error, term()}
  def add(rows), do: backend().add(rows)

  @doc """
  Hybrid retrieval: vector cosine + BM25, fused via Reciprocal
  Rank Fusion, then MMR-diversified down to `k`.

    1. Vector top-`pool_size` (cosine via `Backend.search/4`).
    2. BM25 top-`pool_size` over `chunk_text` (FTS5 via
       `Backend.bm25_search/4`). Backends without an FTS5 index
       (Memory) return `[]`, leaving the path vector-only.
    3. RRF merge: for each hit, sum `1/(60 + rank_in_each_leg)`
       across the legs it appeared in, then sort by combined RRF.
    4. MMR re-rank the top-`pool_size` of that fused list to `k`,
       balancing relevance vs. diversity (`kb_mmr_lambda`).

  Pure vector callers (Memory backend, empty `query_text`) get
  the same behaviour as the pre-#182 path: backend.search → MMR.

  See specs/vector_kb.md §retrieval (#182).
  """
  @spec search(Backend.scope(), String.t(), [float()], pos_integer(), Backend.filter()) ::
          {:ok, [Backend.hit()]} | {:error, term()}
  def search(scope, query_text, query_vec, k, filter \\ :none) do
    pool_size = max(k, AgentSettings.kb_mmr_pool_size())
    lambda    = AgentSettings.kb_mmr_lambda()

    with {:ok, vec_hits}  <- backend().search(scope, query_vec, pool_size, filter),
         {:ok, bm25_hits} <- backend().bm25_search(scope, query_text || "", pool_size, filter) do
      fused = rrf_merge([vec_hits, bm25_hits], pool_size)
      {:ok, MMR.rerank(fused, k, lambda)}
    end
  end

  # Reciprocal Rank Fusion across N ranked lists. Each list is
  # ordered best-first (the backends already return them sorted).
  # For each hit, score = Σ over lists where it appears: 1/(k+rank).
  # k=60 is the standard RRF constant from the original paper —
  # mild tail damping that keeps non-top hits in play without
  # letting them out-vote a strongly-ranked winner.
  #
  # Hits are deduped across lists by `(source_kind, source_ref,
  # chunk_text)` triplet — same chunk reachable via vector AND
  # BM25 sums into one entry, the way RRF intends.
  defp rrf_merge(lists, pool_size) do
    rrf_k = 60

    lists
    |> Enum.flat_map(fn list ->
      list
      |> Enum.with_index(1)
      |> Enum.map(fn {hit, rank} -> {hit, 1.0 / (rrf_k + rank)} end)
    end)
    |> Enum.reduce(%{}, fn {hit, score}, acc ->
      key = dedup_key(hit)

      Map.update(acc, key, {hit, score}, fn {existing_hit, existing_score} ->
        # Keep the variant with the higher cosine score so MMR
        # downstream sees a sensible relevance signal — the BM25
        # leg's `score` is positional (1/rank), not comparable to
        # cosine. Preferring the cosine-scored copy when both
        # legs hit the same chunk avoids polluting MMR's input.
        better = if existing_hit.score >= hit.score, do: existing_hit, else: hit
        {better, existing_score + score}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {_hit, score} -> -score end)
    |> Enum.take(pool_size)
    |> Enum.map(fn {hit, _score} -> hit end)
  end

  defp dedup_key(hit) do
    {hit[:source_kind] || "", hit[:source_ref] || "", hit[:chunk_text] || ""}
  end

  @spec delete_by_source(Backend.scope(), integer()) :: :ok | {:error, term()}
  def delete_by_source(scope, source_id), do: backend().delete_by_source(scope, source_id)

  @spec count(Backend.scope(), String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(scope, user_id \\ nil), do: backend().count(scope, user_id)

  # ─── High-level ingest pipeline ────────────────────────────────────────────

  @doc """
  Chunk → embed → tag → (semantic-merge for inline text) → upsert.

  `attrs` shape:
    %{
      scope:       :knowledge | :memo,
      user_id:     String.t() | nil,    # required for :memo, must be nil for :knowledge
      source_kind: "text" | "file" | "url" | "folder",
      source_ref:  String.t(),
      title:       String.t() | nil
    }

  Returns `{:ok, %{indexed: chunks_count, source_id: id, merged_into: ref_or_nil}}`
  or `{:error, reason}`.
  """
  @spec ingest(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def ingest(attrs, body) when is_binary(body) do
    chunks = Chunker.split(body, chunker_opts_for(attrs[:scope] || attrs["scope"]))

    cond do
      chunks == [] ->
        {:error, :empty_body}

      true ->
        with {:ok, embeddings} <- Embedder.embed_batch(chunks) do
          centroid = average_embedding(embeddings)
          tags     = Tagger.tag(body)

          {effective_attrs, merged_into} = maybe_merge(attrs, centroid, tags)

          {:ok, source_id} = Sources.upsert(
            Map.merge(effective_attrs, %{centroid: centroid, tags: effective_attrs[:tags] || tags}),
            body
          )

          # Replace any existing chunks for this source_id (the upsert
          # deleted+reinserted the kb_sources row, so source_id is
          # fresh — but the backend may still hold stale rows under a
          # PRIOR id with the same source_ref. We sweep by source_ref
          # via Sources, then insert fresh chunks.)
          delete_by_source(effective_attrs.scope, source_id)
          rows = build_rows(effective_attrs, source_id, chunks, embeddings)

          case add(rows) do
            :ok ->
              {:ok, %{indexed: length(chunks), source_id: source_id, merged_into: merged_into}}

            err ->
              err
          end
        end
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp backend do
    Application.get_env(:dmhai, :vector_db_backend, @default_backend)
  end

  # Inline-text only: try to merge into an existing source with similar
  # centroid. URL/file/folder source_refs are deterministic — re-ingest
  # naturally overwrites without a similarity check.
  defp maybe_merge(%{source_kind: "text"} = attrs, centroid, tags) do
    threshold = AgentSettings.kb_text_merge_threshold()

    case Sources.nearest_centroid(attrs.scope, attrs[:user_id], centroid, threshold) do
      {:ok, existing} ->
        merged_tags = (existing.tags ++ tags) |> Enum.uniq() |> Enum.take(10)
        merged_attrs =
          attrs
          |> Map.put(:source_ref, existing.source_ref)
          |> Map.put(:tags, merged_tags)
          # Preserve existing title unless we're providing a fresh one
          |> Map.put_new_lazy(:title, fn -> existing.title end)

        {merged_attrs, existing.source_ref}

      :no_match ->
        {Map.put(attrs, :tags, tags), nil}
    end
  end

  defp maybe_merge(attrs, _centroid, tags), do: {Map.put(attrs, :tags, tags), nil}

  defp build_rows(attrs, source_id, chunks, embeddings) do
    now = System.os_time(:millisecond)

    chunks
    |> Enum.zip(embeddings)
    |> Enum.with_index()
    |> Enum.map(fn {{text, embedding}, idx} ->
      %{
        scope:       attrs.scope,
        user_id:     attrs[:user_id],
        source_id:   source_id,
        chunk_idx:   idx,
        chunk_text:  text,
        embedding:   embedding,
        indexed_at:  now,
        # Decoration consumed by the Memory backend (which doesn't
        # have a real kb_sources table to join against). SqliteVec
        # ignores these — it joins kb_sources at query time.
        _source_kind: attrs.source_kind,
        _source_ref:  attrs.source_ref,
        _title:       attrs[:title],
        _tags:        attrs[:tags] || []
      }
    end)
  end

  # Per-scope chunker config: `/memo` uses much smaller chunks
  # (short personal facts) than `/wiki` (long curated docs). See
  # the @kb_memo_chunk_* settings in AgentSettings for rationale.
  # Falls back to the wiki defaults if scope is unset/unknown.
  defp chunker_opts_for(:memo) do
    [
      max_tokens:     AgentSettings.kb_memo_chunk_tokens(),
      overlap_tokens: AgentSettings.kb_memo_chunk_overlap_tokens()
    ]
  end

  defp chunker_opts_for("memo"), do: chunker_opts_for(:memo)

  defp chunker_opts_for(_), do: []

  defp average_embedding([]), do: []
  defp average_embedding(embeddings) when is_list(embeddings) do
    n = length(embeddings)
    dim = embeddings |> List.first() |> length()

    sums = List.duplicate(0.0, dim)

    Enum.reduce(embeddings, sums, fn vec, acc ->
      Enum.zip(acc, vec) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / n))
  end
end
