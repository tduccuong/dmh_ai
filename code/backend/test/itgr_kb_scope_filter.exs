# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.KbScopeFilterTest do
  @moduledoc """
  Integration test: the `{:org, org_id, scope_predicate}` filter
  on `DmhAi.VectorDB.search/5` actually filters at the SQL layer.

  Sets up three sources with distinct scopes (third-party SaaS,
  DMH-AI internal, untagged) and verifies that scope predicates
  return the expected subsets.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.VectorDB.SourceScope
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()

  setup do
    sid = "kb_scope_test_" <> T.uid()
    now = System.os_time(:millisecond)

    # Three indexed sources sharing the same chunk text so they
    # all rank similarly on lex search; what differs is the scope.
    seed_source = fn source_id_suffix, scope ->
      sql = """
      INSERT INTO kb_sources
        (org_id, source_id, source_kind, title, raw_text, content_sha256,
         source_scope, last_seen_at, last_indexed_at, ingest_status, indexed_at)
      VALUES (?, ?, 'url', ?, ?, ?, ?, ?, ?, 'indexed', ?)
      RETURNING id
      """

      source_id = "#{sid}_#{source_id_suffix}"
      title = "Test doc — #{source_id_suffix}"
      body = "DMH-AI workflow output node shape #{source_id_suffix}"

      %{rows: [[id]]} =
        query!(Repo, sql, [
          @default_org, source_id, title, body,
          :crypto.hash(:sha256, source_id) |> Base.encode16(case: :lower),
          scope, now, now, now
        ])

      %{rows: [[chunk_id]]} =
        query!(Repo, """
        INSERT INTO kb_chunks_meta (org_id, source_id, chunk_idx, chunk_text, indexed_at)
        VALUES (?, ?, 0, ?, ?)
        RETURNING id
        """, [@default_org, id, body, now])

      # FTS index must be populated separately — the real ingest path
      # writes both tables. Without this insert, bm25_search returns
      # no rows for the chunk.
      query!(Repo, "INSERT INTO kb_fts(rowid, chunk_text) VALUES (?, ?)",
             [chunk_id, body])

      id
    end

    # Source A: tagged as third-party (bitrix24)
    src_third  = seed_source.("third", ~s({"platform":"bitrix24","category":"api-docs"}))
    # Source B: tagged as DMH-AI internal
    src_dmhai  = seed_source.("dmhai", ~s({"platform":"dmh_ai","category":"spec"}))
    # Source C: untagged (NULL source_scope → general)
    src_unset  = seed_source.("unset", nil)

    on_exit(fn ->
      Enum.each([src_third, src_dmhai, src_unset], fn id ->
        query!(Repo, "DELETE FROM kb_chunks_meta WHERE source_id=?", [id])
        query!(Repo, "DELETE FROM kb_sources WHERE id=?", [id])
      end)
    end)

    {:ok, src_third: src_third, src_dmhai: src_dmhai, src_unset: src_unset}
  end

  describe "scope filter at the SQL layer" do
    test "platforms_not_in excludes third-party hits, keeps untagged + dmh_ai",
         %{src_third: t, src_dmhai: d, src_unset: u} do
      # Use BM25 (text-only) to avoid embedder dependence in this test.
      pred = %{platforms_not_in: ["bitrix24"], include_untagged: true}

      {:ok, hits} =
        DmhAi.VectorDB.SqliteVec.bm25_search(
          :knowledge, "workflow output node", 50,
          {:org, @default_org, pred}
        )

      ids = Enum.map(hits, & &1.internal_id)

      refute t in ids, "third-party source must be filtered out"
      assert d in ids, "DMH-AI source must pass"
      assert u in ids, "untagged source must pass (include_untagged=true)"
    end

    test "include_untagged=false drops untagged sources",
         %{src_third: t, src_dmhai: d, src_unset: u} do
      pred = %{platforms_in: ["dmh_ai"], include_untagged: false}

      {:ok, hits} =
        DmhAi.VectorDB.SqliteVec.bm25_search(
          :knowledge, "workflow output node", 50,
          {:org, @default_org, pred}
        )

      ids = Enum.map(hits, & &1.internal_id)

      refute t in ids
      assert d in ids
      refute u in ids, "untagged source must NOT pass when include_untagged=false"
    end

    test "categories_in filters by category",
         %{src_third: t, src_dmhai: d, src_unset: u} do
      pred = %{categories_in: ["spec"]}

      {:ok, hits} =
        DmhAi.VectorDB.SqliteVec.bm25_search(
          :knowledge, "workflow output node", 50,
          {:org, @default_org, pred}
        )

      ids = Enum.map(hits, & &1.internal_id)

      refute t in ids                      # api-docs, not spec
      assert d in ids                      # spec ✓
      assert u in ids, "untagged passes by default (include_untagged=true)"
    end

    test "compile_mode_predicate (canonical compile-mode filter) keeps DMH-AI + untagged, excludes all 3rd-party",
         %{src_third: t, src_dmhai: d, src_unset: u} do
      {:ok, hits} =
        DmhAi.VectorDB.SqliteVec.bm25_search(
          :knowledge, "workflow output node", 50,
          {:org, @default_org, SourceScope.compile_mode_predicate()}
        )

      ids = Enum.map(hits, & &1.internal_id)
      refute t in ids
      assert d in ids
      assert u in ids
    end

    test "plain {:org, org_id} filter (no scope) returns all 3 sources (backward compat)",
         %{src_third: t, src_dmhai: d, src_unset: u} do
      {:ok, hits} =
        DmhAi.VectorDB.SqliteVec.bm25_search(
          :knowledge, "workflow output node", 50, {:org, @default_org}
        )

      ids = Enum.map(hits, & &1.internal_id)
      assert t in ids
      assert d in ids
      assert u in ids
    end
  end
end
