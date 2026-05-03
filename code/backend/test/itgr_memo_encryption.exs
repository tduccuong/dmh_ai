# Integration tests: memo encryption (V2 master-key design).
#
# Per specs/memo_encryption.md:
#
#   1.  Round-trip happy path — `save_memo` then `fetch_memo` returns the plaintext.
#   2.  Cross-user isolation — A's MMK can't decrypt B's row.
#   3.  Survives idle timeout — wipe in-memory MMK; next `get_memo_key`
#       re-loads from DB; subsequent `fetch_memo` works.
#   4.  Survives logout — `post_logout`, then a fresh access path
#       still finds the persisted wrap intact.
#   5.  First-write generates MMK — user with no `memo_wrapped_mmk`
#       row; first `save_memo` lazily creates a fresh wrapped MMK.
#   6.  V1 → V2 migration on login — pre-seed a V1 K2 wrap; first
#       login migrates it to V2; existing memo chunks remain
#       decryptable (same underlying MMK).
#   7.  Idempotent migration — second login is a no-op.
#   8.  Admin password reset destroys memos.
#   9.  Admin reset without confirm flag is rejected.
#  10.  FTS not populated for memo scope.
#  11.  Master key file auto-generated on first start.
#  12.  Master key env var override takes precedence over file.

defmodule Itgr.MemoEncryption do
  use ExUnit.Case, async: false

  alias DmhAi.{AuthPlug, MemoCrypto, Repo}
  alias DmhAi.MemoCrypto.MasterKey
  alias DmhAi.Agent.UserAgent
  alias DmhAi.Tools.{FetchMemo, SaveMemo}
  alias DmhAi.Handlers.Auth, as: AuthHandler
  alias DmhAi.VectorDB.SqliteVec
  import Ecto.Adapters.SQL, only: [query!: 3]
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  setup do
    Application.put_env(:dmh_ai, :__embedder_stub__, fn texts ->
      vecs = Enum.map(texts, fn t ->
        seed = :erlang.phash2(t, 1_000_000) / 1.0
        for i <- 0..1023, do: :math.sin(seed + i * 0.001)
      end)
      {:ok, vecs}
    end)
    Application.put_env(:dmh_ai, :__tagger_stub__, fn _ -> ["test"] end)
    Application.put_env(:dmh_ai, :vector_db_backend, SqliteVec)

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__embedder_stub__)
      Application.delete_env(:dmh_ai, :__tagger_stub__)
      Application.delete_env(:dmh_ai, :vector_db_backend)
    end)

    :ok
  end

  defp create_user(email_prefix, password) do
    uid = "u-#{T.uid()}"
    hash = AuthPlug.hash_password(password)
    now = :os.system_time(:second)
    email = String.downcase("#{email_prefix}-#{T.uid()}@test")

    query!(Repo, """
    INSERT INTO users (id, email, name, password_hash, role, created_at,
                       memo_kdf_salt, memo_wrapped_mmk)
    VALUES (?,?,?,?,?,?, NULL, NULL)
    """, [uid, email, email_prefix, hash, "user", now])

    on_exit(fn ->
      query!(Repo, "DELETE FROM users WHERE id=?", [uid])
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])
      query!(Repo, "DELETE FROM kb_chunks_meta WHERE user_id=?", [uid])
      query!(Repo, "DELETE FROM kb_sources WHERE user_id=?", [uid])
      UserAgent.wipe_memo_key(uid)
    end)

    %{id: uid, password: password, email: email}
  end

  defp login(user) do
    body = Jason.encode!(%{email: user.email, password: user.password})

    conn = conn(:post, "/auth/login", body)
           |> put_req_header("content-type", "application/json")

    AuthHandler.post_login(conn).status
  end

  defp memo_count(uid) do
    %{rows: [[n]]} =
      query!(Repo, "SELECT COUNT(*) FROM kb_chunks_meta WHERE scope='memo' AND user_id=?", [uid])
    n
  end

  defp memo_wrap_version(uid) do
    case query!(Repo, "SELECT memo_wrapped_mmk FROM users WHERE id=?", [uid]) do
      %{rows: [[nil]]} -> :no_wrap
      %{rows: [[wrapped]]} when is_binary(wrapped) -> MemoCrypto.wrap_version(wrapped)
      _ -> :no_wrap
    end
  end

  # ─── 1. Round-trip ─────────────────────────────────────────────────────────

  test "round-trip: save_memo + fetch_memo on the same logged-in user" do
    user = create_user("alice", "alice-pw-123")
    assert login(user) == 200

    assert {:ok, %{ok: true}} =
             SaveMemo.execute(%{"text" => "my safe-deposit code is GREEN-RIVER-7"}, %{user_id: user.id})

    assert {:ok, hits} =
             FetchMemo.execute(%{"q" => "what is the safe-deposit code?"}, %{user_id: user.id})

    assert is_list(hits)
    assert length(hits) > 0
    assert Enum.any?(hits, fn h -> String.contains?(h.text, "GREEN-RIVER-7") end)
  end

  # ─── 2. Cross-user isolation ──────────────────────────────────────────────

  test "cross-user isolation: B's MMK can't decrypt A's row" do
    user_a = create_user("a", "pw-a-123")
    user_b = create_user("b", "pw-b-456")
    assert login(user_a) == 200
    assert login(user_b) == 200

    {:ok, %{ok: true}} =
      SaveMemo.execute(%{"text" => "alice-secret-token-XYZ"}, %{user_id: user_a.id})

    {:ok, %{ok: true}} =
      SaveMemo.execute(%{"text" => "bob has nothing"}, %{user_id: user_b.id})

    %{rows: [[ct, idx, src_id] | _]} =
      query!(Repo, """
      SELECT chunk_text, chunk_idx, source_id FROM kb_chunks_meta
      WHERE scope='memo' AND user_id=?
      """, [user_a.id])

    mmk_b = UserAgent.get_memo_key(user_b.id)
    assert {:error, :bad_key} = MemoCrypto.decrypt_chunk(ct, mmk_b, src_id, idx)

    mmk_a = UserAgent.get_memo_key(user_a.id)
    assert {:ok, "alice-secret-token-XYZ"} = MemoCrypto.decrypt_chunk(ct, mmk_a, src_id, idx)
  end

  # ─── 3. Survives idle timeout ─────────────────────────────────────────────

  test "wipe in-memory MMK; next get_memo_key re-loads from DB and works" do
    user = create_user("c", "pw-c")
    assert login(user) == 200

    {:ok, %{ok: true}} = SaveMemo.execute(%{"text" => "still here"}, %{user_id: user.id})

    # Simulate idle timeout / GenServer restart by wiping the cache.
    UserAgent.wipe_memo_key(user.id)

    # Next get_memo_key triggers lazy DB unwrap.
    mmk = UserAgent.get_memo_key(user.id)
    assert is_binary(mmk)
    assert byte_size(mmk) == 32

    # And fetch still works end-to-end.
    {:ok, hits} = FetchMemo.execute(%{"q" => "still"}, %{user_id: user.id})
    assert Enum.any?(hits, fn h -> String.contains?(h.text, "still here") end)
  end

  # ─── 4. Survives logout ────────────────────────────────────────────────────

  test "logout doesn't wipe persistent wrap; next access still works" do
    user = create_user("d", "pw-d")
    assert login(user) == 200
    {:ok, %{ok: true}} = SaveMemo.execute(%{"text" => "MARKER-LOGOUT"}, %{user_id: user.id})

    # Logout — token revoked but DB wrap untouched.
    [tok] = get_user_tokens(user.id)
    body = ""
    conn = conn(:post, "/auth/logout", body)
           |> put_req_header("authorization", "Bearer " <> tok)
    assert AuthHandler.post_logout(conn).status == 200

    # Wipe in-memory cache too (mimics a logout-followed-by-restart).
    UserAgent.wipe_memo_key(user.id)

    # Memo wrap is still on disk → next memo op succeeds.
    {:ok, hits} = FetchMemo.execute(%{"q" => "marker"}, %{user_id: user.id})
    assert Enum.any?(hits, fn h -> String.contains?(h.text, "MARKER-LOGOUT") end)

    # User row still has the V2 wrap — logout doesn't NULL it out.
    assert memo_wrap_version(user.id) == :v2
  end

  defp get_user_tokens(uid) do
    %{rows: rows} = query!(Repo, "SELECT token FROM auth_tokens WHERE user_id=?", [uid])
    Enum.map(rows, &hd/1)
  end

  # ─── 5. First-write generates MMK ─────────────────────────────────────────

  test "first save_memo on a user with no wrap auto-creates the wrap" do
    user = create_user("e", "pw-e")
    # Don't login — go straight to save_memo. ensure_memo_key generates
    # a fresh wrap on demand.
    assert memo_wrap_version(user.id) == :no_wrap

    {:ok, %{ok: true}} =
      SaveMemo.execute(%{"text" => "first save creates wrap"}, %{user_id: user.id})

    assert memo_wrap_version(user.id) == :v2
    assert memo_count(user.id) >= 1
  end

  # ─── 6. V1 → V2 migration on login ────────────────────────────────────────

  test "legacy V1 password-wrapped MMK gets migrated to V2 on login" do
    user = create_user("f", "pw-f")

    # Manually plant a V1 (password-wrapped) MMK + matching encrypted memo row.
    legacy_mmk = MemoCrypto.generate_mmk()
    legacy_salt = MemoCrypto.generate_kdf_salt()
    legacy_pk = MemoCrypto.derive_password_key("pw-f", legacy_salt)
    legacy_wrap = MemoCrypto.wrap_mmk(legacy_mmk, legacy_pk)

    query!(Repo, """
      UPDATE users SET memo_kdf_salt=?, memo_wrapped_mmk=? WHERE id=?
      """, [legacy_salt, legacy_wrap, user.id])

    # Pre-seed a memo row encrypted with the V1 MMK (simulating an
    # existing chunk from before the migration).
    plaintext = "v1-era memo content"
    now_ms = :os.system_time(:millisecond)
    %{rows: [[source_id]]} =
      query!(Repo, """
      INSERT INTO kb_sources (scope, user_id, source_kind, source_ref, title, tags, centroid, indexed_at)
      VALUES ('memo', ?, 'text', ?, NULL, '[]', NULL, ?)
      RETURNING id
      """, [user.id, "ref-v1-#{T.uid()}", now_ms])
    chunk_blob = MemoCrypto.encrypt_chunk(plaintext, legacy_mmk, source_id, 0)
    query!(Repo, """
      INSERT INTO kb_chunks_meta (scope, user_id, source_id, chunk_idx, chunk_text, indexed_at)
      VALUES ('memo', ?, ?, 0, ?, ?)
      """, [user.id, source_id, chunk_blob, now_ms])

    # Login → migration runs.
    assert login(user) == 200

    # After login, wrap is V2 and memo_kdf_salt is NULL.
    assert memo_wrap_version(user.id) == :v2
    %{rows: [[salt]]} =
      query!(Repo, "SELECT memo_kdf_salt FROM users WHERE id=?", [user.id])
    assert is_nil(salt)

    # Old chunks still decrypt under the same underlying MMK (only the
    # wrap changed; the key inside is identical).
    mmk = UserAgent.get_memo_key(user.id)
    %{rows: [[ct]]} =
      query!(Repo,
        "SELECT chunk_text FROM kb_chunks_meta WHERE source_id=? AND chunk_idx=0",
        [source_id])
    assert {:ok, ^plaintext} = MemoCrypto.decrypt_chunk(ct, mmk, source_id, 0)
  end

  # ─── 7. Idempotent migration ─────────────────────────────────────────────

  test "second login does NOT re-migrate an already-V2 wrap" do
    user = create_user("g", "pw-g")
    assert login(user) == 200
    {:ok, %{ok: true}} = SaveMemo.execute(%{"text" => "marker"}, %{user_id: user.id})

    %{rows: [[wrap_before]]} =
      query!(Repo, "SELECT memo_wrapped_mmk FROM users WHERE id=?", [user.id])

    UserAgent.wipe_memo_key(user.id)
    assert login(user) == 200

    %{rows: [[wrap_after]]} =
      query!(Repo, "SELECT memo_wrapped_mmk FROM users WHERE id=?", [user.id])

    # V2 wrap is left alone (byte-identical).
    assert wrap_before == wrap_after
  end

  # ─── 8. Admin reset destroys memos ────────────────────────────────────────

  test "admin reset with confirm_memo_wipe wipes user's memos and resets wrap" do
    admin = create_user("admin", "admin-pw")
    target = create_user("victim", "victim-pw")
    promote_to_admin(admin.id)
    assert login(target) == 200

    {:ok, %{ok: true}} = SaveMemo.execute(%{"text" => "secret-pre-reset"}, %{user_id: target.id})
    assert memo_count(target.id) > 0

    body = Jason.encode!(%{password: "new-pw", confirm_memo_wipe: true})
    conn = conn(:put, "/users/#{target.id}", body)
           |> put_req_header("content-type", "application/json")
    assert AuthHandler.put_update_user(conn, %{id: admin.id, role: "admin"}, target.id).status == 200

    assert memo_count(target.id) == 0
    assert memo_wrap_version(target.id) == :no_wrap

    %{rows: [[n]]} = query!(Repo, "SELECT COUNT(*) FROM auth_tokens WHERE user_id=?", [target.id])
    assert n == 0
  end

  # ─── 9. Admin reset without confirm is rejected ──────────────────────────

  test "admin reset without confirm_memo_wipe returns 409 when memos exist" do
    admin = create_user("admin", "admin-pw")
    target = create_user("victim", "victim-pw")
    promote_to_admin(admin.id)
    assert login(target) == 200
    {:ok, %{ok: true}} = SaveMemo.execute(%{"text" => "still here"}, %{user_id: target.id})

    body = Jason.encode!(%{password: "new-pw"})
    conn = conn(:put, "/users/#{target.id}", body)
           |> put_req_header("content-type", "application/json")
    response = AuthHandler.put_update_user(conn, %{id: admin.id, role: "admin"}, target.id)

    assert response.status == 409
    decoded = Jason.decode!(response.resp_body)
    assert decoded["error"] == "memo_wipe_required"
    assert decoded["memo_count"] >= 1

    assert memo_count(target.id) >= 1
  end

  # ─── 10. FTS not populated for memo scope ────────────────────────────────

  test "kb_fts has no row for memo writes" do
    user = create_user("h", "pw-h")
    assert login(user) == 200
    {:ok, %{ok: true}} = SaveMemo.execute(%{"text" => "ftsmarker12345xyz"}, %{user_id: user.id})

    %{rows: rows} =
      query!(Repo, "SELECT rowid FROM kb_fts WHERE kb_fts MATCH ?", ["ftsmarker12345xyz"])
    assert rows == []
  end

  # ─── 11 + 12. Master key resolution ───────────────────────────────────────

  test "master key file auto-generated on first read when missing" do
    # Test in isolation from the suite-wide pre-seeded master key.
    MasterKey.reset()
    System.delete_env("DMHAI_MEMO_MASTER_KEY")

    tmp_dir = Path.join(System.tmp_dir!(), "dmh_ai_master_test_#{T.uid()}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "master.key")
    refute File.exists?(path)

    settings = %{"memoMasterKeyPath" => path}
    snapshot = swap_settings(settings)
    on_exit(fn ->
      restore_settings(snapshot)
      File.rm_rf!(tmp_dir)
      # Re-seed the suite key so subsequent tests aren't affected.
      MasterKey.put(:crypto.strong_rand_bytes(32))
    end)

    key = MasterKey.get()
    assert byte_size(key) == 32
    assert File.exists?(path)
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    # mode includes the permission bits; mask out type bits.
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "DMHAI_MEMO_MASTER_KEY env var takes precedence over file" do
    MasterKey.reset()

    expected = :crypto.strong_rand_bytes(32)
    System.put_env("DMHAI_MEMO_MASTER_KEY", Base.encode64(expected))

    on_exit(fn ->
      System.delete_env("DMHAI_MEMO_MASTER_KEY")
      MasterKey.put(:crypto.strong_rand_bytes(32))
    end)

    assert MasterKey.get() == expected
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp promote_to_admin(uid) do
    query!(Repo, "UPDATE users SET role='admin' WHERE id=?", [uid])
  end

  defp swap_settings(map) do
    snapshot =
      case query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"]) do
        %{rows: [[v]]} -> v
        _              -> nil
      end

    query!(Repo,
           "INSERT INTO settings (key, value) VALUES (?, ?) " <>
             "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
           ["admin_cloud_settings", Jason.encode!(map)])

    snapshot
  end

  defp restore_settings(snapshot) do
    if snapshot do
      query!(Repo,
             "INSERT INTO settings (key, value) VALUES (?, ?) " <>
               "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
             ["admin_cloud_settings", snapshot])
    else
      query!(Repo, "DELETE FROM settings WHERE key=?", ["admin_cloud_settings"])
    end
  end
end
