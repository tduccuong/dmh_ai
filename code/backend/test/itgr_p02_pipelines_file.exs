# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P02PipelinesFileTest do
  @moduledoc """
  G1 — pin `DmhAi.Commands.Pipelines.File.run/3` end-to-end against
  a real on-disk fixture file.

  Existing P02 integration coverage exercises the ingest layer via
  synthetic content fed directly into `VectorDB.ingest`. The File
  pipeline adds a layer above that: it reads the file from disk,
  routes through `ExtractContent`, then calls `VectorDB.ingest`.
  Without this test, a regression in that layer (e.g. wrong
  source_kind tag, lost basename title, dropped path in source_ref)
  is invisible to the rest of the suite.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Commands.Pipelines, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()
  @embedding_dim 1024

  setup_all do
    Application.put_env(:dmh_ai, :__embedder_stub__, fn texts ->
      vecs =
        Enum.map(texts, fn text ->
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
    rand    = T.uid()
    user_id = "u_file_#{rand}"
    email   = "file-#{rand}@test.local" |> String.downcase()
    now     = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "User", "x:y", "user", @org_id, "admin", now])

    path = Path.join(System.tmp_dir!(), "dmh_p02_file_#{rand}.txt")

    on_exit(fn ->
      File.rm(path)

      # kb_chunks_meta.source_id is the INT pk of kb_sources, not the
      # TEXT source_id column. Join via kb_sources.id.
      query!(Repo,
        "DELETE FROM kb_chunks_meta WHERE source_id IN " <>
          "(SELECT id FROM kb_sources WHERE org_id=? AND source_kind='file')",
        [@org_id])

      query!(Repo, "DELETE FROM kb_source_history WHERE org_id=?", [@org_id])
      query!(Repo, "DELETE FROM kb_sources WHERE org_id=? AND source_kind='file'", [@org_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, %{user_id: user_id, path: path}}
  end

  test "real on-disk file is ingested via Pipelines.File.run/3", %{user_id: user_id, path: path} do
    body = """
    DMH-AI G1 fixture document.

    This file lives at #{path}; the test asserts that Pipelines.File.run/3
    reads it, routes through ExtractContent, and lands a kb_sources row
    with the correct source_kind and basename.
    """
    File.write!(path, body)

    assert {:ok, ack} = Pipelines.File.run(path, "S_g1_" <> T.uid(), user_id)
    assert is_binary(ack)

    [[source_kind, title, ingest_status]] =
      query!(Repo,
             "SELECT source_kind, title, ingest_status FROM kb_sources " <>
               "WHERE org_id=? AND source_kind='file' AND title=? LIMIT 1",
             [@org_id, Path.basename(path)]).rows

    assert source_kind   == "file"
    assert title         == Path.basename(path)
    assert ingest_status == "indexed"

    [[chunk_count]] =
      query!(Repo,
             "SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id IN " <>
               "(SELECT id FROM kb_sources WHERE org_id=? AND source_kind='file' AND title=?)",
             [@org_id, Path.basename(path)]).rows

    assert chunk_count >= 1, "at least one chunk must be persisted from the fixture body"
  end

  test "re-running on the same path with UNCHANGED content is a no-op", %{user_id: user_id, path: path} do
    # Body must clear AgentSettings.min_extracted_text_chars (50 by default)
    # after whitespace + form-feed strip.
    body =
      "Stable handbook content describing parental-leave policy across " <>
        "all departments and roles within the organisation. " <> T.uid()

    File.write!(path, body)
    session_id = "S_g1_" <> T.uid()

    assert {:ok, _} = Pipelines.File.run(path, session_id, user_id)

    [[content_hash_v1]] =
      query!(Repo,
             "SELECT content_sha256 FROM kb_sources " <>
               "WHERE org_id=? AND source_kind='file' AND title=?",
             [@org_id, Path.basename(path)]).rows

    [[chunks_v1]] =
      query!(Repo,
             "SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id IN " <>
               "(SELECT id FROM kb_sources WHERE org_id=? AND source_kind='file' AND title=?)",
             [@org_id, Path.basename(path)]).rows

    # Same file content, second run.
    assert {:ok, _} = Pipelines.File.run(path, session_id, user_id)

    [[content_hash_v2]] =
      query!(Repo,
             "SELECT content_sha256 FROM kb_sources " <>
               "WHERE org_id=? AND source_kind='file' AND title=?",
             [@org_id, Path.basename(path)]).rows

    [[chunks_v2]] =
      query!(Repo,
             "SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id IN " <>
               "(SELECT id FROM kb_sources WHERE org_id=? AND source_kind='file' AND title=?)",
             [@org_id, Path.basename(path)]).rows

    assert content_hash_v2 == content_hash_v1, "content_sha256 must NOT change for unchanged content"
    assert chunks_v2       == chunks_v1,       "chunk count must NOT change for unchanged content"
  end

  test "re-running on the same path with CHANGED content atomically replaces chunks",
       %{user_id: user_id, path: path} do
    body_v1 =
      "First version of the document covering historical vacation policy " <>
        "from before the 2024 update was rolled out across all teams. " <> T.uid()

    body_v2 =
      "Second version — completely different sentence reflecting the 2026 " <>
        "policy that supersedes everything written in the prior revision. " <> T.uid()

    File.write!(path, body_v1)
    session_id = "S_g1_" <> T.uid()
    assert {:ok, _} = Pipelines.File.run(path, session_id, user_id)

    [[hash_v1, chunks_v1]] =
      query!(Repo,
             "SELECT content_sha256, " <>
               "(SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id=ks.id) " <>
             "FROM kb_sources ks WHERE org_id=? AND source_kind='file' AND title=?",
             [@org_id, Path.basename(path)]).rows

    File.write!(path, body_v2)
    assert {:ok, _} = Pipelines.File.run(path, session_id, user_id)

    [[hash_v2, chunks_v2]] =
      query!(Repo,
             "SELECT content_sha256, " <>
               "(SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id=ks.id) " <>
             "FROM kb_sources ks WHERE org_id=? AND source_kind='file' AND title=?",
             [@org_id, Path.basename(path)]).rows

    refute hash_v2 == hash_v1, "content_sha256 MUST change when file content changes"

    # Search the chunks; only v2 sentences should be retrievable.
    %{rows: chunk_rows} =
      query!(Repo,
             "SELECT chunk_text FROM kb_chunks_meta WHERE source_id IN " <>
               "(SELECT id FROM kb_sources WHERE org_id=? AND source_kind='file' AND title=?)",
             [@org_id, Path.basename(path)])

    flat = chunk_rows |> Enum.map(fn [t] -> t end) |> Enum.join(" ")
    assert String.contains?(flat, "Second version"),
           "atomic replace must persist v2 content"
    refute String.contains?(flat, "First version"),
           "atomic replace must DROP v1 content — no stale fragments may remain"

    assert chunks_v2 >= 1
    assert chunks_v1 >= 1
  end
end
