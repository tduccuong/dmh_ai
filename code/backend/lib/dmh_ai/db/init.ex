# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init do
  require Logger
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  @db_dir "/data/db"

  def run do
    File.mkdir_p(@db_dir)
    File.mkdir_p(DmhAi.Constants.assets_dir())

    create_tables()
    migrate_columns()
    DmhAi.Agent.AgentSettings.migrate_legacy_model_keys()
    seed_admin()
    seed_pools()
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
    # Creds primitives — Phase 1 schema bump. `cred_type` → `kind`
    # (free-form label, no enum) and a new optional `expires_at`
    # (unix ms) so OAuth2-style time-bounded creds can co-exist with
    # static ones in the same table. SQLite RENAME COLUMN is 3.25+.
    rename_column_if_present("user_credentials", "cred_type", "kind")
    add_column_if_missing("user_credentials", "expires_at", "INTEGER")
    # Wall-clock duration of a tool execution in ms. Stamped by
    # `SessionProgress.mark_tool_done/2`. Null for non-tool rows
    # ('thinking' / 'summary' / 'chain_aborted'). FE renders a
    # "(Ns)" suffix on completed tool bubbles. See architecture.md
    # §Long-running tool execution.
    add_column_if_missing("session_progress", "duration_ms", "INTEGER")
    # Streaming-time chain-of-thought buffer. Populated alongside
    # `stream_buffer` while an LLM is generating; cleared at chain
    # end. Lets the FE render a live `Thinking…` block during the
    # streaming phase. See architecture.md §Polling-based delivery.
    add_column_if_missing("sessions", "thinking_buffer", "TEXT")
    add_column_if_missing("sessions", "thinking_buffer_ts", "INTEGER")
    # Per-user Linux UID inside the sandbox container — see
    # specs/permissions.md §Per-user Linux accounts in the sandbox.
    # Allocated lazily on first sandbox use (DmhAi.Permissions.SandboxUser),
    # ≥ 10001. NULL until first allocation. Uniqueness enforced by the
    # index below — SQLite ALTER TABLE can't add a UNIQUE constraint to
    # an existing column directly, so we use a UNIQUE INDEX (NULLs
    # don't collide in standard SQLite indices, which is what we want).
    add_column_if_missing("users", "unix_uid", "INTEGER")
    query!(Repo,
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_unix_uid ON users (unix_uid) WHERE unix_uid IS NOT NULL")
    # Memo encryption — see specs/memo_encryption.md.
    # `memo_kdf_salt` (16 raw bytes) is the per-user PBKDF2 salt for
    # deriving the memo wrap-key from the login password (separate
    # salt purpose from auth's password hash). `memo_wrapped_mmk` is
    # the user's master memo key wrapped with the wrap-key — wire
    # format `0x01 ‖ iv ‖ tag ‖ ct`. Both NULL until the user's first
    # post-deploy login, which generates+stores them and re-encrypts
    # any pre-existing plaintext memo rows.
    add_column_if_missing("users", "memo_kdf_salt", "BLOB")
    add_column_if_missing("users", "memo_wrapped_mmk", "BLOB")

    # Profile-extraction watermark — see ProfileExtractor. Holds the ts
    # of the last user message folded into users.profile by the
    # batched extractor. NULL means "never extracted"; the extractor
    # treats it as 0 and counts every user message as unprocessed on
    # first run.
    add_column_if_missing("users", "last_profile_extracted_msg_ts", "INTEGER")

    # One-shot sweep of legacy memo entries from kb_fts. Memo writes
    # since the encryption deploy skip kb_fts (FTS over ciphertext is
    # useless, FTS over plaintext defeats encryption — see
    # specs/memo_encryption.md). Older memo rows from before that
    # skip still have plaintext shadows in kb_fts that BM25 returns
    # on retrieval; the bm25 hits then drive `decrypt_memo_hit`,
    # which expects ciphertext and crashes on the stale plaintext
    # row's missing chunk_idx. Idempotent: subsequent runs see no
    # memo rows in kb_fts and the DELETE is a no-op.
    cleanup_memo_fts()
  end

  defp cleanup_memo_fts do
    try do
      query!(Repo, """
      DELETE FROM kb_fts
      WHERE rowid IN (SELECT id FROM kb_chunks_meta WHERE scope='memo')
      """)
    rescue
      _ -> :ok  # kb_fts may not exist on a brand-new install pre-create_tables
    end
  end

  # SQLite 3.25+ supports `ALTER TABLE … RENAME COLUMN`. The rename
  # is a no-op when the source column doesn't exist (fresh DB created
  # via the new schema, or migration already applied).
  defp rename_column_if_present(table, old, new) do
    try do
      query!(Repo, "ALTER TABLE #{table} RENAME COLUMN #{old} TO #{new}")
      Logger.info("[DB.Init] renamed #{table}.#{old} → #{new}")
    rescue
      _ -> :ok
    end
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
      thinking_buffer TEXT,                 -- partial chain-of-thought tokens streamed alongside stream_buffer; NULL when no thinking active. See architecture.md §Polling-based delivery.
      thinking_buffer_ts INTEGER,           -- last thinking_buffer update ts (ms)
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
      last_profile_extracted_msg_ts INTEGER,
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
      kind TEXT NOT NULL,                     -- 'tool' | 'thinking' | 'summary' | 'chain_aborted'
      status TEXT,                            -- 'pending' | 'done' (tool only — mutated in place)
      label TEXT,                             -- human-readable one-liner for FE rendering
      sub_labels TEXT DEFAULT NULL,           -- JSON array of sub-activity labels (for tools with parallel internals)
      hidden INTEGER NOT NULL DEFAULT 0,      -- 1 = persisted for audit only, never shown in the FE timeline
      duration_ms INTEGER,                    -- wall-clock tool-execution duration; stamped on the pending→done flip. Null for non-tool rows.
      ts INTEGER NOT NULL
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_progress_task ON session_progress (task_id, id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_progress_session ON session_progress (session_id, ts)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS user_credentials (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      target TEXT NOT NULL,                  -- free-form label: host+user, service name, API name
      kind TEXT NOT NULL,                    -- free-form: 'ssh_key' | 'user_pass' | 'api_key' | 'oauth2' | …
      payload TEXT NOT NULL,                 -- plaintext JSON, shape determined by `kind`
      notes TEXT,                            -- free-form notes from the assistant (why/when/how to use)
      expires_at INTEGER,                    -- optional unix ms expiry (OAuth2 access tokens etc.); NULL = non-expiring
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE(user_id, target)
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_user_credentials_user ON user_credentials (user_id)")

    # Pending OAuth2 state tokens for the connect_mcp flow. One
    # row per in-flight authorization. Carries everything needed to
    # exchange the code and attach the service to the originating
    # task without re-doing discovery: PKCE verifier, client_id (and
    # optional client_secret), the cached ASM doc, the canonical
    # resource id, and the (user_id, session_id, anchor_task_id,
    # alias) the connection is being established for. Single-use —
    # the callback handler deletes the row on success. TTL via
    # `expires_at` (default `oauthStateTtlSecs`, 600 s).
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS pending_oauth_states (
      state              TEXT PRIMARY KEY,
      user_id            TEXT NOT NULL,
      session_id         TEXT NOT NULL,
      anchor_task_id     TEXT NOT NULL,
      alias              TEXT NOT NULL,
      canonical_resource TEXT NOT NULL,
      server_url         TEXT NOT NULL,
      pkce_verifier      TEXT NOT NULL,
      client_id          TEXT NOT NULL,
      client_secret      TEXT,
      asm_json           TEXT NOT NULL,
      scopes             TEXT,
      redirect_uri       TEXT NOT NULL,
      created_at         INTEGER NOT NULL,
      expires_at         INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_pending_oauth_states_user ON pending_oauth_states (user_id)")

    # Per-user authorized external services. One row per service the
    # user has ever authorized. Survives sessions, restarts, task
    # lifecycles. Authorization here is necessary but not sufficient
    # for the LLM to see the service's tools — task_services must
    # also bind the service to the active task. `server_tools_json`
    # is the last-known tools/list result; `asm_json` caches the
    # authorization-server metadata for the refresh hook.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS authorized_services (
      user_id                TEXT NOT NULL,
      alias                  TEXT NOT NULL,
      canonical_resource     TEXT NOT NULL,
      server_url             TEXT NOT NULL,
      asm_json               TEXT,
      server_tools_json      TEXT,
      server_tools_cached_at INTEGER,
      -- Lifecycle: 'authorized' (token works) | 'needs_auth' (token
      -- refresh failed AS-side; model must call connect_mcp to
      -- recover). `tools_for_task/2` filters out needs_auth services
      -- so the LLM doesn't emit names it can no longer invoke; the
      -- §Authorized MCP services context block surfaces them with a
      -- `[needs re-auth]` annotation so the model knows to act.
      -- `authorize/5` resets to 'authorized' on re-auth.
      status                 TEXT NOT NULL DEFAULT 'authorized',
      created_ts             INTEGER NOT NULL,
      PRIMARY KEY (user_id, alias)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_authorized_services_user ON authorized_services (user_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_authorized_services_resource ON authorized_services (canonical_resource)")

    # Task ↔ authorized-service junction. One row per service
    # attached to a task. Per-turn tool catalog filters to services
    # in this table for the current anchor task; complete_task /
    # cancel_task drop every row for that task.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS task_services (
      task_id     TEXT NOT NULL,
      user_id     TEXT NOT NULL,
      alias       TEXT NOT NULL,
      attached_ts INTEGER NOT NULL,
      PRIMARY KEY (task_id, alias)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_task_services_user ON task_services (user_id, alias)")

    # Admin-curated MCP catalog. Each row is a blessed service —
    # admin sets up name + URL + optional metadata, clicks Enable to
    # run a preflight probe (DmhAi.MCP.Probe) which classifies the
    # service as :open / :gated / :not_mcp and persists auth_kind
    # and any AS metadata harvested during the probe. The chat tool
    # `connect_mcp(slug:)` reads this row and skips PRM/ASM
    # discovery, walking users straight into auth.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS mcp_catalog (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      slug              TEXT    NOT NULL UNIQUE,
      name              TEXT    NOT NULL,
      description       TEXT,
      mcp_url           TEXT    NOT NULL,
      icon_url          TEXT,
      categories        TEXT,                          -- JSON array of strings
      enabled           INTEGER NOT NULL DEFAULT 0,    -- 0/1
      auth_kind         TEXT,                          -- 'none' | 'oauth' | 'api_key' | NULL
      auth_metadata     TEXT,                          -- JSON object (PRM hint URL, AS endpoint, scopes…)
      last_probe_status TEXT,                          -- 'open' | 'gated' | 'not_mcp' | 'error' | NULL
      last_probe_error  TEXT,                          -- human-readable error from the probe attempt
      last_probe_at     INTEGER,                       -- ms epoch
      created_at        INTEGER NOT NULL,
      updated_at        INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_mcp_catalog_enabled ON mcp_catalog (enabled)")

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

    # Vector knowledge base — see specs/vector_kb.md.
    #
    #   kb_sources       — registry of every /wiki / /memo / save_memo
    #                      ingest. Source-of-truth for relearn flows.
    #                      `centroid` (averaged chunk embedding) gates
    #                      semantic-merge for inline-text ingest.
    #   kb_chunks_meta   — non-vector metadata for each chunk; rowid
    #                      links 1:1 to the corresponding kb_vec_* row.
    #   kb_vec_knowledge — vec0 virtual table holding the global vectors.
    #   kb_vec_memo      — vec0 virtual table for per-user memos.
    #   kb_seeds         — admin-curated URL list for one-click batch /wiki.
    #   kb_relearn_jobs  — dedup table for the background re-fetch supervisor.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_sources (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      scope        TEXT NOT NULL CHECK (scope IN ('knowledge', 'memo')),
      user_id      TEXT,
      source_kind  TEXT NOT NULL,
      source_ref   TEXT NOT NULL,
      title        TEXT,
      raw_text     TEXT,
      centroid     BLOB,
      tags         TEXT,
      indexed_at   INTEGER NOT NULL,
      UNIQUE(scope, user_id, source_ref)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_sources_scope ON kb_sources (scope, user_id)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_chunks_meta (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      scope        TEXT NOT NULL CHECK (scope IN ('knowledge', 'memo')),
      user_id      TEXT,
      source_id    INTEGER NOT NULL REFERENCES kb_sources(id) ON DELETE CASCADE,
      chunk_idx    INTEGER NOT NULL,
      chunk_text   TEXT NOT NULL,
      indexed_at   INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_source ON kb_chunks_meta (source_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_scope ON kb_chunks_meta (scope, user_id)")

    # vec0 virtual tables. Dimension is hard-coded; distance metric
    # is cosine (semantic similarity, magnitude-invariant — see
    # specs/vector_kb.md). Changing dim or metric means dropping +
    # reindexing both tables; `migrate_vec_tables_to_cosine/0`
    # handles the L2 → cosine migration on boot for existing dbs.
    query!(Repo, "CREATE VIRTUAL TABLE IF NOT EXISTS kb_vec_knowledge USING vec0(embedding float[1024] distance_metric=cosine)")
    query!(Repo, "CREATE VIRTUAL TABLE IF NOT EXISTS kb_vec_memo      USING vec0(embedding float[1024] distance_metric=cosine)")
    migrate_vec_tables_to_cosine()

    # FTS5 inverted index over chunk_text — feeds the BM25 leg of
    # hybrid search (#182). Contentless table (text not duplicated;
    # we already have it in `kb_chunks_meta`); rowid mirrors
    # `kb_chunks_meta.id`. `contentless_delete=1` lets us issue
    # plain `DELETE FROM kb_fts WHERE rowid=?` on chunk delete.
    # Tokenizer `unicode61` handles diacritics + case-folding for
    # multilingual content (Vietnamese / German / etc.) — the
    # default tokenizer is ASCII-only and would index "đỏ" as
    # something useless.
    query!(Repo, """
    CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts USING fts5(
      chunk_text,
      content='',
      contentless_delete=1,
      tokenize='unicode61 remove_diacritics 2'
    )
    """)
    migrate_fts5_backfill()

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_seeds (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      url           TEXT NOT NULL UNIQUE,
      label         TEXT,
      tags          TEXT,
      last_run_at   INTEGER,
      last_status   TEXT,
      last_error    TEXT,
      created_at    INTEGER NOT NULL
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_relearn_jobs (
      source_ref   TEXT PRIMARY KEY,
      source_kind  TEXT NOT NULL,
      enqueued_at  INTEGER NOT NULL
    )
    """)

    # Pools — model-routing registry. See specs/api_pools.md.
    # Replaces the legacy <provider>::<local|cloud>::<model> scheme. A
    # pool bundles endpoint config + account rotation, addressed in
    # canonical model strings as <pool>::<model>.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS pools (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      name             TEXT NOT NULL UNIQUE,
      provider         TEXT NOT NULL,           -- 'ollama' | 'openai' | …
      base_url         TEXT NOT NULL,
      strategy         TEXT NOT NULL DEFAULT 'least_used',
      cooldown_seconds INTEGER NOT NULL DEFAULT 300,
      num_ctx          INTEGER,                 -- per-pool Ollama options.num_ctx;
                                                -- NULL = don't inject (server default applies)
      accounts         TEXT NOT NULL DEFAULT '[]',
                                                -- JSON array: [{name, api_key, throttled_until?, last_used_ts?}]
      rr_cursor        INTEGER NOT NULL DEFAULT 0,
                                                -- round-robin cursor (only used when strategy='round_robin')
      created_ts       INTEGER NOT NULL,
      updated_ts       INTEGER NOT NULL
    )
    """)

    migrate_pools_drop_api_format()
    migrate_pools_add_num_ctx()
  end

  # Add the `num_ctx` column to existing pools tables. Per-pool
  # Ollama context-window override; NULL means don't inject (server
  # default applies). See specs/api_pools.md. Idempotent: a no-op
  # once the column is present.
  defp migrate_pools_add_num_ctx do
    sql =
      case query!(Repo, "SELECT sql FROM sqlite_master WHERE type='table' AND name='pools'", []).rows do
        [[s]] when is_binary(s) -> s
        _ -> ""
      end

    if not String.contains?(sql, "num_ctx") do
      Logger.info("[DB.Init] adding pools.num_ctx (per-pool Ollama context override)")
      query!(Repo, "ALTER TABLE pools ADD COLUMN num_ctx INTEGER", [])
    end
  end

  # Drop the legacy `api_format` column from existing pools tables.
  # Provider-driven adapter dispatch (#185 phase 3) made it dead — the
  # wire protocol is determined entirely by `provider`. Idempotent: a
  # no-op once the column is gone. Requires SQLite 3.35+ (released
  # 2021-03), guaranteed on every deployment we care about.
  defp migrate_pools_drop_api_format do
    sql =
      case query!(Repo, "SELECT sql FROM sqlite_master WHERE type='table' AND name='pools'", []).rows do
        [[s]] when is_binary(s) -> s
        _ -> ""
      end

    if String.contains?(sql, "api_format") do
      Logger.info("[DB.Init] dropping pools.api_format (provider-driven dispatch)")
      query!(Repo, "ALTER TABLE pools DROP COLUMN api_format", [])
    end
  end

  # Migrate any existing vec0 tables that were created without
  # `distance_metric=cosine` (the prior default was L2). vec0's
  # metric is fixed at table creation, so the only path is drop +
  # recreate + re-embed every chunk. Detection: read the CREATE
  # statement from sqlite_master and check whether it mentions
  # cosine. Idempotent: a no-op once tables are on cosine.
  #
  # Re-embedding fires synchronously during boot — fine for the
  # current corpus size (a few hundred memo chunks per user). If
  # the corpus grows past that, move this to a background task.
  defp migrate_vec_tables_to_cosine do
    Enum.each([:knowledge, :memo], fn scope ->
      vec_table =
        case scope do
          :knowledge -> "kb_vec_knowledge"
          :memo      -> "kb_vec_memo"
        end

      sql =
        case query!(Repo, "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [vec_table]).rows do
          [[s]] when is_binary(s) -> s
          _                        -> ""
        end

      cond do
        sql == "" ->
          # Table was just freshly created with cosine — nothing to migrate.
          :ok

        String.contains?(sql, "distance_metric=cosine") ->
          # Already on cosine.
          :ok

        true ->
          Logger.info("[DB.Init] migrating #{vec_table} from L2 → cosine (re-embedding existing chunks)")
          rebuild_vec_table_as_cosine(scope, vec_table)
      end
    end)
  end

  # Drop the old L2 vec0 table, recreate with cosine, then re-embed
  # every chunk from `kb_chunks_meta` and re-insert with the same
  # rowid. Per-batch embedder calls (size capped by AgentSettings)
  # so a stale embedder pool doesn't compound the boot delay.
  defp rebuild_vec_table_as_cosine(scope, vec_table) do
    rows =
      query!(Repo,
        "SELECT id, chunk_text FROM kb_chunks_meta WHERE scope=? ORDER BY id ASC",
        [Atom.to_string(scope)]).rows

    query!(Repo, "DROP TABLE IF EXISTS #{vec_table}", [])

    query!(Repo,
      "CREATE VIRTUAL TABLE IF NOT EXISTS #{vec_table} USING vec0(embedding float[1024] distance_metric=cosine)", [])

    case rows do
      [] ->
        Logger.info("[DB.Init] #{vec_table} migration: no chunks to re-embed")
        :ok

      _ ->
        batch_size = DmhAi.Agent.AgentSettings.kb_embedding_batch_size()

        rows
        |> Enum.chunk_every(batch_size)
        |> Enum.each(fn batch ->
          texts = Enum.map(batch, fn [_id, text] -> text end)

          case DmhAi.VectorDB.Embedder.embed_batch(texts) do
            {:ok, vecs} ->
              Enum.zip(batch, vecs)
              |> Enum.each(fn {[id, _text], vec} ->
                blob = encode_vector_le(vec)
                query!(Repo, "INSERT INTO #{vec_table}(rowid, embedding) VALUES (?, ?)", [id, blob])
              end)

            {:error, reason} ->
              Logger.error("[DB.Init] re-embed failed for #{vec_table}: #{inspect(reason)} — skipping #{length(batch)} chunks")
          end
        end)

        Logger.info("[DB.Init] #{vec_table} migration: re-embedded #{length(rows)} chunks")
    end
  end

  # Pack a list of floats into a vec0-compatible LE blob. Mirrors
  # `DmhAi.VectorDB.SqliteVec.encode_vector/1`; duplicated here so
  # the migration doesn't depend on an alias-loop with that module.
  defp encode_vector_le(floats) do
    Enum.reduce(floats, <<>>, fn f, acc -> acc <> <<f::little-float-32>> end)
  end

  # Backfill the FTS5 index from existing `kb_chunks_meta` rows.
  # Idempotent: `INSERT OR IGNORE` skips any rowid already in the
  # FTS5 table, so re-running on every boot is cheap (the dup-check
  # is just an index probe per row). Boot-time cost on a fresh-from-
  # migration database: one full scan; on subsequent boots: near-
  # instant. The chunk-add path keeps FTS5 in sync going forward, so
  # this is mainly for the v2 → hybrid upgrade path.
  defp migrate_fts5_backfill do
    %{rows: [[meta_count]]} = query!(Repo, "SELECT COUNT(*) FROM kb_chunks_meta", [])
    %{rows: [[fts_count]]}  = query!(Repo, "SELECT COUNT(*) FROM kb_fts", [])

    if meta_count > fts_count do
      Logger.info("[DB.Init] FTS5 backfill: meta=#{meta_count} fts=#{fts_count} → backfilling missing")

      query!(Repo, """
      INSERT OR IGNORE INTO kb_fts(rowid, chunk_text)
      SELECT id, chunk_text FROM kb_chunks_meta
      """, [])

      %{rows: [[after_count]]} = query!(Repo, "SELECT COUNT(*) FROM kb_fts", [])
      Logger.info("[DB.Init] FTS5 backfill: now #{after_count} rows")
    end

    :ok
  rescue
    e ->
      Logger.warning("[DB.Init] FTS5 backfill failed: #{Exception.message(e)}")
      :ok
  end

  # Seed default pools on first boot. Importable from an operator-managed
  # pools.json (see load_pool_seeds/0 for path order). When no file is
  # found, only the `ollama-cloud` placeholder is inserted so the admin UI
  # has something to edit. Idempotent — re-run on every boot, but only
  # inserts pools that don't already exist by name.
  defp seed_pools do
    existing = query!(Repo, "SELECT name FROM pools", []).rows |> List.flatten() |> MapSet.new()

    seeds = load_pool_seeds()

    now = System.os_time(:millisecond)

    Enum.each(seeds, fn pool ->
      if not MapSet.member?(existing, pool["name"]) do
        query!(Repo, """
        INSERT INTO pools (name, provider, base_url, strategy,
                           cooldown_seconds, num_ctx, accounts, rr_cursor,
                           created_ts, updated_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        """, [
          pool["name"],
          pool["provider"],
          pool["base_url"],
          pool["strategy"] || "least_used",
          pool["cooldown_seconds"] || 300,
          pool["num_ctx"],
          Jason.encode!(pool["accounts"] || []),
          now, now
        ])
        Logger.info("[DB.Init] seeded pool: #{pool["name"]}")
      end
    end)
  end

  # Look for an operator-managed pool seed file. Path order:
  #   1. $DMHAI_POOL_SEED  — explicit override
  #   2. /data/pools.json — operator file bind-mounted into the container
  #   3. ./temp/pools.json — repo-local copy used in dev
  # Falls back to a built-in placeholder set if none of those exist.
  defp load_pool_seeds do
    candidate_paths = [
      System.get_env("DMHAI_POOL_SEED"),
      "/data/pools.json",
      "temp/pools.json"
    ]
    |> Enum.reject(&is_nil/1)

    case Enum.find(candidate_paths, &File.exists?/1) do
      nil ->
        default_pool_seeds()

      path ->
        try do
          %{"pools" => pools} = path |> File.read!() |> Jason.decode!()
          # Translate pools.json's account `api_key` field to our schema
          # (already aligned), but keep both shapes accepted.
          Enum.map(pools, fn p ->
            accounts =
              (p["accounts"] || [])
              |> Enum.map(fn a ->
                %{
                  "name"    => a["name"] || a["api_key"] || "unknown",
                  "api_key" => a["api_key"] || a["apiKey"] || a["key"] || ""
                }
              end)

            Map.put(p, "accounts", accounts)
          end)
        rescue
          e ->
            Logger.warning("[DB.Init] pool seed file #{path} unreadable (#{Exception.message(e)}); using defaults")
            default_pool_seeds()
        end
    end
  end

  defp default_pool_seeds do
    [
      %{
        "name" => "ollama-cloud",
        "provider" => "ollama",
        "base_url" => "https://ollama.com/v1",
        "strategy" => "least_used",
        "cooldown_seconds" => 300,
        "accounts" => []
      }
    ]
  end

  defp seed_admin do
    result = query!(Repo, "SELECT id FROM users WHERE email=?", ["admin@dmhai.local"])

    if result.rows == [] do
      uid = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      password_hash = hash_password("dmh_ai")
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
