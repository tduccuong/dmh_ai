# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Auth.Credentials do
  @moduledoc """
  Per-user credentials store. Single primitive backing every credential
  kind — passwords, SSH keys, API keys, OAuth2 tokens, MCP server
  tokens.

  Schema: `user_credentials` keyed by `(user_id, target, account)`.
  `account` is a per-account label (typically the email/login returned
  by the OAuth provider's userinfo endpoint, or `""` for credentials
  that have no account concept — API keys etc.). Multiple accounts of
  the same service for the same user co-exist as separate rows;
  `lookup_all/2` returns them all.

  `kind` is a free-form string the caller chooses to describe
  `payload`'s shape. `expires_at` (optional unix-ms) supports time-
  bounded credentials such as OAuth2 access tokens; `nil` for non-
  expiring creds.

  Backward compat: callers that don't pass an `account` opt operate
  on the legacy default account (`""`) — the same row a pre-multi-
  account install would have written. Existing OAuth flows keep
  working until they're updated to capture the account from
  userinfo at callback time.

  Security: payloads stored **plaintext** in SQLite — known shortcut
  matching how the rest of the app treats sensitive fields. Revisit
  when the DB moves off local disk.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @type cred :: %{
          id: integer(),
          user_id: String.t(),
          target: String.t(),
          account: String.t(),
          kind: String.t(),
          payload: map(),
          notes: String.t() | nil,
          expires_at: integer() | nil,
          created_at: integer(),
          updated_at: integer()
        }

  @doc """
  Upsert a credential scoped to `(user_id, target, account)`. `kind`
  is a free-form string describing `payload`'s shape. Optional opts:

    * `:account` (default `""`) — per-account label; rows with
      different accounts co-exist as separate credentials.
    * `:notes` — free-form notes string.
    * `:expires_at` — unix ms expiry.
  """
  @spec save(String.t(), String.t(), String.t(), map(), keyword()) :: :ok
  def save(user_id, target, kind, payload, opts \\ [])
      when is_binary(user_id) and is_binary(target) and is_binary(kind) and is_map(payload) do
    account    = Keyword.get(opts, :account, "")
    notes      = Keyword.get(opts, :notes)
    expires_at = Keyword.get(opts, :expires_at)
    now        = System.os_time(:millisecond)
    payload_json = Jason.encode!(payload)

    query!(Repo, """
    INSERT INTO user_credentials (user_id, target, account, kind, payload, notes, expires_at, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(user_id, target, account) DO UPDATE SET
      kind       = excluded.kind,
      payload    = excluded.payload,
      notes      = excluded.notes,
      expires_at = excluded.expires_at,
      updated_at = excluded.updated_at
    """, [user_id, target, account, kind, payload_json, notes, expires_at, now, now])

    :ok
  end

  @doc """
  Fetch by `(user_id, target)`. Backward-compat lookup that resolves
  to the legacy default account (`""`) — the row a pre-multi-account
  install would have written. New callers that need account-scoped
  access should use `lookup/3` (with explicit account) or
  `lookup_all/2` (returns every account for the target).

  Returns the decoded record or `nil` if missing.
  """
  @spec lookup(String.t(), String.t()) :: cred() | nil
  def lookup(user_id, target) when is_binary(user_id) and is_binary(target) do
    lookup(user_id, target, "")
  end

  @doc """
  Fetch by `(user_id, target, account)`. Returns the decoded record
  or `nil` if missing.
  """
  @spec lookup(String.t(), String.t(), String.t()) :: cred() | nil
  def lookup(user_id, target, account)
      when is_binary(user_id) and is_binary(target) and is_binary(account) do
    r = query!(Repo, """
    SELECT id, user_id, target, account, kind, payload, notes, expires_at, created_at, updated_at
    FROM user_credentials
    WHERE user_id=? AND target=? AND account=?
    """, [user_id, target, account])

    case r.rows do
      [row] -> row_to_map(row)
      _     -> nil
    end
  end

  @doc """
  Fetch every account row for `(user_id, target)`. Returns `[]` when
  no credentials exist; otherwise a list ordered by `updated_at` DESC
  so callers that pick one (e.g., for fan-out) get the most-recently-
  used account first.

  This is the canonical lookup for the multi-account fan-out path —
  `lookup_creds` in the tool layer returns one entry per row from
  here so the model can iterate.
  """
  @spec lookup_all(String.t(), String.t()) :: [cred()]
  def lookup_all(user_id, target) when is_binary(user_id) and is_binary(target) do
    r = query!(Repo, """
    SELECT id, user_id, target, account, kind, payload, notes, expires_at, created_at, updated_at
    FROM user_credentials
    WHERE user_id=? AND target=?
    ORDER BY updated_at DESC
    """, [user_id, target])

    Enum.map(r.rows, &row_to_map/1)
  end

  @doc """
  List metadata for all of a user's credentials. Payloads are NOT
  returned — only target / account / kind / notes / expiry / timestamps
  — so callers don't accidentally spread secrets when listing.
  """
  @spec list(String.t()) :: [map()]
  def list(user_id) when is_binary(user_id) do
    r = query!(Repo, """
    SELECT id, target, account, kind, notes, expires_at, created_at, updated_at
    FROM user_credentials
    WHERE user_id=?
    ORDER BY updated_at DESC
    """, [user_id])

    now = System.os_time(:millisecond)

    Enum.map(r.rows, fn [id, target, account, kind, notes, expires_at, created_at, updated_at] ->
      %{
        id: id,
        target: target,
        account: account,
        kind: kind,
        notes: notes,
        expires_at: expires_at,
        is_expired: is_integer(expires_at) and expires_at < now,
        created_at: created_at,
        updated_at: updated_at
      }
    end)
  end

  @doc """
  Delete by `(user_id, target)`. Backward-compat: deletes the legacy
  default account (`""`) only. Use `delete/3` for explicit account
  scoping or `delete_all/2` to remove every account for a target.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(user_id, target) when is_binary(user_id) and is_binary(target) do
    delete(user_id, target, "")
  end

  @doc "Delete the row at `(user_id, target, account)`."
  @spec delete(String.t(), String.t(), String.t()) :: :ok
  def delete(user_id, target, account)
      when is_binary(user_id) and is_binary(target) and is_binary(account) do
    query!(Repo,
      "DELETE FROM user_credentials WHERE user_id=? AND target=? AND account=?",
      [user_id, target, account])
    :ok
  end

  @doc "Delete every account row for `(user_id, target)`."
  @spec delete_all(String.t(), String.t()) :: :ok
  def delete_all(user_id, target) when is_binary(user_id) and is_binary(target) do
    query!(Repo, "DELETE FROM user_credentials WHERE user_id=? AND target=?", [user_id, target])
    :ok
  end

  # ── private ───────────────────────────────────────────────────────────

  defp row_to_map([id, user_id, target, account, kind, payload_json, notes, expires_at, created_at, updated_at]) do
    now = System.os_time(:millisecond)

    %{
      id: id,
      user_id: user_id,
      target: target,
      account: account,
      kind: kind,
      payload: Jason.decode!(payload_json || "{}"),
      notes: notes,
      expires_at: expires_at,
      is_expired: is_integer(expires_at) and expires_at < now,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
