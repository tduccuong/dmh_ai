# Tests for the on-boot filesystem migration that moves legacy
# `<assets>/<email>/<session>/workspace/*` files into the new
# `<workspaces>/<email>/<session>/*` tree (#190 / specs/permissions.md).
#
# Migration.run/2 is the test entrypoint — accepts overridable
# assets_dir / workspaces_dir so each test can build a fresh tmp
# tree without touching /data/.

defmodule Itgr.PermissionsMigration do
  use ExUnit.Case, async: true

  alias DmhAi.Permissions.Migration

  setup do
    base = Path.join(System.tmp_dir!(), "dmh_ai_perm_mig_#{System.unique_integer([:positive])}")
    assets   = Path.join(base, "user_assets")
    work     = Path.join(base, "user_workspaces")
    File.mkdir_p!(assets)

    on_exit(fn -> File.rm_rf(base) end)

    {:ok, base: base, assets: assets, work: work}
  end

  defp legacy_workspace(assets, email, session, files) do
    dir = Path.join([assets, email, session, "workspace"])
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, contents} ->
      File.write!(Path.join(dir, name), contents)
    end)
    dir
  end

  defp legacy_data(assets, email, session, files) do
    dir = Path.join([assets, email, session, "data"])
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, contents} ->
      File.write!(Path.join(dir, name), contents)
    end)
    dir
  end

  defp keystore(assets, email, files) do
    dir = Path.join([assets, email, "_keystore", "ssh"])
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, contents} ->
      File.write!(Path.join(dir, name), contents)
    end)
    dir
  end

  describe "Migration.run/2 — happy path" do
    test "moves legacy workspace files to user_workspaces", %{assets: a, work: w} do
      legacy_workspace(a, "u@x.com", "S1", [
        {"out.csv", "a,b\n1,2\n"},
        {"plot.png", <<137, 80, 78, 71>>}
      ])

      assert :ok = Migration.run(a, w)

      assert File.read!(Path.join([w, "u@x.com", "S1", "out.csv"]))  == "a,b\n1,2\n"
      assert File.read!(Path.join([w, "u@x.com", "S1", "plot.png"])) == <<137, 80, 78, 71>>
    end

    test "removes the now-empty legacy workspace dir", %{assets: a, work: w} do
      src = legacy_workspace(a, "u@x.com", "S1", [{"x.txt", "x"}])
      assert :ok = Migration.run(a, w)
      refute File.dir?(src), "legacy workspace dir should be removed after sweep"
    end

    test "leaves data/ uploads untouched", %{assets: a, work: w} do
      legacy_workspace(a, "u@x.com", "S1", [{"out.txt", "out"}])
      data_dir = legacy_data(a, "u@x.com", "S1", [{"upload.pdf", "PDF-CONTENT"}])

      assert :ok = Migration.run(a, w)

      assert File.read!(Path.join(data_dir, "upload.pdf")) == "PDF-CONTENT"
      # data/ directory itself stays intact
      assert File.dir?(data_dir)
    end

    test "leaves _keystore/ untouched (per-user, not per-session)", %{assets: a, work: w} do
      legacy_workspace(a, "u@x.com", "S1", [{"out.txt", "out"}])
      ks_dir = keystore(a, "u@x.com", [{"id_rsa", "PRIVATE KEY"}])

      assert :ok = Migration.run(a, w)

      assert File.read!(Path.join(ks_dir, "id_rsa")) == "PRIVATE KEY"
      assert File.dir?(ks_dir)
    end

    test "handles multiple users + multiple sessions in one pass", %{assets: a, work: w} do
      legacy_workspace(a, "alice@x.com", "S1", [{"a1.txt", "a1"}])
      legacy_workspace(a, "alice@x.com", "S2", [{"a2.txt", "a2"}])
      legacy_workspace(a, "bob@y.com",   "S3", [{"b3.txt", "b3"}])

      assert :ok = Migration.run(a, w)

      assert File.read!(Path.join([w, "alice@x.com", "S1", "a1.txt"])) == "a1"
      assert File.read!(Path.join([w, "alice@x.com", "S2", "a2.txt"])) == "a2"
      assert File.read!(Path.join([w, "bob@y.com",   "S3", "b3.txt"])) == "b3"
    end
  end

  describe "Migration.run/2 — idempotence" do
    test "second run on already-migrated tree is a no-op", %{assets: a, work: w} do
      legacy_workspace(a, "u@x.com", "S1", [{"x.txt", "x"}])

      assert :ok = Migration.run(a, w)
      mtime1 = File.stat!(Path.join([w, "u@x.com", "S1", "x.txt"])).mtime

      Process.sleep(1_100)
      assert :ok = Migration.run(a, w)
      mtime2 = File.stat!(Path.join([w, "u@x.com", "S1", "x.txt"])).mtime

      # Migrated file untouched on second pass.
      assert mtime1 == mtime2
    end

    test "fresh install (no assets dir contents) is a no-op", %{assets: a, work: w} do
      assert :ok = Migration.run(a, w)
      # Workspaces dir created (mkdir_p!), but otherwise empty.
      assert {:ok, []} = File.ls(w)
    end
  end

  describe "Migration.run/2 — collisions" do
    test "leaves source in place when destination already has the same name", %{assets: a, work: w} do
      legacy_workspace(a, "u@x.com", "S1", [{"keep.txt", "OLD-LEGACY"}])
      # Pre-populate the destination with a different file at the same name.
      dst_dir = Path.join([w, "u@x.com", "S1"])
      File.mkdir_p!(dst_dir)
      File.write!(Path.join(dst_dir, "keep.txt"), "ALREADY-IN-NEW-TREE")

      assert :ok = Migration.run(a, w)

      # Destination preserved (not overwritten).
      assert File.read!(Path.join(dst_dir, "keep.txt")) == "ALREADY-IN-NEW-TREE"
      # Source preserved too (not deleted) — data preservation > completeness.
      assert File.read!(Path.join([a, "u@x.com", "S1", "workspace", "keep.txt"])) == "OLD-LEGACY"
    end

    test "moves non-colliding files even when one collides", %{assets: a, work: w} do
      legacy_workspace(a, "u@x.com", "S1", [
        {"colliding.txt", "old"},
        {"unique.txt",    "moved"}
      ])
      dst_dir = Path.join([w, "u@x.com", "S1"])
      File.mkdir_p!(dst_dir)
      File.write!(Path.join(dst_dir, "colliding.txt"), "preexisting")

      assert :ok = Migration.run(a, w)

      # The non-colliding one moved.
      assert File.read!(Path.join(dst_dir, "unique.txt")) == "moved"
      refute File.exists?(Path.join([a, "u@x.com", "S1", "workspace", "unique.txt"]))

      # The colliding one stayed put.
      assert File.read!(Path.join(dst_dir, "colliding.txt")) == "preexisting"
      assert File.read!(Path.join([a, "u@x.com", "S1", "workspace", "colliding.txt"])) == "old"
    end
  end
end
