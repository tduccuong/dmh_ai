# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P02PipelinesFolderTest do
  @moduledoc """
  G2 — pin `DmhAi.Commands.Pipelines.Folder` end-to-end against a
  fixture directory.

  Splits into two halves:
    * `list_eligible_files/1` — walker behaviour (skiplist, extension
      whitelist, hidden-file skip) tested synchronously.
    * `run_async/3` — full ingest of N readable files via FilePipe,
      verified by polling for the per-file kb_sources rows up to a
      short deadline.
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
    user_id = "u_folder_#{rand}"
    email   = "folder-#{rand}@test.local" |> String.downcase()
    now     = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "User", "x:y", "user", @org_id, "admin", now])

    root = Path.join(System.tmp_dir!(), "dmh_p02_folder_#{rand}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)

      query!(Repo,
        "DELETE FROM kb_chunks_meta WHERE source_id IN " <>
          "(SELECT id FROM kb_sources WHERE org_id=? AND source_kind='file')",
        [@org_id])

      query!(Repo, "DELETE FROM kb_source_history WHERE org_id=?", [@org_id])
      query!(Repo, "DELETE FROM kb_sources WHERE org_id=? AND source_kind='file'", [@org_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    {:ok, %{user_id: user_id, root: root}}
  end

  describe "list_eligible_files/1 walker" do
    test "keeps text + markdown + code files; skips unsupported extensions", %{root: root} do
      write!(root, "a.txt", "doc body for a")
      write!(root, "b.md",  "# Doc body for b")
      write!(root, "c.exs", "IO.puts(\"hello\")")
      write!(root, "d.bin", <<0, 1, 2, 3, 4>>)
      write!(root, "e.tmp", "scratch file")

      eligible = Pipelines.Folder.list_eligible_files(root) |> Enum.map(&Path.basename/1)

      assert "a.txt" in eligible
      assert "b.md"  in eligible
      assert "c.exs" in eligible
      refute "d.bin" in eligible, "binary extensions outside the whitelist must be skipped"
      refute "e.tmp" in eligible, ".tmp is not in any whitelist"
    end

    test "skips hidden files + designated skiplist directories", %{root: root} do
      write!(root, ".hidden.txt", "should be skipped")
      File.mkdir_p!(Path.join(root, ".git"))
      write!(Path.join(root, ".git"), "config.txt", "git metadata, skip")

      File.mkdir_p!(Path.join(root, "node_modules"))
      write!(Path.join(root, "node_modules"), "pkg.txt", "should also be skipped")

      write!(root, "kept.md", "this one is kept")

      eligible = Pipelines.Folder.list_eligible_files(root) |> Enum.map(&Path.basename/1)

      assert "kept.md" in eligible
      refute ".hidden.txt" in eligible
      refute "config.txt"  in eligible, "files inside .git must be skipped"
      refute "pkg.txt"     in eligible, "files inside node_modules must be skipped"
    end

    test "walks recursively into nested non-skiplisted directories", %{root: root} do
      nested = Path.join([root, "level_1", "level_2"])
      File.mkdir_p!(nested)
      write!(nested, "deep.md", "Deeply nested content that must still be discovered.")

      eligible = Pipelines.Folder.list_eligible_files(root)
      assert Enum.any?(eligible, &String.ends_with?(&1, "/level_1/level_2/deep.md"))
    end
  end

  describe "run_async/3 end-to-end ingest" do
    test "every eligible file lands in kb_sources with source_kind=file", %{user_id: user_id, root: root} do
      write!(root, "alpha.md",
             "Alpha handbook section describing the company's vacation policy " <>
               "across all departments and tiers of seniority.")

      write!(root, "beta.md",
             "Beta handbook section explaining expense reimbursement rules " <>
               "including per-diem caps and currency conversion.")

      write!(root, "gamma.txt",
             "Gamma SOP for handling production incidents at three in the " <>
               "morning when no other on-call engineer is reachable.")

      session_id = "S_g2_" <> T.uid()
      assert {:ok, _ack} = Pipelines.Folder.run_async(root, session_id, user_id)

      # `run_async` returns immediately while a background Task does
      # the actual ingestion. Poll until all 3 rows appear (or fail
      # the test if they don't within the deadline).
      wait_until(2_000, fn ->
        [[n]] =
          query!(Repo,
                 "SELECT COUNT(*) FROM kb_sources WHERE org_id=? AND source_kind='file' " <>
                   "AND title IN (?, ?, ?)",
                 [@org_id, "alpha.md", "beta.md", "gamma.txt"]).rows
        n == 3
      end)

      %{rows: rows} =
        query!(Repo,
               "SELECT title, ingest_status FROM kb_sources " <>
                 "WHERE org_id=? AND source_kind='file' AND title IN (?, ?, ?) ORDER BY title",
               [@org_id, "alpha.md", "beta.md", "gamma.txt"])

      titles = rows |> Enum.map(fn [t, _] -> t end)
      statuses = rows |> Enum.map(fn [_, s] -> s end)

      assert titles == ["alpha.md", "beta.md", "gamma.txt"]
      assert Enum.all?(statuses, &(&1 == "indexed"))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp write!(dir, name, body) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), body)
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)
      if now >= deadline do
        flunk("condition not met within deadline")
      else
        Process.sleep(50)
        do_wait(fun, deadline)
      end
    end
  end
end
