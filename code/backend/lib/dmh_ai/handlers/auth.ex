# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Auth do
  import Plug.Conn
  alias DmhAi.Repo
  alias DmhAi.AuthPlug
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # GET /auth/me
  def get_me(conn) do
    case AuthPlug.get_auth_user(conn) do
      nil -> json(conn, 401, %{error: "Unauthorized"})
      user -> json(conn, 200, user)
    end
  end

  # GET /users
  def get_users(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      result = query!(Repo, "SELECT id, email, name, role, created_at FROM users WHERE deleted=0 ORDER BY created_at")

      users =
        Enum.map(result.rows, fn [id, email, name, role, created_at] ->
          %{id: id, email: email, name: name, role: role, createdAt: created_at}
        end)

      json(conn, 200, users)
    end
  end

  # GET /users/prefs
  def get_user_prefs(conn, user) do
    key = "prefs_#{user.id}"
    result = query!(Repo, "SELECT value FROM settings WHERE key=?", [key])

    prefs =
      case result.rows do
        [[v] | _] -> Jason.decode!(v || "{}")
        _ -> %{}
      end

    json(conn, 200, prefs)
  end

  # POST /auth/login
  def post_login(conn) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    email = (d["email"] || "") |> String.trim() |> String.downcase()
    password = d["password"] || ""

    result =
      query!(Repo, """
      SELECT id, email, name, role, password_hash, password_changed
      FROM users WHERE email=? AND deleted=0
      """, [email])

    case result.rows do
      [[id, db_email, name, role, password_hash, pw_changed] | _] ->
        if AuthPlug.verify_password(password, password_hash) do
          token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
          now = :os.system_time(:second)
          # Store sha256(token), not the raw bearer. The raw value is
          # only emitted to the client below — the server keeps the
          # hash. See db/init.ex auth_tokens schema comment.
          query!(Repo, "INSERT INTO auth_tokens (token_hash, user_id, created_at) VALUES (?,?,?)",
            [AuthPlug.hash_token(token), id, now])

          display = name || hd(String.split(db_email, "@"))

          # Set the bearer also as a cookie so plain `<a>`-click
          # navigations (browser doesn't add the Authorization header
          # on those) still authenticate. AuthPlug.get_auth_user
          # falls back to the cookie when no header is present.
          conn
          |> put_auth_cookie(token)
          |> json(200, %{
            token: token,
            user: %{
              id: id,
              email: db_email,
              name: display,
              role: role,
              passwordChanged: pw_changed == 1 or pw_changed == true
            }
          })
        else
          json(conn, 401, %{error: "Invalid username or password"})
        end

      _ ->
        json(conn, 401, %{error: "Invalid username or password"})
    end
  end


  # POST /auth/logout
  def post_logout(conn) do
    # Pick up the bearer from the header OR the cookie — whichever
    # the client used to authenticate. Either way we delete that
    # specific token row and clear the cookie.
    token = AuthPlug.bearer_from_conn(conn)

    if is_binary(token) and token != "" do
      # Revoke just this token row; clear the cookie below.
      query!(Repo, "DELETE FROM auth_tokens WHERE token_hash=?", [AuthPlug.hash_token(token)])
    end

    conn
    |> clear_auth_cookie()
    |> json(200, %{ok: true})
  end

  # ── cookie helpers ─────────────────────────────────────────────────────

  @auth_cookie "dmh_ai_token"
  # 365 days — the cookie lifetime that bounds how long an idle
  # browser keeps the credential. The server-side row is the
  # authoritative source; deleting the row (logout, password change,
  # admin revoke) invalidates the cookie regardless of its remaining
  # max-age.
  @auth_cookie_max_age 31_536_000

  defp put_auth_cookie(conn, token) do
    Plug.Conn.put_resp_cookie(conn, @auth_cookie, token,
      http_only: true,
      secure: secure_cookie?(conn),
      same_site: "Strict",
      max_age: @auth_cookie_max_age,
      path: "/"
    )
  end

  defp clear_auth_cookie(conn) do
    Plug.Conn.delete_resp_cookie(conn, @auth_cookie,
      http_only: true,
      secure: secure_cookie?(conn),
      same_site: "Strict",
      path: "/"
    )
  end

  # Set `Secure` only when the user-facing connection is HTTPS —
  # either direct (`conn.scheme == :https`) or behind an HTTPS-
  # terminating proxy that signals via `X-Forwarded-Proto: https`.
  # Plain HTTP local-stage sessions skip the flag so the cookie still
  # gets sent on `<a>`-click downloads during dev testing.
  defp secure_cookie?(conn) do
    conn.scheme == :https or
      Enum.any?(get_req_header(conn, "x-forwarded-proto"), &(&1 == "https"))
  end

  # POST /users (admin: create user)
  def post_create_user(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      d = Jason.decode!(body || "{}")
      email = (d["email"] || "") |> String.trim() |> String.downcase()
      name = d["name"] |> then(fn n -> if n && String.trim(n) != "", do: String.trim(n), else: nil end)
      password = d["password"] || ""
      role = d["role"] || "user"

      if email == "" or password == "" do
        json(conn, 400, %{error: "Email and password are required"})
      else
        existing = query!(Repo, "SELECT id, deleted FROM users WHERE email=?", [email])

        case existing.rows do
          [[existing_id, 1] | _] ->
            # Reactivate soft-deleted user
            query!(Repo, """
            UPDATE users SET name=?, password_hash=?, role=?, deleted=0, password_changed=0
            WHERE id=?
            """, [name, AuthPlug.hash_password(password), role, existing_id])

            json(conn, 200, %{id: existing_id, email: email, name: name, role: role})

          [[_existing_id, _] | _] ->
            json(conn, 409, %{error: "Email already exists"})

          _ ->
            uid = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
            now = :os.system_time(:second)

            query!(Repo, """
            INSERT INTO users (id, email, name, password_hash, role, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [uid, email, name, AuthPlug.hash_password(password), role, now])

            json(conn, 200, %{id: uid, email: email, name: name, role: role})
        end
      end
    end
  end

  # PUT /auth/password
  def put_password(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    current = d["current"] || ""
    new_pw = d["new"] || ""

    if new_pw == "" do
      json(conn, 400, %{error: "New password required"})
    else
      result = query!(Repo, "SELECT password_hash FROM users WHERE id=?", [user.id])

      case result.rows do
        [[password_hash] | _] ->
          if AuthPlug.verify_password(current, password_hash) do
            query!(Repo, "UPDATE users SET password_hash=?, password_changed=1 WHERE id=?",
              [AuthPlug.hash_password(new_pw), user.id])

            json(conn, 200, %{ok: true})
          else
            json(conn, 401, %{error: "Current password is incorrect"})
          end

        _ ->
          json(conn, 401, %{error: "Current password is incorrect"})
      end
    end
  end

  # PUT /users/prefs
  def put_user_prefs(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    key = "prefs_#{user.id}"

    result = query!(Repo, "SELECT value FROM settings WHERE key=?", [key])

    prefs =
      case result.rows do
        [[v] | _] -> Jason.decode!(v || "{}")
        _ -> %{}
      end

    allowed_keys = ["lang", "notificationPollInterval"]
    updates = Map.take(d, allowed_keys)
    new_prefs = Map.merge(prefs, updates)

    query!(Repo, "INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)", [key, Jason.encode!(new_prefs)])

    json(conn, 200, new_prefs)
  end

  # GET /me/credentials — list-only view of the caller's saved
  # credential rows. Metadata only — never payload — so accidental
  # console / FE leaks can't expose tokens. Surface fields the
  # Connected accounts panel needs to render: id (for the per-row
  # revoke button), target (service identity), account (multi-
  # account label), kind (oauth2_service / api_key_mcp / etc.),
  # expiry status, and timestamps.
  def list_my_credentials(conn, user) do
    rows = DmhAi.Auth.Credentials.list(user.id)
    json(conn, 200, %{credentials: rows})
  end

  # DELETE /me/credentials/:id — revoke ONE row, scoped to the
  # caller's user_id. We resolve `(user_id, id)` to a target+account
  # pair before delegating to `delete/3` so the caller can't trick
  # the row-id into deleting another user's credential by guessing.
  def delete_my_credential(conn, user, id_str) do
    case Integer.parse(id_str || "") do
      {id, ""} ->
        case DmhAi.Auth.Credentials.list(user.id) |> Enum.find(&(&1.id == id)) do
          nil ->
            json(conn, 404, %{error: "credential not found"})

          %{target: target, account: account} ->
            DmhAi.Auth.Credentials.delete(user.id, target, account)
            DmhAi.SysLog.log("[ME:CREDS] revoked user=#{user.id} target=#{target} account=#{inspect(account)}")
            json(conn, 200, %{ok: true})
        end

      _ ->
        json(conn, 400, %{error: "id must be an integer"})
    end
  end

  # PUT /users/:id (admin: update user)
  def put_update_user(conn, user, uid) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      d = Jason.decode!(body || "{}")

      if Map.has_key?(d, "name") or Map.has_key?(d, "role") do
        name = d["name"] |> then(fn n -> if n && String.trim(n) != "", do: String.trim(n), else: nil end)
        role = d["role"] || "user"
        query!(Repo, "UPDATE users SET name=?, role=? WHERE id=?", [name, role, uid])
      end

      if d["password"] && d["password"] != "" do
        query!(Repo, "UPDATE users SET password_hash=?, password_changed=1 WHERE id=?",
               [AuthPlug.hash_password(d["password"]), uid])

        # Force re-login on every device so a stale token can't outlive the reset.
        query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])

        json(conn, 200, %{ok: true})
      else
        json(conn, 200, %{ok: true})
      end
    end
  end

  # DELETE /users/:id (admin: soft-delete user)
  def delete_user(conn, user, uid) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      if uid == user.id do
        json(conn, 400, %{error: "Cannot delete your own account"})
      else
        query!(Repo, "UPDATE users SET deleted=1 WHERE id=?", [uid])
        query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])
        json(conn, 200, %{ok: true})
      end
    end
  end
end
