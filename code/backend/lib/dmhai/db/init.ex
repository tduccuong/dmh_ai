# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.DB.Init do
  require Logger
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  @db_dir "/data/db"

  def run do
    File.mkdir_p(@db_dir)
    File.mkdir_p(Dmhai.Constants.assets_dir())

    create_tables()
    migrate_columns()
    seed_admin()
  end

  # Additive schema migrations — idempotent. Safe on fresh installs because
  # CREATE TABLE above already has the new columns; the ALTER here catches
  # older DBs where the column is missing.
  # SQLite has no `ADD COLUMN IF NOT EXISTS` so we catch the duplicate-column
  # error and move on.
  defp migrate_columns do
    add_column_if_missing("session_progress", "sub_labels", "TEXT DEFAULT NULL")
    # Per-session human-readable task number: (1), (2), (3), … Surfaced in
    # the task-list block + FE sidebar so the user can say "tell me more
    # about task 1" and the model can map it to the internal task_id.
    add_column_if_missing("tasks", "task_num", "INTEGER")
    # First-class attachments column — JSON array of workspace/data paths.
    # Previously derived via regex from task_spec text; that was fragile
    # (model collapses newlines → regex misses 📎). Structured column is
    # the source of truth for fetch_task, the task-list block, and dedup.
    add_column_if_missing("tasks", "attachments", "TEXT DEFAULT NULL")
    # Per-session tool-result retention window (last N turns' tool_call /
    # tool_result messages, JSON). Lets the model answer follow-up
    # questions immediately after a tool run without re-extracting,
    # while still capped so extraction marathons can't balloon context.
    add_column_if_missing("sessions", "tool_history", "TEXT DEFAULT NULL")
    # Anchor back-reference. Set at pickup_task time when a DIFFERENT
    # task was the current anchor; read at complete / cancel / pause
    # time to restore that prior anchor. See architecture.md §Anchor
    # mutation via back_to_when_done back-stack.
    add_column_if_missing("tasks", "back_to_when_done_task_num", "INTEGER")
  end

  defp add_column_if_missing(table, column, type_and_default) do
    try do
      query!(Repo, "ALTER TABLE #{table} ADD COLUMN #{column} #{type_and_default}")
      Logger.info("[DB.Init] added #{table}.#{column}")
    rescue
      _ -> :ok
    end
  end

  defp create_tables do
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      name TEXT,
      model TEXT,
      messages TEXT DEFAULT '[]',
      context TEXT,
      user_id TEXT DEFAULT '',
      mode TEXT DEFAULT 'confidant',
      stream_buffer TEXT,                   -- partial final-answer tokens being streamed from the LLM; NULL when idle
      stream_buffer_ts INTEGER,             -- last stream_buffer update ts (ms); used by FE polling to detect change
      tool_history TEXT DEFAULT NULL,       -- JSON: last-N-turn tool_call / tool_result messages for context retention
      created_at INTEGER,
      updated_at INTEGER DEFAULT 0
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
      profile TEXT DEFAULT '',
      password_changed INTEGER DEFAULT 0,
      deleted INTEGER DEFAULT 0,
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

    query!(Repo, "CREATE UNIQUE INDEX IF NOT EXISTS idx_image_descriptions_name ON image_descriptions (session_id, name)")

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

    query!(Repo, "CREATE UNIQUE INDEX IF NOT EXISTS idx_video_descriptions_name ON video_descriptions (session_id, name)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_token_stats (
      session_id TEXT PRIMARY KEY,
      user_id TEXT,
      master_rx_tokens INTEGER DEFAULT 0,
      master_tx_tokens INTEGER DEFAULT 0,
      updated_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS worker_token_stats (
      session_id TEXT NOT NULL,
      task_id     TEXT NOT NULL DEFAULT '',
      worker_id  TEXT NOT NULL,
      user_id    TEXT,
      description TEXT,
      rx_tokens  INTEGER DEFAULT 0,
      tx_tokens  INTEGER DEFAULT 0,
      updated_at INTEGER,
      PRIMARY KEY (session_id, task_id, worker_id)
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS tasks (
      task_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      task_num INTEGER,                        -- per-session monotonic from 1; display label (1), (2), …
      task_type TEXT NOT NULL,                 -- 'one_off' | 'periodic'
      intvl_sec INTEGER NOT NULL DEFAULT 0,
      task_title TEXT,
      task_spec TEXT NOT NULL,
      task_status TEXT NOT NULL DEFAULT 'pending',
                                               -- 'pending' | 'ongoing' | 'paused'
                                               -- | 'done' | 'cancelled'
      task_result TEXT,
      time_to_pickup INTEGER,                  -- unix ms; when to next pick up this task
                                               -- (periodic next cycle; one_off future-dated)
      language TEXT NOT NULL DEFAULT 'en',
      attachments TEXT DEFAULT NULL,           -- JSON array of workspace/data paths (structured; not parsed from spec)
      back_to_when_done_task_num INTEGER,      -- Anchor back-reference.
                                               -- Set at pickup_task time when a DIFFERENT task was the
                                               -- current anchor; read at complete/cancel/pause time to
                                               -- restore that prior anchor. Nullable — free mode when nil.
                                               -- See architecture.md §Anchor mutation via back_to_when_done.
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks (session_id, task_status)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_tasks_user ON tasks (user_id, task_status)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_tasks_pickup ON tasks (task_status, time_to_pickup)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_progress (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      task_id TEXT,                           -- nullable: direct-response turns have no task
      kind TEXT NOT NULL,                     -- 'tool' | 'thinking' | 'summary'
      status TEXT,                            -- 'pending' | 'done' (tool only — mutated in place)
      label TEXT,                             -- human-readable one-liner for FE rendering
      sub_labels TEXT DEFAULT NULL,           -- JSON array of sub-activity labels (for tools with parallel internals)
      hidden INTEGER NOT NULL DEFAULT 0,      -- 1 = persisted for audit only, never shown in the FE timeline
      ts INTEGER NOT NULL
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_progress_task ON session_progress (task_id, id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_progress_session ON session_progress (session_id, ts)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS user_credentials (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      target TEXT NOT NULL,                  -- free-form label: "pi@192.168.178.22", "github-api", etc.
      cred_type TEXT NOT NULL,               -- 'ssh_key' | 'user_pass' | 'api_key' | 'token' | 'other'
      payload TEXT NOT NULL,                 -- plaintext JSON blob: {user, password} | {private_key} | {token} | ...
      notes TEXT,                            -- free-form notes from the assistant (why/when/how to use)
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE(user_id, target)
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_user_credentials_user ON user_credentials (user_id)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS model_behavior_stats (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      role          TEXT NOT NULL,              -- 'assistant' | 'confidant' | 'web_search' | 'compactor' | …
      model         TEXT NOT NULL,              -- routed string, e.g. 'ollama::cloud::gpt-oss:120b-cloud'
      issue_type    TEXT NOT NULL,              -- 'tool_call_schema' | 'task_discipline' | …
      tool_name     TEXT NOT NULL DEFAULT '',   -- tool involved (e.g. 'create_task'); '' for non-tool issues
      count         INTEGER NOT NULL DEFAULT 0,
      first_seen_at INTEGER NOT NULL,
      last_seen_at  INTEGER NOT NULL,
      UNIQUE(role, model, issue_type, tool_name)
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_model_behavior_stats_model ON model_behavior_stats (model, count DESC)")

    # Per-task raw message archive. Compaction writes turns here before
    # summarising them away from session.messages, so fetch_task can
    # replay a task's history verbatim even after the master session
    # has been compacted. See architecture.md §Task state continuity
    # across chains.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS task_turn_archive (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      task_id       TEXT NOT NULL,               -- cryptic BE id (FK to tasks.task_id)
      session_id    TEXT NOT NULL,
      original_ts   INTEGER NOT NULL,            -- the message's own ts when originally written
      role          TEXT NOT NULL,               -- 'user' | 'assistant' | 'tool'
      content       TEXT,                        -- nullable: tool_calls-only assistant msgs
      tool_calls    TEXT,                        -- JSON string, present on assistant with tool_calls
      tool_call_id  TEXT,                        -- present on role='tool'
      archived_at   INTEGER NOT NULL             -- unix ms when compaction wrote this row
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_task_turn_archive_task_ts ON task_turn_archive (task_id, original_ts)")
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
    salt_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    key = :crypto.pbkdf2_hmac(:sha256, password, salt_hex, 100_000, 32)
    salt_hex <> ":" <> Base.encode16(key, case: :lower)
  end
end
