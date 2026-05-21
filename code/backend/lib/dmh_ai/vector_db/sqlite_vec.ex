# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.SqliteVec do
  @moduledoc """
  Production backend — sqlite-vec virtual tables joined to per-scope
  metadata tables, per Primitive 0.1:

    * Knowledge: `kb_vec_knowledge` ↔ `kb_chunks_meta` ↔ `kb_sources`
      (org-scoped; rows carry `org_id`).
    * Memo: `kb_vec_memo` ↔ `memo_chunks_meta` ↔ `memo_sources`
      (per-user-readable; rows carry `org_id` for audit + `user_id`
      for ownership).

  The vec0 row's `rowid` mirrors the corresponding chunks_meta `id`;
  we insert into meta first to mint the id, then insert into vec0
  with the same rowid. Search uses vec0's `MATCH` syntax for native
  top-K cosine, joining on rowid to fetch metadata + source attrs.

  Memo `chunk_text` is AES-GCM ciphertext (per
  specs/memo_encryption.md), so memo BM25 is a no-op — memo retrieval
  is vector-only.

  Implements `DmhAi.VectorDB.Backend`.
  """

  @behaviour DmhAi.VectorDB.Backend

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @impl true
  def add(rows) when is_list(rows) do
    Enum.each(rows, &add_row/1)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp add_row(%{scope: :knowledge} = row) do
    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO kb_chunks_meta (org_id, source_id, chunk_idx, chunk_text, indexed_at)
      VALUES (?, ?, ?, ?, ?)
      RETURNING id
      """, [
        row.org_id,
        row.source_id,
        row.chunk_idx,
        row.chunk_text,
        row.indexed_at
      ])

    query!(Repo, "INSERT INTO kb_vec_knowledge(rowid, embedding) VALUES (?, CAST(? AS BLOB))",
           [id, encode_vector(row.embedding)])

    query!(Repo, "INSERT INTO kb_fts(rowid, chunk_text) VALUES (?, ?)",
           [id, row.chunk_text])
  end

  defp add_row(%{scope: :memo} = row) do
    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO memo_chunks_meta (org_id, user_id, source_id, chunk_idx, chunk_text, indexed_at)
      VALUES (?, ?, ?, ?, ?, ?)
      RETURNING id
      """, [
        row.org_id,
        row.user_id,
        row.source_id,
        row.chunk_idx,
        row.chunk_text,
        row.indexed_at
      ])

    query!(Repo, "INSERT INTO kb_vec_memo(rowid, embedding) VALUES (?, CAST(? AS BLOB))",
           [id, encode_vector(row.embedding)])

    # No memo_fts insert — memo chunk_text is AES-GCM ciphertext;
    # FTS over ciphertext is matchless. Memo retrieval is vector-only.
  end

  @impl true
  def search(scope, query_vec, k, filter)
      when is_list(query_vec) and is_integer(k) and k > 0 do
    encoded = encode_vector(query_vec)
    {vec_table, meta_table, src_table} = tables_for(scope)
    {filter_sql, filter_args} = build_filter(scope, filter)

    sql = """
    SELECT meta.chunk_text,
           meta.chunk_idx,
           src.id AS internal_id,
           src.source_kind,
           src.source_id,
           src.title,
           src.tags,
           vec.distance
    FROM   #{vec_table} vec
    JOIN   #{meta_table} meta ON meta.id = vec.rowid
    JOIN   #{src_table}  src  ON src.id  = meta.source_id
    WHERE  vec.embedding MATCH CAST(? AS BLOB)
      AND  k = ?
      #{filter_sql}
    ORDER  BY vec.distance
    """

    args = [encoded, k] ++ filter_args
    %{rows: rows} = query!(Repo, sql, args)

    hits =
      Enum.map(rows, fn [chunk_text, chunk_idx, internal_id, kind, source_id, title, tags_json, distance] ->
        %{
          chunk_text:  chunk_text,
          chunk_idx:   chunk_idx,
          internal_id: internal_id,
          source_kind: kind,
          source_id:   source_id,
          title:       title,
          tags:        decode_tags(tags_json),
          # vec0 with `distance_metric=cosine` returns cosine distance
          # (1 - cos_sim), range [0, 2]. Convert directly to cosine
          # similarity in [0, 1]; clamp negatives (rare for text).
          score: max(0.0, 1.0 - (distance || 0.0))
        }
      end)

    {:ok, hits}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def bm25_search(_scope, "", _k, _filter), do: {:ok, []}

  # Memo chunks are ciphertext; no usable FTS. Memo retrieval is
  # vector-only, so BM25 always returns empty for the memo scope.
  def bm25_search(:memo, _query_text, _k, _filter), do: {:ok, []}

  def bm25_search(:knowledge = scope, query_text, k, filter)
      when is_binary(query_text) and is_integer(k) and k > 0 do
    case build_fts_query(query_text) do
      "" ->
        {:ok, []}

      fts_q ->
        {filter_sql, filter_args} = build_filter(scope, filter)

        sql = """
        SELECT meta.chunk_text,
               meta.chunk_idx,
               src.id AS internal_id,
               src.source_kind,
               src.source_id,
               src.title,
               src.tags,
               bm25(kb_fts) AS rank
        FROM   kb_fts
        JOIN   kb_chunks_meta meta ON meta.id = kb_fts.rowid
        JOIN   kb_sources     src  ON src.id  = meta.source_id
        WHERE  kb_fts MATCH ?
          #{filter_sql}
        ORDER BY bm25(kb_fts) ASC
        LIMIT ?
        """

        args = [fts_q] ++ filter_args ++ [k]

        %{rows: rows} = query!(Repo, sql, args)

        hits =
          rows
          |> Enum.with_index(1)
          |> Enum.map(fn {[chunk_text, chunk_idx, internal_id, kind, source_id, title, tags_json, _rank], position} ->
            %{
              chunk_text:  chunk_text,
              chunk_idx:   chunk_idx,
              internal_id: internal_id,
              source_kind: kind,
              source_id:   source_id,
              title:       title,
              tags:        decode_tags(tags_json),
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
  # FTS5 syntax characters.
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
    {vec_table, meta_table, _src_table} = tables_for(scope)
    fts_table = fts_table_for(scope)

    %{rows: rows} =
      query!(Repo, "SELECT id FROM #{meta_table} WHERE source_id=?", [source_id])

    ids = Enum.map(rows, fn [id] -> id end)

    Enum.each(ids, fn id ->
      query!(Repo, "DELETE FROM #{vec_table} WHERE rowid=?", [id])

      if fts_table do
        query!(Repo, "DELETE FROM #{fts_table} WHERE rowid=?", [id])
      end
    end)

    query!(Repo, "DELETE FROM #{meta_table} WHERE source_id=?", [source_id])
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  # `scope_arg` is `org_id` for `:knowledge` and `user_id` for `:memo`.
  # Both are required (NOT NULL per Primitive 0.1).
  def count(:knowledge, org_id) when is_binary(org_id) do
    [[n]] = query!(Repo, "SELECT COUNT(*) FROM kb_chunks_meta WHERE org_id=?", [org_id]).rows
    {:ok, n}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def count(:memo, user_id) when is_binary(user_id) do
    [[n]] = query!(Repo, "SELECT COUNT(*) FROM memo_chunks_meta WHERE user_id=?", [user_id]).rows
    {:ok, n}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp tables_for(:knowledge), do: {"kb_vec_knowledge", "kb_chunks_meta", "kb_sources"}
  defp tables_for(:memo),      do: {"kb_vec_memo",      "memo_chunks_meta", "memo_sources"}

  defp fts_table_for(:knowledge), do: "kb_fts"
  defp fts_table_for(:memo),      do: nil

  # Filters narrow a search within the scope:
  #   :knowledge — by `org_id` (required for any cross-org isolation)
  #                or by `:source_id`.
  #   :memo      — by `user_id` (every memo search must filter)
  #                or by `:source_id`.
  defp build_filter(_scope, :none), do: {"", []}

  defp build_filter(:knowledge, {:org, org_id}) when is_binary(org_id) do
    {"AND meta.org_id = ?", [org_id]}
  end

  # `{:org, org_id, scope_predicate}` — org isolation PLUS a scope
  # filter against `src.source_scope` (JSON column on kb_sources).
  # The scope filter restricts results to platforms / categories
  # the caller declared relevant (e.g. compile-mode excludes
  # third-party SaaS API docs that happen to mention "workflow").
  # See arch_wiki/dmh_ai/knowledge.md §Source scope.
  defp build_filter(:knowledge, {:org, org_id, scope_pred}) when is_binary(org_id) and is_map(scope_pred) do
    {scope_sql, scope_args} = build_scope_predicate(scope_pred)
    {"AND meta.org_id = ?" <> scope_sql, [org_id | scope_args]}
  end

  defp build_filter(:memo, {:user, user_id}) when is_binary(user_id) do
    {"AND meta.user_id = ?", [user_id]}
  end

  defp build_filter(_scope, {:source_id, source_id}) when is_integer(source_id) do
    {"AND meta.source_id = ?", [source_id]}
  end

  defp build_filter(_scope, _other), do: {"", []}

  # Build the scope-predicate SQL fragment + args. Reads
  # `src.source_scope` as JSON via SQLite's json_extract. The
  # default `include_untagged: true` always lets untagged sources
  # through — they're general-purpose org KB.
  defp build_scope_predicate(pred) when is_map(pred) do
    include_untagged = Map.get(pred, :include_untagged, true)
    untagged_clause  =
      if include_untagged, do: "src.source_scope IS NULL OR ", else: ""

    {clauses, args} =
      Enum.reduce(pred, {[], []}, fn
        {:platforms_in, list}, {sqls, args} when is_list(list) and list != [] ->
          marks = list |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
          vals  = Enum.map(list, &platform_to_param/1)
          {[~s|json_extract(src.source_scope, '$.platform') IN (#{marks})| | sqls], vals ++ args}

        {:platforms_not_in, list}, {sqls, args} when is_list(list) and list != [] ->
          marks = list |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
          vals  = Enum.map(list, &platform_to_param/1)
          {[~s|(json_extract(src.source_scope, '$.platform') NOT IN (#{marks}) OR json_extract(src.source_scope, '$.platform') IS NULL)| | sqls], vals ++ args}

        {:categories_in, list}, {sqls, args} when is_list(list) and list != [] ->
          marks = list |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
          {[~s|json_extract(src.source_scope, '$.category') IN (#{marks})| | sqls], list ++ args}

        _, acc ->
          acc
      end)

    case clauses do
      [] ->
        # No constraints → no filter (untagged option is moot).
        {"", []}

      cs ->
        sql = " AND (" <> untagged_clause <> Enum.join(cs, " AND ") <> ")"
        {sql, args}
    end
  end

  # SQL's IN accepts strings and NULLs; convert atom `nil` to NULL.
  # SQLite-vec stores Jason-encoded scopes, so the platform is a
  # string or JSON null — both end up as SQL NULL when extracted.
  defp platform_to_param(nil), do: nil
  defp platform_to_param(v) when is_binary(v), do: v

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
