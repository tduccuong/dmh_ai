# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB do
  @moduledoc """
  Vector knowledge base facade. Two responsibilities:

    1. Pick the active backend (`SqliteVec` in production, `Memory`
       in tests) per `:dmh_ai, :vector_db_backend` config and proxy
       the four behaviour methods.
    2. Expose `ingest/2` — the high-level pipeline that runs chunk →
       embed → tag → centroid-merge → upsert in one shot. The
       runtime command path (`/index`) and the `save_memo` LLM tool
       both call this.

  See `specs/vector_kb.md` for the full design.
  """

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.VectorDB.{Backend, Chunker, Embedder, MMR, Sources, SqliteVec, Tagger}
  alias DmhAi.MemoCrypto
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_backend DmhAi.VectorDB.SqliteVec

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
    {hit[:source_kind] || "", hit[:source_id] || "", hit[:chunk_text] || ""}
  end

  @spec delete_by_source(Backend.scope(), integer()) :: :ok | {:error, term()}
  def delete_by_source(scope, source_id), do: backend().delete_by_source(scope, source_id)

  # `scope_arg` is `org_id` for `:knowledge`, `user_id` for `:memo`.
  @spec count(Backend.scope(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(scope, scope_arg), do: backend().count(scope, scope_arg)

  # ─── High-level ingest pipeline ────────────────────────────────────────────

  @doc """
  Two-phase memo ingest — phase 1 (synchronous): chunk + encrypt +
  persist `kb_chunks_meta` rows WITHOUT computing the embedding.
  Returns `{:ok, %{source_id, chunks: [{meta_id, plaintext, chunk_idx}]}}`
  so the caller can fire the slow embedder HTTP call in the
  background and follow up with `attach_memo_embedding/2` per chunk.

  This is the path taken by `/memo` so the user sees "Memo saved."
  instantly (no embedder round-trip on the critical path). The
  `fetch_memo` / Confidant pre-step paths still use the synchronous
  `ingest/2` because they need the row searchable on return.

  Memo scope only — passing any other scope returns
  `{:error, :memo_scope_required}`.
  """
  @spec ingest_memo_async(map()) :: {:ok, map()} | {:error, term()}
  def ingest_memo_async(%{scope: :memo} = attrs) do
    %{org_id: org_id, user_id: user_id, source_kind: kind, source_ref: ref,
      memo_key: mmk, body: body} = attrs

    cond do
      not is_binary(body) or body == "" ->
        {:error, :empty_body}

      not is_binary(mmk) ->
        {:error, :memo_key_unavailable}

      not is_binary(org_id) or org_id == "" ->
        {:error, :org_id_required}

      true ->
        chunks = Chunker.split(body, chunker_opts_for(:memo))

        if chunks == [] do
          {:error, :empty_body}
        else
          # Memo dedupes by source_ref (sha256 hash of text). No
          # centroid-based merge — that would require the embedding,
          # which is exactly what we're deferring.
          #
          # Skip Tagger.tag/1 — it makes an Oracle-tier LLM call to
          # extract free-form tags, which on a slow miner/cloud
          # endpoint can be 5–15 s. Memo retrieval is vector + MMR
          # only; tags don't drive scoring for memo scope, so they're
          # decorative-only and not worth the latency on the
          # synchronous /memo path. Index paths still tag via the
          # synchronous `ingest/2`.
          {:ok, source_id} = Sources.upsert_memo(
            %{
              org_id: org_id,
              user_id: user_id,
              source_kind: kind,
              source_id: ref,
              title: attrs[:title],
              centroid: nil,
              tags: []
            },
            body
          )

          # Sweep any prior chunks for this source_id (idempotent re-save).
          delete_by_source(:memo, source_id)

          now = System.os_time(:millisecond)

          chunk_records =
            chunks
            |> Enum.with_index()
            |> Enum.map(fn {plaintext, idx} ->
              ciphertext = MemoCrypto.encrypt_chunk(plaintext, mmk, source_id, idx)

              %{rows: [[meta_id]]} =
                query!(Repo, """
                INSERT INTO memo_chunks_meta (org_id, user_id, source_id, chunk_idx, chunk_text, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?)
                RETURNING id
                """, [org_id, user_id, source_id, idx, ciphertext, now])

              %{meta_id: meta_id, plaintext: plaintext, chunk_idx: idx}
            end)

          {:ok, %{source_id: source_id, chunks: chunk_records}}
        end
    end
  end

  def ingest_memo_async(_), do: {:error, :memo_scope_required}

  @doc """
  Phase 2 of the memo two-phase save: attach an embedding vector to
  a previously-inserted `kb_chunks_meta` row. Inserts into
  `kb_vec_memo` keyed on the same rowid. Idempotent-ish — a second
  call for the same `meta_id` raises (PK violation), which is fine
  because the spawned background task per save is one-shot.
  """
  @spec attach_memo_embedding(integer(), [float()]) :: :ok | {:error, term()}
  def attach_memo_embedding(meta_id, embedding) when is_integer(meta_id) and is_list(embedding) do
    encoded = SqliteVec.encode_vector(embedding)
    query!(Repo, "INSERT INTO kb_vec_memo(rowid, embedding) VALUES (?, CAST(? AS BLOB))",
           [meta_id, encoded])
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Chunk → embed → tag → (semantic-merge for inline text) → upsert.
  Synchronous: returns only after the embedder pool has produced
  vectors and the meta+vec rows are inserted. Used by `/index` paths
  and the `save_memo` Assistant tool. The slash-command `/memo` path
  uses the async variant `ingest_memo_async/1` to avoid blocking the
  user-visible ack on the embedder HTTP call.

  `attrs` shape:
    %{
      scope:       :knowledge | :memo,
      org_id:      String.t(),         # required (both scopes); FK organizations.id
      user_id:     String.t() | nil,   # required for :memo, ignored for :knowledge
      source_kind: "text" | "file" | "url" | "folder",
      source_ref:  String.t(),
      title:       String.t() | nil
    }

  Returns `{:ok, %{indexed: chunks_count, source_id: id, merged_into: ref_or_nil}}`
  or `{:error, reason}`.
  """
  @spec ingest(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def ingest(attrs, body) when is_binary(body) do
    scope = attrs[:scope] || attrs["scope"]

    case scope do
      :knowledge ->
        # Knowledge ingest owns Primitive 0.2's three guarantees
        # (idempotent / fresh / removable). The full pipeline —
        # content-hash gate, chunk + embed + tag, atomic replace —
        # lives in DmhAi.Ingest. VectorDB just forwards.
        DmhAi.Ingest.upsert_kb_source(attrs, body)

      :memo ->
        ingest_memo(attrs, body)

      _ ->
        {:error, :unknown_scope}
    end
  end

  defp ingest_memo(attrs, body) do
    chunks = Chunker.split(body, chunker_opts_for(:memo))

    cond do
      chunks == [] ->
        {:error, :empty_body}

      not is_binary(attrs[:memo_key]) ->
        {:error, :memo_key_unavailable}

      not is_binary(attrs[:org_id]) or attrs[:org_id] == "" ->
        {:error, :org_id_required}

      not is_binary(attrs[:user_id]) or attrs[:user_id] == "" ->
        {:error, :user_id_required_for_memo}

      true ->
        with {:ok, embeddings} <- Embedder.embed_batch(chunks) do
          centroid = average_embedding(embeddings)
          tags     = Tagger.tag(body)

          # Memo doesn't centroid-merge against KB — different corpus.
          effective_attrs = Map.put(attrs, :tags, tags)
          source_id = memo_source_id(effective_attrs)

          {:ok, internal_id} =
            Sources.upsert_memo(
              Map.merge(effective_attrs, %{
                centroid: centroid,
                source_id: source_id
              }),
              body
            )

          delete_by_source(:memo, internal_id)
          rows = build_rows(effective_attrs, internal_id, source_id, chunks, embeddings)

          case add(rows) do
            :ok ->
              {:ok, %{indexed: length(chunks), source_id: source_id, internal_id: internal_id}}

            err ->
              err
          end
        end
    end
  end

  defp memo_source_id(%{source_id: sid}) when is_binary(sid) and sid != "", do: sid

  defp memo_source_id(%{source_ref: ref}) when is_binary(ref) and ref != "", do: ref

  # ─── Private ──────────────────────────────────────────────────────────────

  defp backend do
    Application.get_env(:dmh_ai, :vector_db_backend, @default_backend)
  end

  defp build_rows(attrs, internal_id, source_id, chunks, embeddings) do
    now = System.os_time(:millisecond)
    scope = attrs[:scope] || attrs["scope"]
    memo_key = if scope == :memo, do: attrs[:memo_key], else: nil

    chunks
    |> Enum.zip(embeddings)
    |> Enum.with_index()
    |> Enum.map(fn {{text, embedding}, idx} ->
      stored_text =
        if memo_key do
          # AES-GCM encrypt under the user's MMK. AAD binds the row
          # to (internal_id, chunk_idx) so a row physically copied
          # to another position fails the auth-tag check on read.
          MemoCrypto.encrypt_chunk(text, memo_key, internal_id, idx)
        else
          text
        end

      base = %{
        scope:       scope,
        org_id:      attrs.org_id,
        source_id:   internal_id,
        chunk_idx:   idx,
        chunk_text:  stored_text,
        embedding:   embedding,
        indexed_at:  now,
        # Decoration consumed by the Memory backend (which doesn't
        # have a real sources table to join against). SqliteVec
        # ignores these — it joins kb_sources / memo_sources at
        # query time.
        _source_kind: attrs.source_kind,
        _source_ref:  source_id,
        _title:       attrs[:title],
        _tags:        attrs[:tags] || []
      }

      if scope == :memo, do: Map.put(base, :user_id, attrs.user_id), else: base
    end)
  end

  # Per-scope chunker config: `/memo` uses much smaller chunks
  # (short personal facts) than `/index` (long curated docs). See
  # the @kb_memo_chunk_* settings in AgentSettings for rationale.
  # Falls back to the index defaults if scope is unset/unknown.
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
