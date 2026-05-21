# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.KbCompileScopeTest do
  @moduledoc """
  Integration test pinning the KB auto-fetch contract.

  The runtime applies a SINGLE scope predicate to every per-turn
  auto-fetch: tagged third-party platform sources are excluded;
  untagged sources + non-platform categories (workflow / SOP /
  policy) are included. There is no intent classification — the
  predicate is unconditional. The model widens via an explicit
  `fetch_index(scope: …)` call when it needs third-party docs.

  The shape of the bug class: an org has a tagged third-party
  source indexed in the KB; auto-fetch must NOT surface it. This
  used to depend on runtime intent detection; now it's the static
  default.

  Platform-agnostic — picks an arbitrary slug from the runtime's
  `third_party_platforms/0` list and uses synthetic chunk text.
  Assertions are about SHAPE, not any specific SaaS.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, VectorDB}
  alias DmhAi.VectorDB.SourceScope
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()

  # The chunk text is synthetic — a generic phrase the test query
  # below matches via BM25. Same body on both seeded sources so the
  # only difference between them is `source_scope`.
  @chunk_text "synthetic test content describing a fictional automation primitive"

  setup do
    # Pick any third-party platform from the live list — the test is
    # about shape, not about which platform. Falls back to a synthetic
    # slug if the runtime list is empty (shouldn't happen).
    third_party =
      case SourceScope.third_party_platforms() do
        [first | _] -> first
        []           -> "test_third_party"
      end

    sid_suffix = T.uid()
    now = System.os_time(:millisecond)

    seed = fn slug, scope_blob ->
      source_id = "compilescope_#{slug}_#{sid_suffix}"
      title     = "Test doc — #{slug}"

      %{rows: [[id]]} =
        query!(Repo, """
        INSERT INTO kb_sources
          (org_id, source_id, source_kind, title, raw_text, content_sha256,
           source_scope, last_seen_at, last_indexed_at, ingest_status, indexed_at)
        VALUES (?, ?, 'url', ?, ?, ?, ?, ?, ?, 'indexed', ?)
        RETURNING id
        """, [
          @default_org, source_id, title, @chunk_text,
          :crypto.hash(:sha256, source_id) |> Base.encode16(case: :lower),
          scope_blob, now, now, now
        ])

      %{rows: [[chunk_id]]} =
        query!(Repo, """
        INSERT INTO kb_chunks_meta (org_id, source_id, chunk_idx, chunk_text, indexed_at)
        VALUES (?, ?, 0, ?, ?)
        RETURNING id
        """, [@default_org, id, @chunk_text, now])

      query!(Repo, "INSERT INTO kb_fts(rowid, chunk_text) VALUES (?, ?)",
             [chunk_id, @chunk_text])

      id
    end

    src_third_party = seed.("thirdparty",
                            ~s({"platform":"#{third_party}","category":"api-docs"}))
    src_untagged    = seed.("untagged", nil)

    on_exit(fn ->
      Enum.each([src_third_party, src_untagged], fn id ->
        query!(Repo, "DELETE FROM kb_chunks_meta WHERE source_id=?", [id])
        query!(Repo, "DELETE FROM kb_sources WHERE id=?", [id])
      end)
    end)

    {:ok,
     third_party_platform: third_party,
     src_third_party:      src_third_party,
     src_untagged:         src_untagged}
  end

  describe "auto-fetch — unconditional safe scope" do
    test "tagged third-party source is EXCLUDED; untagged source passes",
         %{src_third_party: tp, src_untagged: u} do
      # The runtime applies this same predicate on every per-turn
      # auto-fetch — no intent detection in front of it.
      filter = {:org, @default_org, SourceScope.compile_mode_predicate()}

      # BM25 is enough — both seeded sources carry identical chunk
      # text, so without the filter both would rank identically.
      {:ok, hits} =
        DmhAi.VectorDB.SqliteVec.bm25_search(:knowledge, @chunk_text, 50, filter)

      ids = Enum.map(hits, & &1.internal_id)
      refute tp in ids, "auto-fetch must exclude tagged third-party sources"
      assert u  in ids, "untagged source must still be reachable"
    end

    test "predicate shape — covers EVERY known third-party platform" do
      pred = SourceScope.compile_mode_predicate()
      assert is_map(pred)
      assert pred.include_untagged == true
      Enum.each(SourceScope.third_party_platforms(), fn slug ->
        assert slug in pred.platforms_not_in
      end)
    end
  end

  describe "VectorDB.search/5 wires the filter end-to-end" do
    test "search/5 with the auto-fetch predicate excludes tagged third-party hits",
         %{src_third_party: tp, src_untagged: u} do
      pred = SourceScope.compile_mode_predicate()

      # Use BM25 via the public VectorDB hybrid path with a non-empty
      # query_text so the FTS leg fires. The vector leg also runs but
      # without an Embedder a stub vector of zeros is fine for the
      # filter test — the SQL `WHERE` clause is what we're verifying.
      stub_vec = List.duplicate(0.0, 1024)

      {:ok, hits} =
        VectorDB.search(:knowledge, @chunk_text, stub_vec, 50, {:org, @default_org, pred})

      ids = Enum.map(hits, & &1.internal_id)
      refute tp in ids
      assert u  in ids
    end
  end
end
