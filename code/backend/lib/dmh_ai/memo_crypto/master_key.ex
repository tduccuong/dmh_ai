# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.MemoCrypto.MasterKey do
  @moduledoc """
  Deployment-wide memo master key — see `specs/memo_encryption.md`.

  Source resolution, in order:

    1. `DMHAI_MEMO_MASTER_KEY` env var (base64-encoded 32 bytes).
    2. File at `AgentSettings.memo_master_key_path/0`.
    3. Auto-generate, write the file with `chmod 0600`, log a notice.

  Cached in `:persistent_term` for the lifetime of the BEAM process.
  No supervisor child — the first call to `get/0` performs the load
  lazily (and atomically; subsequent calls hit the cache).

  Tests can pre-seed via `put/1` to avoid touching the filesystem.

  Why outside the DB: a stolen DB backup MUST NOT yield the means to
  decrypt memo content. Operators who back up `/data/db/` alone don't
  capture the master key (the default file path lives one level up,
  in `/data/secrets/`).
  """

  alias DmhAi.Agent.AgentSettings
  require Logger

  @key_term {__MODULE__, :master_key}
  @env_var "DMHAI_MEMO_MASTER_KEY"
  @key_bytes 32

  @doc """
  Returns the 32-byte master key. First call resolves and caches;
  subsequent calls hit the persistent_term cache directly.

  Raises only on a malformed env-var override — silent fallback to
  the file path would mask an operator's misconfiguration.
  """
  @spec get() :: binary()
  def get do
    case :persistent_term.get(@key_term, :unset) do
      :unset ->
        key = load()
        :persistent_term.put(@key_term, key)
        key

      key when is_binary(key) and byte_size(key) == @key_bytes ->
        key
    end
  end

  @doc "Test hook — pre-seed the cached key without touching disk."
  @spec put(binary()) :: :ok
  def put(key) when is_binary(key) and byte_size(key) == @key_bytes do
    :persistent_term.put(@key_term, key)
    :ok
  end

  @doc "Test hook — drop the cached key. Next `get/0` re-resolves."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase(@key_term)
    :ok
  end

  # ─── Internal ──────────────────────────────────────────────────────────────

  defp load do
    case System.get_env(@env_var) do
      nil  -> load_from_file()
      ""   -> load_from_file()
      env  -> load_from_env(env)
    end
  end

  defp load_from_env(env) do
    case Base.decode64(String.trim(env)) do
      {:ok, k} when byte_size(k) == @key_bytes ->
        Logger.info("[MemoCrypto.MasterKey] loaded master key from #{@env_var} env var")
        k

      _ ->
        raise """
        #{@env_var} env var is set but not a valid base64-encoded \
        #{@key_bytes}-byte key. Either fix the value or unset the env \
        var to fall back to the file at #{AgentSettings.memo_master_key_path()}.\
        """
    end
  end

  defp load_from_file do
    path = AgentSettings.memo_master_key_path()

    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) == @key_bytes ->
        Logger.info("[MemoCrypto.MasterKey] loaded master key from #{path}")
        bytes

      {:ok, bytes} ->
        raise """
        master key file #{path} has wrong size (#{byte_size(bytes)} bytes, \
        expected #{@key_bytes}). Refusing to start so a corrupted key \
        doesn't silently break memo decryption. Either fix the file or \
        delete it to let the BE generate a fresh key (existing memos \
        will become unreadable).\
        """

      {:error, :enoent} ->
        generate_to_file(path)

      {:error, reason} ->
        raise "could not read master key file #{path}: #{inspect(reason)}"
    end
  end

  defp generate_to_file(path) do
    File.mkdir_p!(Path.dirname(path))
    key = :crypto.strong_rand_bytes(@key_bytes)

    # `[:exclusive]` — fails if file already exists. Two BE instances
    # racing on first start can't both win; the loser falls back to
    # reading what the winner wrote on the next get/0 call (caller
    # retries through the cache miss path — practically rare since
    # initial call comes from the boot phase).
    File.write!(path, key, [:exclusive])
    File.chmod!(path, 0o600)

    Logger.notice(
      "[MemoCrypto.MasterKey] generated fresh master key at #{path}. " <>
        "Back this file up SEPARATELY from the database — losing it makes " <>
        "every encrypted memo unreadable forever. See specs/memo_encryption.md."
    )

    key
  end
end
