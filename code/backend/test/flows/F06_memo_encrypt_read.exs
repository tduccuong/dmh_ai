# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F06 — Memo encryption pipeline.
#
# Memos are encrypted at rest with a per-user MMK ("Memo Master
# Key"). The MMK itself is wrapped under a single deployment-wide
# master key. Two-tier so:
#
#   * The deployment operator can rotate the master key without
#     touching every per-user wrap (V1→V2 migration in `auth.ex`
#     does exactly that).
#   * Per-user MMKs can be rotated (or destroyed at deletion)
#     without touching the master key.
#
# Three load-bearing invariants F06 locks in:
#
#   1. MMK wrap/unwrap is an exact round-trip under the same master
#      key. Any other master returns `:bad_master_key` (no plaintext
#      leak across deployments / key rotations).
#   2. Chunk encrypt/decrypt is an exact round-trip under the same
#      MMK. Any other MMK returns `:bad_key` (no plaintext leak
#      across users — proves user A's stolen DB row can't be
#      decrypted by user B's MMK).
#   3. Each chunk's ciphertext binds AAD = (source_id, chunk_idx).
#      A row physically copied to a different position OR a
#      different source_id fails the tag check on read. Without
#      this, an attacker with DB write access could swap
#      (sourceA, chunk0) into (sourceB, chunk5) and the swap would
#      decrypt cleanly, exposing plaintext fragments to the wrong
#      caller.
#
# Plus `wrap_version/1` for the migration-detection contract used by
# the login handler's V1→V2 migration shim.

