# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Ingest do
  @moduledoc """
  KB ingestion pipeline owning Primitive 0.2's three guarantees:

    (i)  **Idempotent** — re-ingesting the same `(org_id, source_id)`
         with identical `content_sha256` is a no-op (only `last_seen_at`
         is bumped). No new chunks/vectors/FTS rows.

    (ii) **Fresh** — re-ingesting with a different `content_sha256`
         atomically REPLACES the source's chunks/vectors/FTS in one
         `Repo.transaction/1`; mid-replace queries see either the
         pre-replace or post-replace state, never a mixed result set.

    (iii) **Removable** — `remove_source!/2` (admin-only) drops every
          chunk/vector/FTS row referencing the source plus the
          kb_sources row itself; writes a `kb_source_history` audit
          trail row.

  Source-identity normalisation lives in `DmhAi.Ingest.SourceId`.
  Memo ingestion stays in `VectorDB` — memos don't need the three
  guarantees (per-user, encrypted, not re-fetched from upstream).
  """

  alias DmhAi.Repo
  alias DmhAi.Ingest.SourceId
  alias DmhAi.VectorDB.{Chunker, Embedder, Sources, SqliteVec, Tagger}
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Upsert a KB source with content-hash idempotence and atomic
  freshness. Required keys on `attrs`: `:org_id`, `:source_kind`,
  `:source_ref`, `:created_by_user_id`. Optional: `:title`,
  `:source_id` (override derived value).

  Returns `{:ok, %{source_id, action: :inserted | :skipped | :replaced,
  internal_id, indexed}}` or `{:error, reason}`.
  """
  @spec upsert_kb_source(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def upsert_kb_source(attrs, body) when is_binary(body) do
    with :ok <- validate_attrs(attrs),
         {:ok, source_id} <- resolve_source_id(attrs) do
      content_sha = sha256(body)
      now = System.os_time(:millisecond)

      Repo.transaction(fn ->
        case lookup_existing(attrs.org_id, source_id) do
          nil ->
            do_fresh(attrs, source_id, content_sha, body, now)

          %{id: id, content_sha256: ^content_sha} ->
            bump_last_seen(id, now)
            %{source_id: source_id, action: :skipped, internal_id: id, indexed: 0}

          %{id: old_id} ->
            do_replace(old_id, attrs, source_id, content_sha, body, now)
        end
      end)
    end
  end

  @doc """
  Admin-only removal. Writes a `kb_source_history` audit row, then
  deletes the kb_sources row + cascading chunks/vectors/FTS. Returns
  `:ok` even if the source was already absent (idempotent).
  """
  @spec remove_kb_source!(String.t(), String.t(), keyword()) :: :ok
  def remove_kb_source!(org_id, source_id, opts \\ []) do
    removed_by = Keyword.get(opts, :removed_by_user_id)
    reason     = Keyword.get(opts, :reason)
    now        = System.os_time(:millisecond)

    {:ok, _} =
      Repo.transaction(fn ->
        case lookup_existing(org_id, source_id) do
          nil ->
            :noop

          %{id: id, source_kind: kind} ->
            query!(Repo, """
            INSERT INTO kb_source_history
              (org_id, source_id, source_kind, removed_by_user_id, reason, removed_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [org_id, source_id, kind, removed_by, reason, now])

            # Cascade-clean chunks/vectors/FTS via the backend (vec0
            # and FTS don't honour FK cascade). Then drop the source
            # row itself; kb_chunks_meta cascades.
            SqliteVec.delete_by_source(:knowledge, id)
            query!(Repo, "DELETE FROM kb_sources WHERE id=?", [id])
        end
      end)

    :ok
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp validate_attrs(attrs) do
    cond do
      not is_binary(attrs[:org_id]) or attrs[:org_id] == "" ->
        {:error, :org_id_required}

      not is_binary(attrs[:source_kind]) ->
        {:error, :source_kind_required}

      not is_binary(attrs[:source_ref]) ->
        {:error, :source_ref_required}

      true ->
        :ok
    end
  end

  defp resolve_source_id(%{source_id: sid}) when is_binary(sid) and sid != "", do: {:ok, sid}

  defp resolve_source_id(attrs) do
    {:ok, SourceId.derive(attrs.source_kind, attrs.source_ref, attrs.org_id)}
  end

  defp lookup_existing(org_id, source_id) do
    case query!(Repo, """
    SELECT id, content_sha256, source_kind FROM kb_sources
    WHERE org_id=? AND source_id=?
    """, [org_id, source_id]).rows do
      [[id, sha, kind]] -> %{id: id, content_sha256: sha, source_kind: kind}
      _ -> nil
    end
  end

  defp bump_last_seen(id, now) do
    query!(Repo, "UPDATE kb_sources SET last_seen_at=? WHERE id=?", [now, id])
  end

  # Fresh ingest — never seen before. Chunk + embed + tag + insert.
  defp do_fresh(attrs, source_id, content_sha, body, now) do
    chunks = Chunker.split(body, [])

    if chunks == [] do
      Repo.rollback(:empty_body)
    else
      {:ok, embeddings} = Embedder.embed_batch(chunks)
      centroid = average_embedding(embeddings)
      tags = Tagger.tag(body, %{user_id: attrs[:created_by_user_id] || attrs[:user_id]})
      extracted_sha = sha256(body)

      {:ok, internal_id} =
        Sources.upsert_kb(%{
          org_id:                 attrs.org_id,
          source_id:              source_id,
          source_kind:            attrs.source_kind,
          title:                  attrs[:title],
          centroid:               centroid,
          tags:                   tags,
          source_scope:           attrs[:source_scope],
          content_sha256:         content_sha,
          extracted_text_sha256:  extracted_sha,
          created_by_user_id:     attrs[:created_by_user_id],
          parent_source_id:       attrs[:parent_source_id],
          last_seen_at:           now,
          last_indexed_at:        now
        }, body)

      rows = build_rows(attrs.org_id, internal_id, source_id, chunks, embeddings, attrs, now)
      :ok = DmhAi.VectorDB.add(rows)

      %{source_id: source_id, action: :inserted, internal_id: internal_id, indexed: length(chunks)}
    end
  end

  # Replace — content changed. Atomic delete-then-insert inside the
  # outer transaction.
  defp do_replace(old_id, attrs, source_id, _content_sha, body, now) do
    SqliteVec.delete_by_source(:knowledge, old_id)
    query!(Repo, "DELETE FROM kb_sources WHERE id=?", [old_id])

    %{action: :inserted} = result = do_fresh(attrs, source_id, sha256(body), body, now)
    %{result | action: :replaced}
  end

  defp build_rows(org_id, internal_id, _source_id, chunks, embeddings, attrs, now) do
    chunks
    |> Enum.zip(embeddings)
    |> Enum.with_index()
    |> Enum.map(fn {{text, embedding}, idx} ->
      %{
        scope:       :knowledge,
        org_id:      org_id,
        source_id:   internal_id,
        chunk_idx:   idx,
        chunk_text:  text,
        embedding:   embedding,
        indexed_at:  now,
        _source_kind: attrs.source_kind,
        _source_ref:  attrs.source_ref,
        _title:       attrs[:title],
        _tags:        []
      }
    end)
  end

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

  defp sha256(bin) when is_binary(bin),
    do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
