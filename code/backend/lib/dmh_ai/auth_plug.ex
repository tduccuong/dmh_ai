# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.AuthPlug do
  import Plug.Conn
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @auth_cookie "dmh_ai_token"

  @doc """
  Extract the authenticated user from the request. Tries the
  `Authorization: Bearer …` header first; falls back to the
  `dmh_ai_token` cookie set at login. The cookie path lets plain
  `<a>`-click navigations (which browsers don't send the bearer
  header on) authenticate naturally.

  Returns a user map or nil.
  """
  def get_auth_user(conn) do
    case bearer_from_conn(conn) do
      token when is_binary(token) and token != "" ->
        # Hash before the WHERE; auth_tokens stores sha256(token), not
        # the raw bearer. See db/init.ex auth_tokens schema comment.
        token_hash = hash_token(token)
        result = query!(Repo, """
        SELECT u.id, u.email, u.name, u.role, u.password_changed
        FROM auth_tokens t
        JOIN users u ON t.user_id = u.id
        WHERE t.token_hash = ? AND u.deleted = 0
        """, [token_hash])

        case result.rows do
          [[id, email, name, role, pw_changed] | _] ->
            display_name = name || hd(String.split(email, "@"))
            %{
              id: id,
              email: email,
              name: display_name,
              role: role,
              passwordChanged: pw_changed == 1 or pw_changed == true
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Resolve the bearer token from the request, regardless of whether
  the client sent it as an `Authorization` header or as the
  `dmh_ai_token` cookie. Returns the trimmed token string, or nil
  if neither carrier is present.
  """
  @spec bearer_from_conn(Plug.Conn.t()) :: String.t() | nil
  def bearer_from_conn(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        String.trim(token)

      _ ->
        conn = Plug.Conn.fetch_cookies(conn)

        case Map.get(conn.req_cookies, @auth_cookie) do
          v when is_binary(v) and v != "" -> v
          _ -> nil
        end
    end
  end

  @doc """
  Verifies a password against the stored hash.
  Stored format: "{salt_hex}:{hash_hex}"
  Salt is used as-is (hex string bytes) for PBKDF2, matching Python's salt_hex.encode().
  """
  def verify_password(password, stored) do
    try do
      [salt_hex, key_hex] = String.split(stored, ":", parts: 2)
      key = :crypto.pbkdf2_hmac(:sha256, password, salt_hex, 100_000, 32)
      Base.encode16(key, case: :lower) == key_hex
    rescue
      _ -> false
    end
  end

  @doc """
  Hashes a new password.
  Generates a 16-byte random salt hex-encoded (32 chars), used as-is for PBKDF2.
  """
  def hash_password(password) do
    salt_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    key = :crypto.pbkdf2_hmac(:sha256, password, salt_hex, 100_000, 32)
    salt_hex <> ":" <> Base.encode16(key, case: :lower)
  end

  @doc """
  Hash a bearer token for `auth_tokens.token_hash` storage / lookup.
  Plain sha256, no salt — the token itself is 256 bits of randomness
  from `:crypto.strong_rand_bytes/1`, so a salt would only add bytes
  without changing the security model. Using lowercase hex keeps the
  same column shape as `users.password_hash` for operator-side `sqlite3`
  inspection.
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
