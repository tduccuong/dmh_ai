# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Auth.SignedUrl do
  @moduledoc """
  HMAC-SHA256 signed URLs for `/assets/<session>/<rest>`.

  The URL itself is the credential — anyone holding a valid
  `?expires=<unix_ts>&sig=<hex>` pair can download until expiry,
  without a bearer token / DMH-AI account. Used for shareable
  download links emitted by `mk_download_link`.

  Signing key (32 random bytes) is stored in the `settings` table
  under `asset_signing_key`, generated lazily on first read if
  absent. `DMHAI_ASSET_SIGNING_KEY` (hex-encoded) overrides the
  DB value and lets the operator pin the key across deployments.

  See architecture.md §Execution tools → mk_download_link →
  Signed URLs for the threat model.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @env_key "DMHAI_ASSET_SIGNING_KEY"
  @settings_key "asset_signing_key"

  @doc """
  Build the query-string suffix for a `/assets/<session_id>/<rel_path>`
  URL: `?expires=<ts>&sig=<hex>`. Caller prepends the path. `ttl_secs`
  is the desired link lifetime; the resulting `expires` is `now + ttl_secs`.
  """
  @spec query(String.t(), String.t(), pos_integer()) :: String.t()
  def query(session_id, rel_path, ttl_secs)
      when is_binary(session_id) and is_binary(rel_path) and is_integer(ttl_secs) and ttl_secs > 0 do
    expires = System.system_time(:second) + ttl_secs
    sig = sign(session_id, rel_path, expires)
    "?expires=#{expires}&sig=#{sig}"
  end

  @doc """
  Verify `params` carries a valid signature for `(session_id, rel_path)`.

  Returns:
  - `:ok` — sig present, valid, not expired.
  - `{:error, :expired}` — sig matches but `expires` is past now.
  - `{:error, :invalid}` — sig missing or doesn't match.

  Uses constant-time comparison (`Plug.Crypto.secure_compare/2`) to
  prevent timing side-channels that could leak the sig byte-by-byte.
  """
  @spec verify(map(), String.t(), String.t()) ::
          :ok | {:error, :expired} | {:error, :invalid}
  def verify(params, session_id, rel_path)
      when is_map(params) and is_binary(session_id) and is_binary(rel_path) do
    with {:ok, sig}     <- fetch_string(params, "sig"),
         {:ok, expires} <- fetch_int(params, "expires"),
         expected       = sign(session_id, rel_path, expires),
         true           <- Plug.Crypto.secure_compare(sig, expected) do
      if expires < System.system_time(:second) do
        {:error, :expired}
      else
        :ok
      end
    else
      _ -> {:error, :invalid}
    end
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp sign(session_id, rel_path, expires) do
    msg = "#{session_id}|#{rel_path}|#{expires}"
    :crypto.mac(:hmac, :sha256, key(), msg) |> Base.encode16(case: :lower)
  end

  defp fetch_string(params, k) do
    case Map.get(params, k) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> :error
    end
  end

  defp fetch_int(params, k) do
    case Map.get(params, k) do
      v when is_integer(v) -> {:ok, v}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end

      _ -> :error
    end
  end

  # Resolve the signing key. Env override wins; otherwise read the
  # `settings.asset_signing_key` row, generating + persisting one on
  # first call. Cached in :persistent_term after first resolution so
  # the per-call cost is a tagged-tuple lookup, not a DB hit.
  defp key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        k = resolve_key()
        :persistent_term.put({__MODULE__, :key}, k)
        k

      k ->
        k
    end
  end

  defp resolve_key do
    case System.get_env(@env_key) do
      hex when is_binary(hex) and hex != "" ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, bytes} when byte_size(bytes) == 32 -> bytes
          _ -> raise "#{@env_key} must be 64 hex chars (32 bytes); got #{byte_size(hex)}-char value"
        end

      _ ->
        load_or_generate_db_key()
    end
  end

  defp load_or_generate_db_key do
    case query!(Repo, "SELECT value FROM settings WHERE key = ?", [@settings_key]) do
      %{rows: [[hex]]} when is_binary(hex) and hex != "" ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, bytes} when byte_size(bytes) == 32 -> bytes
          _ -> generate_and_persist()
        end

      _ ->
        generate_and_persist()
    end
  end

  defp generate_and_persist do
    bytes = :crypto.strong_rand_bytes(32)
    hex = Base.encode16(bytes, case: :lower)

    query!(Repo, """
    INSERT INTO settings (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
    """, [@settings_key, hex])

    bytes
  end
end
