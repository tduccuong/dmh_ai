# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init.Tables do
  @moduledoc """
  Canonical schema for a fresh install. One function — `create_all/0` —
  issues every `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`
  statement the running app needs. The module describes the schema as it
  exists today; schema changes between releases are applied as one-off
  operator-run DB scripts outside the app, never as auto-running migrations
  on boot.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 2]

  def create_all do
    # Organizations — Primitive 0.1. Every scoped artefact in the
    # system points back here via `org_id`. NEVER NULL on any scoped
    # row. Fresh installs auto-create one row via BootstrapSeed so
    # the rest of the schema can rely on the foreign key existing.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS organizations (
      id            TEXT PRIMARY KEY,
      name          TEXT NOT NULL,
      settings_json TEXT,
      created_at    INTEGER NOT NULL
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT,
      model TEXT,
      messages TEXT DEFAULT '[]',
      context TEXT,
      user_id TEXT DEFAULT '',
      -- Streaming state (partial final-answer + chain-of-thought
      -- tokens during a turn) lives in DmhAi.Agent.EphemeralCache
      -- ETS, NOT this table. See architecture.md §Streaming state
      -- lives in ETS, not the DB. Per-token DB writes monopolised
      -- SQLite's single-writer slot in WAL mode.
      cancelled_at INTEGER,                  -- Stop-button stamp; chain loop aborts on its next iteration
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
      email_aliases TEXT,                     -- JSON array of additional emails the user is known by in third-party SaaS (Primitive 0.9). Default NULL = no aliases. Admin-only edit. Identities.resolve/2 tries primary then aliases.
      name TEXT,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user',       -- install-level superuser flag: 'admin' = admin of the deployment itself; 'user' = regular user. Distinct from org_role.
      org_id TEXT NOT NULL,                    -- FK organizations.id; never NULL (Primitive 0.1)
      org_role TEXT NOT NULL DEFAULT 'member', -- role within their org: 'member' | 'manager' | 'admin'
      preferences TEXT,                       -- per-user JSON blob: token-saving toggle, future personal prefs
      unix_uid INTEGER,                       -- per-user Linux UID inside the sandbox (≥ 10001); allocated lazily
      password_changed INTEGER DEFAULT 0,
      deleted INTEGER DEFAULT 0,
      created_at INTEGER
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_users_org ON users (org_id)")
    query!(Repo,
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_unix_uid ON users (unix_uid) WHERE unix_uid IS NOT NULL")

    # Bearer tokens are stored as sha256 hashes (lowercase hex), not
    # the raw 256-bit token returned to the client. Token entropy is
    # already 256 bits via :crypto.strong_rand_bytes(32) in
    # post_login, so plain sha256 (no salt, no PBKDF2) is the right
    # fit — there's nothing to brute-force at that entropy. The hash
    # converts a SQL-exfil into "no live tokens leaked"; without it,
    # `SELECT * FROM auth_tokens` is every active session.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS auth_tokens (
      token_hash TEXT PRIMARY KEY,
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

    # Per-tier token accounting. One row per (session_id, user_id) pair,
    # plus one synthetic per-user row keyed by the sentinel session_id
    # `_user_global` for LLM calls made outside a session (the background
    # fact extractor). `get_global_stats/1` sums across ALL rows for the
    # user — including the sentinel — to give a complete user-global total.
    # Tier names are the atoms `:master | :swift | :oracle | :vision |
    # :embedding`; TokenTracker.add/5 picks the column pair by atom.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_token_stats (
      session_id TEXT PRIMARY KEY,
      user_id TEXT,
      master_rx_tokens    INTEGER DEFAULT 0,
      master_tx_tokens    INTEGER DEFAULT 0,
      swift_rx_tokens     INTEGER DEFAULT 0,
      swift_tx_tokens     INTEGER DEFAULT 0,
      oracle_rx_tokens    INTEGER DEFAULT 0,
      oracle_tx_tokens    INTEGER DEFAULT 0,
      vision_rx_tokens    INTEGER DEFAULT 0,
      vision_tx_tokens    INTEGER DEFAULT 0,
      embedding_rx_tokens INTEGER DEFAULT 0,
      embedding_tx_tokens INTEGER DEFAULT 0,
      updated_at INTEGER
    )
    """)


    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_progress (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      kind TEXT NOT NULL,                     -- 'tool' | 'thinking' | 'summary' | 'chain_aborted' | 'chain_end'
      status TEXT,                            -- 'pending' | 'done' (tool only — mutated in place)
      label TEXT,                             -- human-readable one-liner for FE rendering
      sub_labels TEXT DEFAULT NULL,           -- JSON array of sub-activity labels (for tools with parallel internals)
      hidden INTEGER NOT NULL DEFAULT 0,      -- 1 = persisted for audit only, never shown in the FE timeline
      duration_ms INTEGER,                    -- wall-clock tool-execution duration; stamped on the pending→done flip. Null for non-tool rows.
      ts INTEGER NOT NULL
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_progress_session ON session_progress (session_id, ts)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS user_credentials (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      target TEXT NOT NULL,                  -- free-form label: host+user, service name, API name
      account TEXT NOT NULL DEFAULT '',      -- per-account label (email/login from provider userinfo); '' for non-account creds (api_key etc.)
      kind TEXT NOT NULL,                    -- free-form: 'ssh_key' | 'user_pass' | 'api_key' | 'oauth2' | …
      payload TEXT NOT NULL,                 -- plaintext JSON, shape determined by `kind`
      notes TEXT,                            -- free-form notes from the assistant (why/when/how to use)
      expires_at INTEGER,                    -- optional unix ms expiry (OAuth2 access tokens etc.); NULL = non-expiring
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE(user_id, target, account)
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_user_credentials_user ON user_credentials (user_id)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS model_behavior_stats (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      role          TEXT NOT NULL,              -- 'assistant' | 'confidant' | 'web_search' | 'compactor' | …
      model         TEXT NOT NULL,              -- routed string, e.g. 'ollama::cloud::gpt-oss:120b-cloud'
      issue_type    TEXT NOT NULL,              -- 'tool_call_schema' | 'arguments_decode' | …
      tool_name     TEXT NOT NULL DEFAULT '',   -- tool involved (e.g. 'run_script'); '' for non-tool issues
      count         INTEGER NOT NULL DEFAULT 0,
      first_seen_at INTEGER NOT NULL,
      last_seen_at  INTEGER NOT NULL,
      UNIQUE(role, model, issue_type, tool_name)
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_model_behavior_stats_model ON model_behavior_stats (model, count DESC)")

    # Audit log — every permission denial + cross-user / cross-org
    # access lands here. Per Primitive 0.1 (audit history visible to
    # managers) and Primitive 0.7 (per-org permission model).
    #
    #   action      — :read | :write | :invoke | :approve | :administer
    #   resource    — JSON-encoded resource tag, e.g.
    #                 {"kind":"verb","name":"hubspot.deal.create"}
    #   outcome     — 'allowed' | 'denied' (denials are the primary
    #                 use case; allowed-rows are written for
    #                 high-sensitivity actions only)
    #   reason      — short tag explaining a denial
    #                 ('role_too_low', 'missing_credentials', …)
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS audit_log (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id        TEXT NOT NULL,
      user_id       TEXT,
      action        TEXT NOT NULL,
      resource      TEXT NOT NULL,
      outcome       TEXT NOT NULL,
      reason        TEXT,
      created_at    INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_audit_log_org_ts ON audit_log (org_id, created_at)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_audit_log_user_ts ON audit_log (user_id, created_at)")

    # Pools — model-routing registry. See arch_wiki/dmh_ai/integrations.md
    # §API Pools. A pool bundles endpoint config + account rotation,
    # addressed in canonical model strings as <pool>::<model>. The
    # `protocol` column drives wire-format dispatch in
    # `DmhAi.Agent.LLM.adapter_for/1`.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS pools (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id           TEXT NOT NULL,           -- FK organizations.id; per-org pool catalog (Primitive 0.1)
      name             TEXT NOT NULL,
      protocol         TEXT NOT NULL,           -- 'openai' | 'ollama' | 'anthropic'
      base_url         TEXT NOT NULL,
      strategy         TEXT NOT NULL DEFAULT 'least_used',
      cooldown_seconds INTEGER NOT NULL DEFAULT 300,
      num_ctx          INTEGER,                 -- per-pool Ollama options.num_ctx;
                                                -- NULL = don't inject (server default applies)
      accounts         TEXT NOT NULL DEFAULT '[]',
                                                -- JSON array: [{name, api_key, throttled_until?, last_used_ts?}]
      models           TEXT NOT NULL DEFAULT '[]',
                                                -- JSON array of strings; static model
                                                -- list for endpoints that don't expose
                                                -- /models. Empty = discover live.
      rr_cursor        INTEGER NOT NULL DEFAULT 0,
                                                -- round-robin cursor (only used when strategy='round_robin')
      created_ts       INTEGER NOT NULL,
      updated_ts       INTEGER NOT NULL,
      UNIQUE(org_id, name)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_pools_org ON pools (org_id)")
  end
end
