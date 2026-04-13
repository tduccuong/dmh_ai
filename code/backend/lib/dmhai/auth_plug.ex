defmodule Dmhai.AuthPlug do
  import Plug.Conn
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Extracts the authenticated user from the Bearer token in the Authorization header.
  Returns a user map or nil.
  """
  def get_auth_user(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        token = String.trim(token)
        result = query!(Repo, """
        SELECT u.id, u.email, u.name, u.role, u.password_changed
        FROM auth_tokens t
        JOIN users u ON t.user_id = u.id
        WHERE t.token = ? AND u.deleted = 0
        """, [token])

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
end
