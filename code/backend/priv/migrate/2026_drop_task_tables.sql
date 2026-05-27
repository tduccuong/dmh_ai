-- One-off DB migration: drop the task subsystem tables and rename
-- task_services → session_services. Run this script ONCE against the
-- live DB after deploying the new code; the application no longer
-- auto-migrates schemas on boot.
--
-- The two ALTER TABLE … RENAME statements (pending_oauth_states,
-- session_progress) and the final ALTER TABLE … ADD COLUMN are NOT
-- idempotent — re-running this script will fail on those lines once
-- the migration has been applied. The DROP TABLE / CREATE TABLE
-- IF NOT EXISTS lines are individually safe.

DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS task_chain_archive;
DROP TABLE IF EXISTS worker_token_stats;

-- Re-key the MCP attachment junction. The new schema uses session_id.
-- Live attachments will be lost; users re-attach via connect_mcp.
DROP TABLE IF EXISTS task_services;
CREATE TABLE IF NOT EXISTS session_services (
  session_id  TEXT NOT NULL,
  user_id     TEXT NOT NULL,
  alias       TEXT NOT NULL,
  attached_ts INTEGER NOT NULL,
  PRIMARY KEY (session_id, alias)
);
CREATE INDEX IF NOT EXISTS idx_session_services_user ON session_services (user_id, alias);

-- Drop the anchor_task_id column from pending_oauth_states. SQLite
-- can't DROP COLUMN before 3.35 — recreate the table.
ALTER TABLE pending_oauth_states RENAME TO pending_oauth_states_old;

CREATE TABLE IF NOT EXISTS pending_oauth_states (
  state              TEXT PRIMARY KEY,
  user_id            TEXT NOT NULL,
  session_id         TEXT NOT NULL,
  alias              TEXT NOT NULL,
  canonical_resource TEXT NOT NULL,
  server_url         TEXT NOT NULL,
  pkce_verifier      TEXT NOT NULL,
  client_id          TEXT NOT NULL,
  client_secret      TEXT,
  asm_json           TEXT NOT NULL,
  scopes             TEXT,
  redirect_uri       TEXT NOT NULL,
  flow_kind          TEXT NOT NULL DEFAULT 'mcp',
  created_at         INTEGER NOT NULL,
  expires_at         INTEGER NOT NULL
);

INSERT INTO pending_oauth_states
  (state, user_id, session_id, alias, canonical_resource, server_url,
   pkce_verifier, client_id, client_secret, asm_json, scopes,
   redirect_uri, flow_kind, created_at, expires_at)
SELECT
   state, user_id, session_id, alias, canonical_resource, server_url,
   pkce_verifier, client_id, client_secret, asm_json, scopes,
   redirect_uri, flow_kind, created_at, expires_at
FROM pending_oauth_states_old;

DROP TABLE pending_oauth_states_old;

-- Drop the task_id column from session_progress. Same shape — copy
-- + rename.
ALTER TABLE session_progress RENAME TO session_progress_old;

CREATE TABLE IF NOT EXISTS session_progress (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  status TEXT,
  label TEXT,
  sub_labels TEXT DEFAULT NULL,
  hidden INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER,
  ts INTEGER NOT NULL
);

INSERT INTO session_progress
  (id, session_id, user_id, kind, status, label, sub_labels, hidden, duration_ms, ts)
SELECT
   id, session_id, user_id, kind, status, label, sub_labels, hidden, duration_ms, ts
FROM session_progress_old;

DROP TABLE session_progress_old;

CREATE INDEX IF NOT EXISTS idx_session_progress_session ON session_progress (session_id, ts);

-- Rebuild sessions: add `cancelled_at` (Stop button) and drop the
-- legacy `tool_history` JSON column (replaced by the rolling tool-
-- result flush). The Phase 1 compaction summary lives inside the
-- existing `context` JSON blob, not a dedicated column. We pre-add
-- `cancelled_at` so the subsequent SELECT can pull it from the old
-- table; if the column already exists this ALTER fails — fine, the
-- migration is one-shot.
ALTER TABLE sessions ADD COLUMN cancelled_at INTEGER;

ALTER TABLE sessions RENAME TO sessions_old;

CREATE TABLE IF NOT EXISTS sessions (
  id           TEXT PRIMARY KEY NOT NULL,
  name         TEXT,
  model        TEXT,
  messages     TEXT DEFAULT '[]',
  context      TEXT,
  user_id      TEXT DEFAULT '',
  mode         TEXT DEFAULT 'assistant',
  cancelled_at INTEGER,
  created_at   INTEGER,
  updated_at   INTEGER DEFAULT 0
);

INSERT INTO sessions
  (id, name, model, messages, context, user_id, mode, cancelled_at, created_at, updated_at)
SELECT
   id, name, model, messages, context, user_id, mode, cancelled_at, created_at, updated_at
FROM sessions_old;

DROP TABLE sessions_old;
