# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.DB.Init do
  require Logger
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  @assets_dir "/data/user_assets"
  @db_dir "/data/db"

  def run do
    # mkdir_p may fail in test/CI environments (no /data mount) — that is fine
    # because the DB path is configured to a writable temp location in those cases.
    File.mkdir_p(@db_dir)
    File.mkdir_p(@assets_dir)

    create_tables()
    run_migrations()
    seed_admin()
  end

  defp create_tables do
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      name TEXT,
      model TEXT,
      messages TEXT DEFAULT '[]',
      context TEXT,
      created_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      name TEXT,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user',
      created_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS auth_tokens (
      token TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      created_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS blocked_domains (
      domain TEXT PRIMARY KEY,
      reason TEXT,
      timeout_count INTEGER DEFAULT 0,
      added_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS user_fact_counts (
      user_id TEXT NOT NULL,
      topic TEXT NOT NULL,
      count INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (user_id, topic)
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS image_descriptions (
      session_id TEXT NOT NULL,
      file_id TEXT NOT NULL,
      name TEXT,
      description TEXT NOT NULL,
      created_at INTEGER,
      PRIMARY KEY (session_id, file_id)
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS video_descriptions (
      session_id TEXT NOT NULL,
      file_id TEXT NOT NULL,
      name TEXT,
      description TEXT NOT NULL,
      created_at INTEGER,
      PRIMARY KEY (session_id, file_id)
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS master_buffer (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      content TEXT NOT NULL,
      summary TEXT,
      consumed INTEGER DEFAULT 0,
      created_at INTEGER NOT NULL
    )
    """)

    query!(Repo, """
    CREATE INDEX IF NOT EXISTS idx_master_buffer_session
    ON master_buffer (session_id, consumed, created_at)
    """)
  end

  defp run_migrations do
    alter_table_safe("ALTER TABLE sessions ADD COLUMN user_id TEXT DEFAULT \"\"")
    alter_table_safe("ALTER TABLE users ADD COLUMN password_changed INTEGER DEFAULT 0")
    alter_table_safe("ALTER TABLE users ADD COLUMN deleted INTEGER DEFAULT 0")
    alter_table_safe("ALTER TABLE sessions ADD COLUMN updated_at INTEGER DEFAULT 0")
    alter_table_safe("ALTER TABLE users ADD COLUMN profile TEXT DEFAULT \"\"")
    alter_table_safe("ALTER TABLE sessions ADD COLUMN mode TEXT DEFAULT 'confidant'")
    alter_table_safe("ALTER TABLE master_buffer ADD COLUMN worker_id TEXT")
    alter_table_safe("CREATE UNIQUE INDEX IF NOT EXISTS idx_image_descriptions_name ON image_descriptions (session_id, name)")
    alter_table_safe("CREATE UNIQUE INDEX IF NOT EXISTS idx_video_descriptions_name ON video_descriptions (session_id, name)")
    alter_table_safe("""
    CREATE TABLE IF NOT EXISTS session_token_stats (
      session_id TEXT PRIMARY KEY,
      user_id TEXT,
      master_rx_tokens INTEGER DEFAULT 0,
      master_tx_tokens INTEGER DEFAULT 0,
      updated_at INTEGER
    )
    """)
    alter_table_safe("""
    CREATE TABLE IF NOT EXISTS worker_token_stats (
      session_id TEXT,
      worker_id TEXT,
      user_id TEXT,
      description TEXT,
      rx_tokens INTEGER DEFAULT 0,
      tx_tokens INTEGER DEFAULT 0,
      updated_at INTEGER,
      PRIMARY KEY (session_id, worker_id)
    )
    """)
    alter_table_safe("""
    CREATE TABLE IF NOT EXISTS worker_state (
      worker_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      task TEXT,
      messages TEXT DEFAULT '[]',
      rolling_summary TEXT,
      iter INTEGER DEFAULT 0,
      periodic INTEGER DEFAULT 0,
      status TEXT DEFAULT 'running',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """)
    alter_table_safe("CREATE INDEX IF NOT EXISTS idx_worker_state_user_status ON worker_state (user_id, status)")
  end

  defp alter_table_safe(sql) do
    Repo.query(sql)
    :ok
  rescue
    _ -> :ok
  end

  defp seed_admin do
    result = query!(Repo, "SELECT id FROM users WHERE email=?", ["admin@dmhai.local"])

    if result.rows == [] do
      uid = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      password_hash = hash_password("dmhai")
      now = :os.system_time(:second)

      query!(Repo, """
      INSERT INTO users (id, email, name, password_hash, role, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """, [uid, "admin@dmhai.local", nil, password_hash, "admin", now])

      Logger.info("[DB] Seeded default admin user")
    end
  end

  # Python stores passwords as {salt_hex}:{hash_hex} where:
  # - salt_hex = secrets.token_hex(16)  — 32 hex chars
  # - hash_hex = hashlib.pbkdf2_hmac('sha256', password.encode(), salt_hex.encode(), 100_000).hex()
  # Note: salt passed to pbkdf2_hmac is salt_hex.encode() i.e. the hex string as UTF-8 bytes.
  defp hash_password(password) do
    # Generate a 16-byte random salt and hex-encode it (32 hex chars) — matching Python's token_hex(16)
    salt_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    # Use the hex string itself as bytes for PBKDF2 — same as Python's salt.encode()
    key = :crypto.pbkdf2_hmac(:sha256, password, salt_hex, 100_000, 32)
    salt_hex <> ":" <> Base.encode16(key, case: :lower)
  end
end
