# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.SqliteVec do
  @moduledoc """
  Production backend — sqlite-vec virtual tables (`kb_vec_knowledge`,
  `kb_vec_memo`) joined to `kb_chunks_meta` for non-vector metadata.

  The vec0 row's `rowid` mirrors `kb_chunks_meta.id`; we insert into
  meta first to mint the id, then insert into vec0 with the same
  rowid. Search uses vec0's `MATCH` syntax for native top-K cosine,
  joining on rowid to fetch metadata + source attributes.

  Implements `DmhAi.VectorDB.Backend`.
  """

  @behaviour DmhAi.VectorDB.Backend

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @impl true
  def add(rows) when is_list(rows) do
    Enum.each(rows, fn row ->
      vec_table = vec_table_name(row.scope)

      %{rows: [[id]]} =
        query!(Repo, """
        INSERT INTO kb_chunks_meta (scope, user_id, source_id, chunk_idx, chunk_text, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?)
        RETURNING id
        """, [
          scope_to_string(row.scope),
          row.user_id,
          row.source_id,
          row.chunk_idx,
          row.chunk_text,
          row.indexed_at
        ])

      # CAST(? AS BLOB) — without it, SQLite's bind layer can promote
      # our packed float32 binary to TEXT when the byte pattern happens
      # to be valid UTF-8, and sqlite-vec then tries to parse it as a
      # JSON array. CAST forces BLOB regardless.
      query!(Repo, "INSERT INTO #{vec_table}(rowid, embedding) VALUES (?, CAST(? AS BLOB))",
             [id, encode_vector(row.embedding)])

      # Mirror into the FTS5 index so the BM25 leg of hybrid search
      # (#182) sees this chunk. `kb_fts` is contentless; the rowid
      # is the kb_chunks_meta id we just minted above.
      #
      # Memo scope is excluded — `chunk_text` for memo rows is
      # AES-GCM ciphertext (per specs/memo_encryption.md). FTS over
      # ciphertext yields nothing matchable; FTS over plaintext
      # would defeat the encryption. Memo retrieval uses vector ANN
      # only, no BM25 — hybrid search is :knowledge-only.
      if row.scope != :memo do
        query!(Repo, "INSERT INTO kb_fts(rowid, chunk_text) VALUES (?, ?)",
               [id, row.chunk_text])
      end
    end)

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def search(scope, query_vec, k, filter) when is_list(query_vec) and is_integer(k) and k > 0 do
    vec_table = vec_table_name(scope)
    encoded   = encode_vector(query_vec)

    {filter_sql, filter_args} = build_filter(scope, filter)

    sql = """
    SELECT meta.chunk_text,
           meta.chunk_idx,
           src.id AS source_id,
           src.source_kind,
           src.source_ref,
           src.title,
           src.tags,
           vec.distance
    FROM   #{vec_table} vec
    JOIN   kb_chunks_meta meta ON meta.id = vec.rowid
    JOIN   kb_sources src      ON src.id  = meta.source_id
    WHERE  vec.embedding MATCH CAST(? AS BLOB)
      AND  k = ?
      #{filter_sql}
    ORDER  BY vec.distance
    """

    args = [encoded, k] ++ filter_args
    %{rows: rows} = query!(Repo, sql, args)

    hits =
      Enum.map(rows, fn [chunk_text, chunk_idx, source_id, kind, ref, title, tags_json, distance] ->
        %{
          chunk_text: chunk_text,
          chunk_idx: chunk_idx,
          source_id: source_id,
          source_kind: kind,
          source_ref: ref,
          title: title,
          tags: decode_tags(tags_json),
          # vec0 with `distance_metric=cosine` returns cosine distance
          # (1 - cos_sim), range [0, 2]. Convert directly to cosine
          # similarity in [0, 1]; clamp negatives (rare for text).
          # This matches the Memory backend's score, so threshold
          # tuning is consistent across backends.
          score: max(0.0, 1.0 - (distance || 0.0))
        }
      end)

    {:ok, hits}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def bm25_search(_scope, "", _k, _filter), do: {:ok, []}

  def bm25_search(scope, query_text, k, filter) when is_binary(query_text) and is_integer(k) and k > 0 do
    case build_fts_query(query_text) do
      "" ->
        # All tokens stripped (pure punctuation / unicode the
        # cleaner couldn't keep). Skip BM25 — vector-only fallback.
        {:ok, []}

      fts_q ->
        {filter_sql, filter_args} = build_filter(scope, filter)

        sql = """
        SELECT meta.chunk_text,
               meta.chunk_idx,
               src.id AS source_id,
               src.source_kind,
               src.source_ref,
               src.title,
               src.tags,
               bm25(kb_fts) AS rank
        FROM   kb_fts
        JOIN   kb_chunks_meta meta ON meta.id = kb_fts.rowid
        JOIN   kb_sources     src  ON src.id  = meta.source_id
        WHERE  kb_fts MATCH ?
          AND  meta.scope = ?
          #{filter_sql}
        ORDER BY bm25(kb_fts) ASC
        LIMIT ?
        """

        args = [fts_q, scope_to_string(scope)] ++ filter_args ++ [k]

        %{rows: rows} = query!(Repo, sql, args)

        hits =
          rows
          |> Enum.with_index(1)
          |> Enum.map(fn {[chunk_text, chunk_idx, source_id, kind, ref, title, tags_json, _rank], position} ->
            %{
              chunk_text:  chunk_text,
              chunk_idx:   chunk_idx,
              source_id:   source_id,
              source_kind: kind,
              source_ref:  ref,
              title:       title,
              tags:        decode_tags(tags_json),
              # Positional score mirroring cosine's [0, 1] feel —
              # caller's RRF merge ranks by position (not value), so
              # the absolute number here is informational. We expose
              # 1/position so per-list ordering is preserved if a
              # caller naïvely sorts by `score`.
              score:       1.0 / position
            }
          end)

        {:ok, hits}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Tokenise the user's free-text query and rewrite it into an FTS5
  # boolean — OR each cleaned token, double-quoted to escape any
  # FTS5 syntax characters. We OR (not AND) so a missing word
  # doesn't drop a chunk that matches the rest; BM25's TF/IDF
  # naturally prefers chunks that match more tokens.
  defp build_fts_query(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(fn tok ->
      cleaned = String.replace(tok, ~r/[^[:alnum:]_-]/u, "")
      if cleaned == "", do: nil, else: ~s("#{cleaned}")
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" OR ")
  end

  @impl true
  def delete_by_source(scope, source_id) when is_integer(source_id) do
    vec_table = vec_table_name(scope)

    # Find rowids first, then delete from both vec0 and meta. ON DELETE
    # CASCADE on kb_chunks_meta.source_id removes meta rows; we need to
    # remove vec0 rows manually because vec0 isn't a normal FK target.
    %{rows: rows} =
      query!(Repo, "SELECT id FROM kb_chunks_meta WHERE source_id=?", [source_id])

    ids = Enum.map(rows, fn [id] -> id end)

    Enum.each(ids, fn id ->
      query!(Repo, "DELETE FROM #{vec_table} WHERE rowid=?", [id])
      query!(Repo, "DELETE FROM kb_fts       WHERE rowid=?", [id])
    end)

    query!(Repo, "DELETE FROM kb_chunks_meta WHERE source_id=?", [source_id])
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def count(scope, user_id) do
    {sql, args} =
      case user_id do
        nil ->
          {"SELECT COUNT(*) FROM kb_chunks_meta WHERE scope=? AND user_id IS NULL",
           [scope_to_string(scope)]}

        uid ->
          {"SELECT COUNT(*) FROM kb_chunks_meta WHERE scope=? AND user_id=?",
           [scope_to_string(scope), uid]}
      end

    [[n]] = query!(Repo, sql, args).rows
    {:ok, n}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp vec_table_name(:knowledge), do: "kb_vec_knowledge"
  defp vec_table_name(:memo),      do: "kb_vec_memo"

  defp scope_to_string(:knowledge), do: "knowledge"
  defp scope_to_string(:memo),      do: "memo"

  # The user filter joins on kb_chunks_meta. Memo searches always
  # filter by user_id; knowledge has no per-user partitioning.
  defp build_filter(_scope, :none), do: {"", []}

  defp build_filter(:memo, {:user, user_id}) when is_binary(user_id) do
    {"AND meta.user_id = ?", [user_id]}
  end

  defp build_filter(_scope, {:source_id, source_id}) when is_integer(source_id) do
    {"AND meta.source_id = ?", [source_id]}
  end

  defp build_filter(_scope, _other), do: {"", []}

  # vec0 accepts vectors as packed float32 LE blobs. Exposed (not
  # `defp`) so the memo two-phase ingest path in `VectorDB` can
  # encode an embedding without going through `add/1`.
  @doc false
  def encode_vector(list) when is_list(list) do
    list
    |> Enum.map(fn f -> <<to_float(f)::float-32-little>> end)
    |> IO.iodata_to_binary()
  end

  defp to_float(f) when is_float(f), do: f
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp decode_tags(nil), do: []
  defp decode_tags(""),  do: []
  defp decode_tags(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
