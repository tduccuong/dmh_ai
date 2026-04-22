# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Credentials do
  @moduledoc """
  Per-user credential store.

  Stores ssh keys, user+pass, API tokens, etc. provided by the user during
  Assistant-mode turns so the assistant can reuse them on future tasks
  against the same target.

  Security note: payloads are stored **plaintext** in SQLite. This is a
  known shortcut matching how the rest of the app persists sensitive
  fields today (user profile text, session bodies). Revisit when the DB
  is moved off local disk.

  The `target` field is a free-form label chosen by the assistant, e.g.
  `"pi@192.168.178.22"`, `"github-api"`, `"aws-prod"`. Lookup is exact-
  match on (user_id, target).
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @type cred :: %{
          id: integer(),
          user_id: String.t(),
          target: String.t(),
          cred_type: String.t(),
          payload: map(),
          notes: String.t() | nil,
          created_at: integer(),
          updated_at: integer()
        }

  @doc """
  Upsert a credential scoped to (user_id, target). If a row with the same
  target already exists for this user, its payload/notes/type are replaced.
  """
  @spec save(String.t(), String.t(), String.t(), map(), String.t() | nil) :: :ok
  def save(user_id, target, cred_type, payload, notes \\ nil)
      when is_binary(user_id) and is_binary(target) and is_binary(cred_type) and is_map(payload) do
    now = System.os_time(:millisecond)
    payload_json = Jason.encode!(payload)

    query!(Repo, """
    INSERT INTO user_credentials (user_id, target, cred_type, payload, notes, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(user_id, target) DO UPDATE SET
      cred_type = excluded.cred_type,
      payload   = excluded.payload,
      notes     = excluded.notes,
      updated_at = excluded.updated_at
    """, [user_id, target, cred_type, payload_json, notes, now, now])

    :ok
  end

  @doc """
  Fetch a credential by exact (user_id, target). Returns the record with
  payload decoded, or `nil` if not found.
  """
  @spec lookup(String.t(), String.t()) :: cred() | nil
  def lookup(user_id, target) when is_binary(user_id) and is_binary(target) do
    r = query!(Repo, """
    SELECT id, user_id, target, cred_type, payload, notes, created_at, updated_at
    FROM user_credentials
    WHERE user_id=? AND target=?
    """, [user_id, target])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  @doc """
  List all credentials for a user. Payloads are NOT decoded in the list
  view — only the identifying metadata (target, type, notes, timestamps)
  is returned, so callers don't accidentally spread secrets.
  """
  @spec list(String.t()) :: [map()]
  def list(user_id) when is_binary(user_id) do
    r = query!(Repo, """
    SELECT id, target, cred_type, notes, created_at, updated_at
    FROM user_credentials
    WHERE user_id=?
    ORDER BY updated_at DESC
    """, [user_id])

    Enum.map(r.rows, fn [id, target, cred_type, notes, created_at, updated_at] ->
      %{
        id: id,
        target: target,
        cred_type: cred_type,
        notes: notes,
        created_at: created_at,
        updated_at: updated_at
      }
    end)
  end

  @doc "Delete a credential by (user_id, target). Returns :ok regardless of whether a row was present."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(user_id, target) when is_binary(user_id) and is_binary(target) do
    query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?", [user_id, target])
    :ok
  end

  # ── private ───────────────────────────────────────────────────────────

  defp row_to_map([id, user_id, target, cred_type, payload_json, notes, created_at, updated_at]) do
    %{
      id: id,
      user_id: user_id,
      target: target,
      cred_type: cred_type,
      payload: Jason.decode!(payload_json || "{}"),
      notes: notes,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
