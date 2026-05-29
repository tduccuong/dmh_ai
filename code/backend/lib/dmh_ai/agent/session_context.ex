# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.SessionContext do
  @moduledoc """
  Tiny accessor for `sessions.context` — the JSON blob carrying
  per-chain runtime state (compaction summary + cut index, active
  tool profiles, future per-chain affordances).

  Centralises the read/merge/write dance so callers don't each
  reimplement JSON-decode → Map.update → JSON-encode → SQL write.
  Two readers, two writers — both pairs are small enough that
  this module fits comfortably under 100 LoC and never needs to
  know about specific context keys.

  Schema: `context` is a JSON object. Missing column → `%{}`.
  Decode failure (corrupt JSON) → `%{}` and a Logger warning;
  callers continue with the empty context rather than crashing
  the chain.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Fetch the decoded context map for a session. Returns `%{}` when
  the row is missing, the column is NULL, or the JSON is corrupt
  (logged as a warning).
  """
  @spec get(String.t()) :: map()
  def get(session_id) when is_binary(session_id) do
    case query!(Repo, "SELECT context FROM sessions WHERE id=?", [session_id]) do
      %{rows: [[ctx_json]]} -> decode(ctx_json)
      _                      -> %{}
    end
  end

  @doc """
  Merge `patch` into the session's existing context and write it
  back. Top-level keys in `patch` replace whatever was there;
  nested merges are the caller's responsibility (the JSON shape
  varies per key — `compaction_summary` is a string, `active_profiles`
  is a list, etc.). `updated_at` is bumped on every write so the
  session-list endpoint sorts correctly.
  """
  @spec merge(String.t(), map()) :: :ok
  def merge(session_id, patch) when is_binary(session_id) and is_map(patch) do
    existing = get(session_id)
    new_ctx  = Map.merge(existing, patch)

    query!(Repo, "UPDATE sessions SET context=?, updated_at=? WHERE id=?", [
      Jason.encode!(new_ctx),
      :os.system_time(:millisecond),
      session_id
    ])

    :ok
  end

  @doc """
  Convenience: read the active-profiles list specifically, normalised
  to a list of strings. Missing key → `[]`. The active set always
  excludes `:core` (which is implicit and never persisted).
  """
  @spec active_profiles(String.t()) :: [String.t()]
  def active_profiles(session_id) when is_binary(session_id) do
    case Map.get(get(session_id), "active_profiles", []) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _                       -> []
    end
  end

  @doc """
  Write the active-profiles list. Pass `[]` to clear (end-of-chain
  reset).
  """
  @spec set_active_profiles(String.t(), [String.t()]) :: :ok
  def set_active_profiles(session_id, profiles)
      when is_binary(session_id) and is_list(profiles) do
    merge(session_id, %{"active_profiles" => profiles})
  end

  defp decode(nil), do: %{}
  defp decode(""), do: %{}

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) ->
        m

      {:error, reason} ->
        Logger.warning("[SessionContext] decode failure: #{inspect(reason)}")
        %{}
    end
  end
end
