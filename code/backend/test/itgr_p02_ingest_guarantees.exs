# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P02IngestGuaranteesTest do
  @moduledoc """
  Acceptance tests for Primitive 0.2's three guarantees:

    (i)   Idempotent — re-ingest of unchanged content produces zero
          DB row changes; only `last_seen_at` is bumped.
    (ii)  Fresh — re-ingest of changed content atomically replaces
          chunks/vectors/FTS; no stale fragments leak through search.
    (iii) Removable — admin remove leaves zero rows referencing the
          source_id across kb_sources / kb_chunks_meta / kb_vec /
          kb_fts; a history row records the removal.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Ingest, Repo}
  alias DmhAi.Ingest.{BgRefreshWorker, SourceId}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()
  @embedding_dim 1024

  setup_all do
    # Stub the embedder + tagger so tests run without an LLM pool.
    Application.put_env(:dmh_ai, :__embedder_stub__, fn texts ->
      vecs =
        Enum.map(texts, fn text ->
          # Cheap deterministic embedding: sha256 of text repeated
          # until we have enough bytes to fill 1024 dims. Same text
          # → same vector (idempotence happy).
          seed = :crypto.hash(:sha256, text)
          bytes = :binary.copy(seed, div(@embedding_dim, byte_size(seed)) + 1)
          for(<<b <- bytes>>, do: b / 255.0) |> Enum.take(@embedding_dim)
        end)

      {:ok, vecs}
    end)

    Application.put_env(:dmh_ai, :__tagger_stub__, fn _body -> [] end)

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__embedder_stub__)
      Application.delete_env(:dmh_ai, :__tagger_stub__)
    end)

    :ok
  end

  setup do
    # Each test runs in isolation against a unique source_ref so we
    # don't collide with concurrent runs or pre-existing rows.
    raw_ref = "test://itgr_p02/" <> T.uid()
    body_v1 = "First version of the document content."

    on_exit(fn ->
      # Best-effort cleanup — strip any rows the test created.
      src_id = SourceId.derive("url", raw_ref, @org_id)
      Ingest.remove_kb_source!(@org_id, src_id)
    end)

    {:ok, %{raw_ref: raw_ref, body_v1: body_v1}}
  end

  defp ingest_url(raw_ref, body) do
    Ingest.upsert_kb_source(
      %{
        org_id: @org_id,
        source_kind: "url",
        source_ref: raw_ref,
        title: "Test source"
      },
      body
    )
  end

  defp count_chunks(internal_id) do
    [[n]] =
      query!(Repo,
             "SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id=?",
             [internal_id]).rows

    n
  end

  defp count_vec(internal_id) do
    [[n]] =
      query!(Repo, """
      SELECT COUNT(*) FROM kb_vec_knowledge
      WHERE rowid IN (SELECT id FROM kb_chunks_meta WHERE source_id=?)
      """, [internal_id]).rows

    n
  end

  describe "(i) idempotent" do
    test "re-ingest with identical content is a no-op", %{raw_ref: raw_ref, body_v1: body} do
      {:ok, first} = ingest_url(raw_ref, body)
      assert first.action == :inserted
      assert first.indexed > 0

      chunks_before = count_chunks(first.internal_id)

      {:ok, second} = ingest_url(raw_ref, body)
      assert second.action == :skipped
      assert second.indexed == 0
      assert second.internal_id == first.internal_id

      chunks_after = count_chunks(first.internal_id)
      assert chunks_after == chunks_before, "skip path must not touch chunks"
    end

    test "skip bumps last_seen_at but leaves last_indexed_at", %{raw_ref: raw_ref, body_v1: body} do
      {:ok, first} = ingest_url(raw_ref, body)
      [[indexed_at_1, seen_at_1]] =
        query!(Repo,
               "SELECT last_indexed_at, last_seen_at FROM kb_sources WHERE id=?",
               [first.internal_id]).rows

      Process.sleep(10)
      {:ok, _} = ingest_url(raw_ref, body)

      [[indexed_at_2, seen_at_2]] =
        query!(Repo,
               "SELECT last_indexed_at, last_seen_at FROM kb_sources WHERE id=?",
               [first.internal_id]).rows

      assert indexed_at_2 == indexed_at_1, "last_indexed_at must NOT change on skip"
      assert seen_at_2 > seen_at_1, "last_seen_at must bump on skip"
    end
  end

  describe "(ii) fresh" do
    test "re-ingest with changed content replaces chunks atomically",
         %{raw_ref: raw_ref, body_v1: body_v1} do
      {:ok, first}  = ingest_url(raw_ref, body_v1)
      first_id      = first.internal_id

      body_v2 = "Completely different wording in version two of the document."
      {:ok, second} = ingest_url(raw_ref, body_v2)

      assert second.action == :replaced
      # internal_id is fresh after replace (delete + insert)
      refute second.internal_id == first_id

      # Old internal_id no longer carries any chunks
      assert count_chunks(first_id) == 0
      assert count_vec(first_id)    == 0

      # New internal_id has the v2 chunks
      assert count_chunks(second.internal_id) > 0
    end
  end

  describe "(iii) removable" do
    test "admin remove drops the source and all dependent rows; writes history",
         %{raw_ref: raw_ref, body_v1: body} do
      {:ok, first} = ingest_url(raw_ref, body)
      src_id = SourceId.derive("url", raw_ref, @org_id)
      assert count_chunks(first.internal_id) > 0

      :ok = Ingest.remove_kb_source!(@org_id, src_id,
                                     removed_by_user_id: "test_admin",
                                     reason: "test cleanup")

      # The kb_sources row is gone
      [[remaining]] =
        query!(Repo, "SELECT COUNT(*) FROM kb_sources WHERE org_id=? AND source_id=?",
               [@org_id, src_id]).rows

      assert remaining == 0
      assert count_chunks(first.internal_id) == 0
      assert count_vec(first.internal_id)    == 0

      # History row is present
      [[history_n]] =
        query!(Repo,
               "SELECT COUNT(*) FROM kb_source_history WHERE org_id=? AND source_id=?",
               [@org_id, src_id]).rows

      assert history_n == 1
    end

    test "re-add after remove creates a fresh internal id", %{raw_ref: raw_ref, body_v1: body} do
      {:ok, first} = ingest_url(raw_ref, body)
      src_id = SourceId.derive("url", raw_ref, @org_id)

      :ok = Ingest.remove_kb_source!(@org_id, src_id, reason: "re-add test")

      {:ok, reborn} = ingest_url(raw_ref, body)
      assert reborn.action == :inserted
      refute reborn.internal_id == first.internal_id
    end
  end

  describe "SourceId.derive" do
    test "URL normalisation strips tracking params + fragment + trailing slash" do
      a = SourceId.derive("url", "https://Example.COM/page/?utm_source=x&id=42#frag", @org_id)
      b = SourceId.derive("url", "https://example.com/page?id=42", @org_id)
      assert a == b
    end

    test "file source_id is sha256(org_id ‖ path)" do
      sid1 = SourceId.derive("file", "/tmp/foo.txt", @org_id)
      sid2 = SourceId.derive("file", "/tmp/foo.txt", "another_org")

      refute sid1 == sid2, "file source_id must include org_id"
      assert byte_size(sid1) == 64, "sha256 hex is 64 chars"
    end
  end

  describe "BgRefreshWorker debounce" do
    @tag :network
    test "skipped within bg_refresh_min_interval_s window", %{raw_ref: raw_ref, body_v1: body} do
      {:ok, _} = ingest_url(raw_ref, body)
      src_id = SourceId.derive("url", raw_ref, @org_id)

      # Force a recent last_check_at to trigger the debounce path
      now_ms = System.os_time(:millisecond)
      query!(Repo,
             "UPDATE kb_sources SET last_check_at=? WHERE org_id=? AND source_id=?",
             [now_ms, @org_id, src_id])

      assert BgRefreshWorker.run(@org_id, src_id) == :skipped
    end
  end
end
