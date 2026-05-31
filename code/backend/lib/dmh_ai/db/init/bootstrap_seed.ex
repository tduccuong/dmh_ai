# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init.BootstrapSeed do
  @moduledoc """
  Bootstrap rows every fresh install needs before any user-facing path
  can run: the single default organization, the default admin user, and
  the org-asset directory on disk between the two. Idempotent — re-running
  is a no-op once both rows exist.
  """

  require Logger
  alias DmhAi.{Constants, Repo}
  import Ecto.Adapters.SQL, only: [query!: 3]

  def seed_all do
    seed_default_org()
    File.mkdir_p(Constants.org_assets_dir(Constants.default_org_id()))
    seed_admin()
    :ok
  end

  # Seed the single "default" organization. Every install gets exactly
  # this one row on first boot so the rest of the schema can rely on a
  # valid org_id foreign key existing. Multi-tenant installs grow more
  # rows via the admin UI; on-prem deployments typically never see a
  # second row. Idempotent — INSERT OR IGNORE on primary key.
  defp seed_default_org do
    %{rows: rows} = query!(Repo, "SELECT id FROM organizations WHERE id=?", [Constants.default_org_id()])

    if rows == [] do
      now = System.os_time(:millisecond)

      query!(Repo, """
      INSERT INTO organizations (id, name, settings_json, created_at)
      VALUES (?, ?, NULL, ?)
      """, [Constants.default_org_id(), Constants.default_org_name(), now])

      Logger.info("[DB] Seeded default organization (#{Constants.default_org_id()})")
    end
  end

  defp seed_admin do
    result = query!(Repo, "SELECT id FROM users WHERE email=?", ["admin@dmhai.local"])

    if result.rows == [] do
      uid = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      password_hash = hash_password("dmh_ai")
      now = :os.system_time(:second)

      query!(Repo, """
      INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """, [uid, "admin@dmhai.local", nil, password_hash, "admin",
            Constants.default_org_id(), "admin", now])

      Logger.info("[DB] Seeded default admin user")
    end
  end

  # Python stores passwords as {salt_hex}:{hash_hex} where:
  # - salt_hex = secrets.token_hex(16)  — 32 hex chars
  # - hash_hex = hashlib.pbkdf2_hmac('sha256', password.encode(), salt_hex.encode(), 100_000).hex()
  # Note: salt passed to pbkdf2_hmac is salt_hex.encode() i.e. the hex string as UTF-8 bytes.
  defp hash_password(password) do
    salt_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    key = :crypto.pbkdf2_hmac(:sha256, password, salt_hex, 100_000, 32)
    salt_hex <> ":" <> Base.encode16(key, case: :lower)
  end
end
