# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.MemoCrypto do
  @moduledoc """
  Memo encryption primitives — see `specs/memo_encryption.md`.

  Two layers:

    1. **Master Memo Key (MMK)** — random 32 bytes per user, the key
       that actually encrypts memo `chunk_text`. Persistent on disk
       only in **wrapped** form.

    2. **Password key** — PBKDF2-derived from the user's login
       password using a per-user `memo_kdf_salt` (distinct salt
       purpose from `auth_plug`'s password verification). Used to
       wrap/unwrap the MMK.

  Wire formats:

      wrapped_mmk_v1     = 0x01 || iv(12) || tag(16) || ct(32)
      memo_chunk_v1      = 0x01 || iv(12) || tag(16) || ct(N)

  Both use AES-256-GCM. Per-row IV is random. AAD differs by use site
  (mmk wrap vs chunk encrypt) so a row swapped between contexts fails
  the auth tag check.

  This module is pure — no DB, no I/O, no Logger noise. Side effects
  (loading a row, holding a key in GenServer state) live at the call
  sites in `Handlers.Auth`, `UserAgent`, `Tools.SaveMemo`,
  `Tools.FetchMemo`.
  """

  @version_byte 0x01
  @version_byte_v2 0x02
  @iv_bytes 12
  @tag_bytes 16
  @mmk_bytes 32
  @kdf_iterations 100_000
  @aad_mmk_wrap "memo-mmk-v1"
  @aad_mmk_wrap_master "memo-mmk-master-v1"
  @aad_chunk_prefix "memo-chunk-v1"

  @typedoc "32-byte raw MMK (binary)."
  @type mmk :: binary()

  @typedoc "Wrapped MMK on-disk wire form (binary blob)."
  @type wrapped_mmk :: binary()

  @typedoc "Memo chunk on-disk wire form (binary blob)."
  @type chunk_blob :: binary()

  # ─── Key derivation ────────────────────────────────────────────────────────

  @doc """
  Generate a fresh per-user PBKDF2 salt for memo-key derivation.
  Stored verbatim in `users.memo_kdf_salt` (16 raw bytes).

  Independent from `users.password_hash`'s auth salt — a leaked auth
  salt does NOT help an attacker derive the memo key (and vice versa).
  """
  @spec generate_kdf_salt() :: binary()
  def generate_kdf_salt, do: :crypto.strong_rand_bytes(16)

  @doc """
  Derive the password-key (32 bytes) used to wrap/unwrap the MMK.

  PBKDF2-HMAC-SHA256, 100_000 iterations — same cost knob as auth
  password verification. Cheap enough for login latency, expensive
  enough to make offline brute-force on the wrapped MMK impractical.
  """
  @spec derive_password_key(String.t(), binary()) :: binary()
  def derive_password_key(password, salt) when is_binary(password) and is_binary(salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @kdf_iterations, 32)
  end

  # ─── MMK lifecycle ─────────────────────────────────────────────────────────

  @doc "Generate a fresh random 32-byte MMK."
  @spec generate_mmk() :: mmk()
  def generate_mmk, do: :crypto.strong_rand_bytes(@mmk_bytes)

  @doc """
  Wrap an MMK with a password-key. Output is the on-disk wire format.
  """
  @spec wrap_mmk(mmk(), binary()) :: wrapped_mmk()
  def wrap_mmk(mmk, password_key)
      when is_binary(mmk) and byte_size(mmk) == @mmk_bytes and
             is_binary(password_key) and byte_size(password_key) == 32 do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ct, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm, password_key, iv, mmk, @aad_mmk_wrap, @tag_bytes, true)

    <<@version_byte, iv::binary, tag::binary, ct::binary>>
  end

  @doc """
  Unwrap a wrapped-MMK with the user's password-key.

  Returns `{:ok, mmk}` on auth-tag verify, `{:error, :bad_password}`
  on tag mismatch (wrong password OR corrupted blob — caller can't
  distinguish, by AES-GCM design), `{:error, :bad_format}` on a blob
  that doesn't look like a v1 wrap.
  """
  @spec unwrap_mmk(wrapped_mmk(), binary()) ::
          {:ok, mmk()} | {:error, :bad_password | :bad_format}
  def unwrap_mmk(wrapped, password_key)
      when is_binary(wrapped) and is_binary(password_key) and byte_size(password_key) == 32 do
    case wrapped do
      <<@version_byte, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>> ->
        case :crypto.crypto_one_time_aead(
               :aes_256_gcm, password_key, iv, ct, @aad_mmk_wrap, tag, false) do
          plain when is_binary(plain) and byte_size(plain) == @mmk_bytes -> {:ok, plain}
          _ -> {:error, :bad_password}
        end

      _ ->
        {:error, :bad_format}
    end
  end

  def unwrap_mmk(_, _), do: {:error, :bad_format}

  # ─── Master-key wrap (V2) ─────────────────────────────────────────────────

  @doc """
  Wrap an MMK with the deployment master key (V2 wire format,
  `0x02 || iv || tag || ct`). AAD distinguishes the master-wrap
  context from the legacy password-wrap so a copied blob can't
  unwrap under the wrong key.
  """
  @spec wrap_with_master(mmk(), binary()) :: wrapped_mmk()
  def wrap_with_master(mmk, master_key)
      when is_binary(mmk) and byte_size(mmk) == @mmk_bytes and
             is_binary(master_key) and byte_size(master_key) == 32 do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ct, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm, master_key, iv, mmk, @aad_mmk_wrap_master, @tag_bytes, true)

    <<@version_byte_v2, iv::binary, tag::binary, ct::binary>>
  end

  @doc """
  Unwrap a V2 (master-key) wrapped MMK. Returns `{:ok, mmk}`,
  `{:error, :bad_master_key}` on tag mismatch, or
  `{:error, :bad_format}` for anything that doesn't parse as V2.
  """
  @spec unwrap_with_master(wrapped_mmk(), binary()) ::
          {:ok, mmk()} | {:error, :bad_master_key | :bad_format}
  def unwrap_with_master(wrapped, master_key)
      when is_binary(wrapped) and is_binary(master_key) and byte_size(master_key) == 32 do
    case wrapped do
      <<@version_byte_v2, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>> ->
        case :crypto.crypto_one_time_aead(
               :aes_256_gcm, master_key, iv, ct, @aad_mmk_wrap_master, tag, false) do
          plain when is_binary(plain) and byte_size(plain) == @mmk_bytes -> {:ok, plain}
          _ -> {:error, :bad_master_key}
        end

      _ ->
        {:error, :bad_format}
    end
  end

  def unwrap_with_master(_, _), do: {:error, :bad_format}

  @doc """
  Inspect the version byte of a wrapped MMK without decrypting.
  Returns `:v1` (legacy password-wrap), `:v2` (master-wrap), or
  `:unknown` for anything else (treated as the absence of a usable
  wrap upstream).
  """
  @spec wrap_version(binary() | nil) :: :v1 | :v2 | :unknown
  def wrap_version(<<@version_byte_v2, _rest::binary>>), do: :v2
  def wrap_version(<<@version_byte, _rest::binary>>),    do: :v1
  def wrap_version(_),                                    do: :unknown

  # ─── Chunk encrypt/decrypt ────────────────────────────────────────────────

  @doc """
  Encrypt a memo chunk's plaintext into the v1 on-disk wire format.

  AAD binds the ciphertext to the row's `source_id` and `chunk_idx`,
  so a row physically copied to a different position (or another
  user's source_id) will fail the tag check on read.
  """
  @spec encrypt_chunk(String.t(), mmk(), source_id :: term(), non_neg_integer()) :: chunk_blob()
  def encrypt_chunk(plaintext, mmk, source_id, chunk_idx)
      when is_binary(plaintext) and is_binary(mmk) and byte_size(mmk) == @mmk_bytes and
             is_integer(chunk_idx) and chunk_idx >= 0 do
    iv  = :crypto.strong_rand_bytes(@iv_bytes)
    aad = chunk_aad(source_id, chunk_idx)

    {ct, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm, mmk, iv, plaintext, aad, @tag_bytes, true)

    <<@version_byte, iv::binary, tag::binary, ct::binary>>
  end

  @doc """
  Decrypt a v1 memo chunk blob. Returns `{:ok, plaintext}`,
  `{:error, :bad_key}` on tag mismatch, `{:error, :legacy_plaintext}`
  if the blob doesn't start with our version byte (caller treats it
  as legacy plaintext and queues lazy re-encrypt — see
  specs/memo_encryption.md § Migration).
  """
  @spec decrypt_chunk(chunk_blob(), mmk(), source_id :: term(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, :bad_key | :legacy_plaintext}
  def decrypt_chunk(blob, mmk, source_id, chunk_idx)
      when is_binary(blob) and is_binary(mmk) and byte_size(mmk) == @mmk_bytes and
             is_integer(chunk_idx) do
    case blob do
      <<@version_byte, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>> ->
        aad = chunk_aad(source_id, chunk_idx)

        case :crypto.crypto_one_time_aead(
               :aes_256_gcm, mmk, iv, ct, aad, tag, false) do
          plain when is_binary(plain) -> {:ok, plain}
          _ -> {:error, :bad_key}
        end

      _ ->
        {:error, :legacy_plaintext}
    end
  end

  @doc """
  Quick probe — does this blob look like a v1 encrypted chunk
  (vs legacy plaintext)? Used by lazy migration to skip already-
  encrypted rows without paying a decrypt round-trip.
  """
  @spec encrypted?(binary()) :: boolean()
  def encrypted?(<<@version_byte, _rest::binary>>), do: true
  def encrypted?(_), do: false

  # ─── Internal ─────────────────────────────────────────────────────────────

  defp chunk_aad(source_id, chunk_idx) do
    # `source_id` is whatever the backend stores in `kb_chunks_meta.
    # source_id` (integer for SqliteVec, integer or binary for the
    # Memory backend, "" for legacy/unknown rows). Stringify so the
    # AAD is a stable binary regardless of backend.
    @aad_chunk_prefix <> "|" <> to_string(source_id) <> "|" <> Integer.to_string(chunk_idx)
  end
end