defmodule DmhAi.Flows.F06MemoEncryptRead do
  use ExUnit.Case, async: false

  alias DmhAi.MemoCrypto

  @moduletag flow_id: "F06"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F06")
    on_exit(teardown)
    :ok
  end

  describe "MMK wrap/unwrap under master key" do
    test "round-trip with the SAME master key returns the exact MMK" do
      master = :crypto.strong_rand_bytes(32)
      mmk    = MemoCrypto.generate_mmk()

      wrapped = MemoCrypto.wrap_with_master(mmk, master)

      # Wire format starts with the V2 version byte (0x02). Without
      # it the migration detector classifies the blob as :unknown
      # and the login path can't tell V1 from V2 from a corrupt
      # write. Lock it in.
      assert MemoCrypto.wrap_version(wrapped) == :v2,
             "freshly-wrapped V2 blobs must report wrap_version=:v2; got: #{inspect(MemoCrypto.wrap_version(wrapped))}"

      assert {:ok, ^mmk} = MemoCrypto.unwrap_with_master(wrapped, master),
             "round-trip with same master key must return the original MMK byte-for-byte"
    end

    test "wrong master key returns :bad_master_key (no plaintext leak)" do
      master_a = :crypto.strong_rand_bytes(32)
      master_b = :crypto.strong_rand_bytes(32)
      mmk      = MemoCrypto.generate_mmk()

      wrapped = MemoCrypto.wrap_with_master(mmk, master_a)

      assert {:error, :bad_master_key} =
               MemoCrypto.unwrap_with_master(wrapped, master_b),
             "wrapping under master A must NOT decrypt under master B"
    end

    test "malformed blob returns :bad_format" do
      master = :crypto.strong_rand_bytes(32)

      assert {:error, :bad_format} =
               MemoCrypto.unwrap_with_master(<<0xFF, "garbage">>, master),
             "non-V2 prefix must fail with :bad_format, not :bad_master_key"

      assert {:error, :bad_format} =
               MemoCrypto.unwrap_with_master("", master),
             "empty blob must fail with :bad_format"
    end

    test "wrap_version recognises V1, V2, unknown" do
      # Build a fake V1 blob (legacy password-wrap, leading byte 0x01).
      v1_blob = <<0x01, 0::8 * 60>>
      assert MemoCrypto.wrap_version(v1_blob) == :v1

      master = :crypto.strong_rand_bytes(32)
      mmk    = MemoCrypto.generate_mmk()
      v2_blob = MemoCrypto.wrap_with_master(mmk, master)
      assert MemoCrypto.wrap_version(v2_blob) == :v2

      assert MemoCrypto.wrap_version(<<0xFF, 0xFF, 0xFF>>) == :unknown
      assert MemoCrypto.wrap_version("") == :unknown
      assert MemoCrypto.wrap_version(nil) == :unknown
    end
  end

  describe "chunk encrypt/decrypt under MMK" do
    test "round-trip with same MMK + AAD returns the exact plaintext" do
      mmk = MemoCrypto.generate_mmk()
      plaintext = "the user's home address is 221B Baker Street"
      source_id = "src-#{T.uid()}"
      chunk_idx = 0

      blob = MemoCrypto.encrypt_chunk(plaintext, mmk, source_id, chunk_idx)

      # Ciphertext must NOT contain the plaintext substring.
      refute String.contains?(blob, "Baker Street"),
             "encrypted blob leaks plaintext bytes"

      assert {:ok, ^plaintext} = MemoCrypto.decrypt_chunk(blob, mmk, source_id, chunk_idx)
    end

    test "wrong MMK returns :bad_key (no cross-user plaintext leak)" do
      mmk_a = MemoCrypto.generate_mmk()
      mmk_b = MemoCrypto.generate_mmk()
      source_id = "src-#{T.uid()}"

      blob = MemoCrypto.encrypt_chunk("user A's secret", mmk_a, source_id, 0)

      assert {:error, :bad_key} = MemoCrypto.decrypt_chunk(blob, mmk_b, source_id, 0),
             "ciphertext from user A's MMK must not decrypt under user B's MMK"
    end

    test "AAD binding — wrong chunk_idx fails the tag check" do
      mmk = MemoCrypto.generate_mmk()
      source_id = "src-#{T.uid()}"

      # Encrypt at idx=3, attempt decrypt at idx=4. Same source_id,
      # same MMK — only the AAD differs. The DB-row-shuffle attack.
      blob = MemoCrypto.encrypt_chunk("chunk-three content", mmk, source_id, 3)

      assert {:error, :bad_key} = MemoCrypto.decrypt_chunk(blob, mmk, source_id, 4),
             "row swap (idx=3 → idx=4) must fail tag check; AAD binds chunk_idx"
    end

    test "AAD binding — wrong source_id fails the tag check" do
      mmk = MemoCrypto.generate_mmk()

      blob = MemoCrypto.encrypt_chunk("source-A content", mmk, "src-A", 0)

      assert {:error, :bad_key} = MemoCrypto.decrypt_chunk(blob, mmk, "src-B", 0),
             "row swap (src-A → src-B) at the same idx must fail tag check; AAD binds source_id"
    end

    test "legacy plaintext (no version byte) is detected, not silently corrupted" do
      mmk = MemoCrypto.generate_mmk()

      # Pre-encryption rows are stored as raw plaintext bytes — no
      # leading 0x01. The decrypt path must surface this as
      # :legacy_plaintext so the caller knows to route through the
      # lazy re-encrypt path, NOT mistake it for ciphertext and
      # error generically.
      assert {:error, :legacy_plaintext} =
               MemoCrypto.decrypt_chunk("plain old text", mmk, "src", 0),
             "absent version byte must surface :legacy_plaintext for migration routing"
    end
  end

  describe "two-tier composition (master → MMK → chunk)" do
    test "rotating the master key unwraps the MMK without touching chunks" do
      master_old = :crypto.strong_rand_bytes(32)
      master_new = :crypto.strong_rand_bytes(32)

      mmk = MemoCrypto.generate_mmk()
      source_id = "src-#{T.uid()}"

      # User saves a memo. Chunk encrypted with MMK; MMK wrapped
      # under master_old.
      chunk = MemoCrypto.encrypt_chunk("user's note", mmk, source_id, 0)
      wrapped_old = MemoCrypto.wrap_with_master(mmk, master_old)

      # Operator rotates master: unwrap MMK with old, re-wrap with
      # new. Chunk untouched.
      {:ok, ^mmk} = MemoCrypto.unwrap_with_master(wrapped_old, master_old)
      wrapped_new = MemoCrypto.wrap_with_master(mmk, master_new)

      # Old wrap is now unusable.
      assert {:error, :bad_master_key} =
               MemoCrypto.unwrap_with_master(wrapped_old, master_new)

      # New wrap unwraps to the same MMK; chunk decrypts cleanly.
      {:ok, mmk_after} = MemoCrypto.unwrap_with_master(wrapped_new, master_new)
      assert {:ok, "user's note"} = MemoCrypto.decrypt_chunk(chunk, mmk_after, source_id, 0)
    end
  end
end
