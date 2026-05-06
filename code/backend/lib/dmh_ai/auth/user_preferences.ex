# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Auth.UserPreferences do
  @moduledoc """
  Per-user UI-controlled preferences. Stored as a JSON blob in the
  `users.preferences` column.

  Distinct from `admin_cloud_settings` (global runtime config tuned by
  admins) and `AgentSettings` (the reader of that global config). This
  module exposes ONLY personal toggles that every user can flip from
  the Conversation Settings page — currently the conservative-token-
  saving option; new toggles get added here as the UI grows.

  All readers treat NULL / absent keys as `false` / default values, so
  an unmigrated row keeps the runtime's pre-feature behaviour.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]
  alias DmhAi.Repo

  @typedoc "Decoded preferences map. Empty when NULL or invalid JSON."
  @type prefs :: map()

  # Single source of truth for the JSON keys. Adding a new toggle? Add
  # a constant + a getter/setter pair below — and surface it to the FE
  # via the /me/preferences endpoint serialiser.
  @key_conservative_token_saving "conservativeTokenSaving"

  # ─── Public API ──────────────────────────────────────────────────────────

  @doc """
  Read the full preferences blob for a user. Returns an empty map when
  the column is NULL, the row is missing, or the JSON is corrupt — the
  callers use `Map.get/3` with explicit defaults so a corrupt blob never
  bleeds an unexpected value into runtime decisions.
  """
  @spec get_all(String.t()) :: prefs()
  def get_all(user_id) when is_binary(user_id) do
    case query!(Repo, "SELECT preferences FROM users WHERE id=?", [user_id]) do
      %{rows: [[json]]} when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc """
  Whether the conservative-token-saving mode is enabled for this user.
  Defaults to `false` when the key is absent.
  """
  @spec conservative_token_saving?(String.t()) :: boolean()
  def conservative_token_saving?(user_id) when is_binary(user_id) do
    user_id |> get_all() |> Map.get(@key_conservative_token_saving, false) == true
  end

  @doc """
  Replace the conservative-token-saving toggle. Idempotent. Refuses
  non-boolean values to keep the JSON clean — the FE serialises
  booleans, so any other shape is a wiring bug worth surfacing.
  """
  @spec put_conservative_token_saving(String.t(), boolean()) :: :ok
  def put_conservative_token_saving(user_id, value)
      when is_binary(user_id) and is_boolean(value) do
    put_key(user_id, @key_conservative_token_saving, value)
  end

  @doc """
  FE-visible serialisation of a user's preferences. Currently a thin
  wrapper that fills in defaults for absent keys — keeps the FE
  payload shape stable across versions even when older rows have
  partial JSON.
  """
  @spec serialize(String.t()) :: %{required(String.t()) => term()}
  def serialize(user_id) when is_binary(user_id) do
    prefs = get_all(user_id)

    %{
      @key_conservative_token_saving =>
        Map.get(prefs, @key_conservative_token_saving, false) == true
    }
  end

  # ─── Internals ───────────────────────────────────────────────────────────

  defp put_key(user_id, key, value) do
    current = get_all(user_id)
    updated = Map.put(current, key, value)
    json    = Jason.encode!(updated)

    query!(Repo, "UPDATE users SET preferences=? WHERE id=?", [json, user_id])
    :ok
  end
end
