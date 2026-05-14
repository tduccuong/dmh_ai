-- 0001_org_scoping.sql — Primitive 0.1 schema migration.
--
-- One-off operator-run migration. Apply via:
--
--     sqlite3 /data/db/chat.db < 0001_org_scoping.sql
--
-- Idempotent: every statement uses IF NOT EXISTS / OR IGNORE so a
-- re-run is a no-op. The repo's db/init.ex describes the schema as a
-- fresh install would see it — this file is the operator's bridge
-- from the pre-org-scoping shape to the new shape.

BEGIN TRANSACTION;

-- 1. organizations table + default row.
CREATE TABLE IF NOT EXISTS organizations (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  settings_json TEXT,
  created_at    INTEGER NOT NULL
);

INSERT OR IGNORE INTO organizations (id, name, settings_json, created_at)
VALUES ('default', 'Default Organization', NULL, CAST(strftime('%s','now') AS INTEGER) * 1000);

-- 2. users: add org_id + org_role; backfill all rows to the default org.
--    Existing single-install admin becomes org admin.
ALTER TABLE users ADD COLUMN org_id   TEXT;
ALTER TABLE users ADD COLUMN org_role TEXT;
UPDATE users SET org_id   = 'default' WHERE org_id   IS NULL;
UPDATE users SET org_role = CASE WHEN role = 'admin' THEN 'admin' ELSE 'member' END
                WHERE org_role IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_org ON users (org_id);

-- 3. pools: add org_id, drop the global UNIQUE(name), add UNIQUE(org_id, name).
--    SQLite can't drop columns or constraints in-place; the safe path is
--    a table copy. Doing it transactionally below.
CREATE TABLE pools_new (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id           TEXT NOT NULL,
  name             TEXT NOT NULL,
  protocol         TEXT NOT NULL,
  base_url         TEXT NOT NULL,
  strategy         TEXT NOT NULL DEFAULT 'least_used',
  cooldown_seconds INTEGER NOT NULL DEFAULT 300,
  num_ctx          INTEGER,
  accounts         TEXT NOT NULL DEFAULT '[]',
  models           TEXT NOT NULL DEFAULT '[]',
  rr_cursor        INTEGER NOT NULL DEFAULT 0,
  created_ts       INTEGER NOT NULL,
  updated_ts       INTEGER NOT NULL,
  UNIQUE(org_id, name)
);
INSERT INTO pools_new (id, org_id, name, protocol, base_url, strategy,
                       cooldown_seconds, num_ctx, accounts, models, rr_cursor,
                       created_ts, updated_ts)
  SELECT id, 'default', name, protocol, base_url, strategy,
         cooldown_seconds, num_ctx, accounts, models, rr_cursor,
         created_ts, updated_ts
  FROM pools;
DROP TABLE pools;
ALTER TABLE pools_new RENAME TO pools;
CREATE INDEX IF NOT EXISTS idx_pools_org ON pools (org_id);

-- 4. mcp_catalog: same shape — add org_id, change UNIQUE(slug) → UNIQUE(org_id, slug).
CREATE TABLE mcp_catalog_new (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id            TEXT NOT NULL,
  slug              TEXT NOT NULL,
  name              TEXT NOT NULL,
  description       TEXT,
  mcp_url           TEXT NOT NULL,
  icon_url          TEXT,
  categories        TEXT,
  enabled           INTEGER NOT NULL DEFAULT 0,
  auth_kind         TEXT,
  auth_metadata     TEXT,
  last_probe_status TEXT,
  last_probe_error  TEXT,
  last_probe_at     INTEGER,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  UNIQUE(org_id, slug)
);
INSERT INTO mcp_catalog_new (id, org_id, slug, name, description, mcp_url,
                             icon_url, categories, enabled, auth_kind,
                             auth_metadata, last_probe_status,
                             last_probe_error, last_probe_at,
                             created_at, updated_at)
  SELECT id, 'default', slug, name, description, mcp_url,
         icon_url, categories, enabled, auth_kind,
         auth_metadata, last_probe_status,
         last_probe_error, last_probe_at,
         created_at, updated_at
  FROM mcp_catalog;
DROP TABLE mcp_catalog;
ALTER TABLE mcp_catalog_new RENAME TO mcp_catalog;
CREATE INDEX IF NOT EXISTS idx_mcp_catalog_enabled ON mcp_catalog (org_id, enabled);

-- 5. kb_seeds: add org_id, change UNIQUE(url) → UNIQUE(org_id, url).
CREATE TABLE kb_seeds_new (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id        TEXT NOT NULL,
  url           TEXT NOT NULL,
  label         TEXT,
  tags          TEXT,
  last_run_at   INTEGER,
  last_status   TEXT,
  last_error    TEXT,
  created_at    INTEGER NOT NULL,
  UNIQUE(org_id, url)
);
INSERT INTO kb_seeds_new (id, org_id, url, label, tags,
                          last_run_at, last_status, last_error, created_at)
  SELECT id, 'default', url, label, tags,
         last_run_at, last_status, last_error, created_at
  FROM kb_seeds;
DROP TABLE kb_seeds;
ALTER TABLE kb_seeds_new RENAME TO kb_seeds;
CREATE INDEX IF NOT EXISTS idx_kb_seeds_org ON kb_seeds (org_id);

-- 6. kb_sources / kb_chunks_meta: split memo rows out into the new
--    memo_sources / memo_chunks_meta tables. Knowledge rows lose the
--    `scope` and `user_id` columns; memo rows gain a NOT NULL org_id
--    (from the row's user.org_id) plus user_id.
--
--    The vec0 virtual tables are unchanged on disk — kb_vec_knowledge
--    keeps rowids 1:1 with kb_chunks_meta.id; kb_vec_memo keeps rowids
--    1:1 with memo_chunks_meta.id (we preserve the chunk-meta ids via
--    explicit INSERT … SELECT id … so vector lookups don't break).

CREATE TABLE kb_sources_new (
  id           INTEGER PRIMARY KEY,
  org_id       TEXT NOT NULL,
  source_kind  TEXT NOT NULL,
  source_ref   TEXT NOT NULL,
  title        TEXT,
  raw_text     TEXT,
  centroid     BLOB,
  tags         TEXT,
  indexed_at   INTEGER NOT NULL,
  UNIQUE(org_id, source_ref)
);
INSERT INTO kb_sources_new (id, org_id, source_kind, source_ref, title,
                            raw_text, centroid, tags, indexed_at)
  SELECT id, 'default', source_kind, source_ref, title,
         raw_text, centroid, tags, indexed_at
  FROM kb_sources WHERE scope = 'knowledge';

CREATE TABLE memo_sources (
  id           INTEGER PRIMARY KEY,
  org_id       TEXT NOT NULL,
  user_id      TEXT NOT NULL,
  source_kind  TEXT NOT NULL,
  source_ref   TEXT NOT NULL,
  title        TEXT,
  raw_text     TEXT,
  centroid     BLOB,
  tags         TEXT,
  indexed_at   INTEGER NOT NULL,
  UNIQUE(user_id, source_ref)
);
INSERT INTO memo_sources (id, org_id, user_id, source_kind, source_ref,
                          title, raw_text, centroid, tags, indexed_at)
  SELECT s.id,
         COALESCE(u.org_id, 'default') AS org_id,
         s.user_id, s.source_kind, s.source_ref,
         s.title, s.raw_text, s.centroid, s.tags, s.indexed_at
  FROM kb_sources s
  LEFT JOIN users u ON u.id = s.user_id
  WHERE s.scope = 'memo';

CREATE TABLE kb_chunks_meta_new (
  id           INTEGER PRIMARY KEY,
  org_id       TEXT NOT NULL,
  source_id    INTEGER NOT NULL REFERENCES kb_sources_new(id) ON DELETE CASCADE,
  chunk_idx    INTEGER NOT NULL,
  chunk_text   TEXT NOT NULL,
  indexed_at   INTEGER NOT NULL
);
INSERT INTO kb_chunks_meta_new (id, org_id, source_id, chunk_idx, chunk_text, indexed_at)
  SELECT id, 'default', source_id, chunk_idx, chunk_text, indexed_at
  FROM kb_chunks_meta WHERE scope = 'knowledge';

CREATE TABLE memo_chunks_meta (
  id           INTEGER PRIMARY KEY,
  org_id       TEXT NOT NULL,
  user_id      TEXT NOT NULL,
  source_id    INTEGER NOT NULL REFERENCES memo_sources(id) ON DELETE CASCADE,
  chunk_idx    INTEGER NOT NULL,
  chunk_text   TEXT NOT NULL,
  indexed_at   INTEGER NOT NULL
);
INSERT INTO memo_chunks_meta (id, org_id, user_id, source_id, chunk_idx, chunk_text, indexed_at)
  SELECT cm.id,
         COALESCE(u.org_id, 'default') AS org_id,
         cm.user_id, cm.source_id, cm.chunk_idx, cm.chunk_text, cm.indexed_at
  FROM kb_chunks_meta cm
  LEFT JOIN users u ON u.id = cm.user_id
  WHERE cm.scope = 'memo';

DROP TABLE kb_chunks_meta;
ALTER TABLE kb_chunks_meta_new RENAME TO kb_chunks_meta;
CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_source ON kb_chunks_meta (source_id);
CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_org    ON kb_chunks_meta (org_id);

DROP TABLE kb_sources;
ALTER TABLE kb_sources_new RENAME TO kb_sources;
CREATE INDEX IF NOT EXISTS idx_kb_sources_org ON kb_sources (org_id);

CREATE INDEX IF NOT EXISTS idx_memo_sources_user      ON memo_sources (user_id);
CREATE INDEX IF NOT EXISTS idx_memo_sources_org       ON memo_sources (org_id);
CREATE INDEX IF NOT EXISTS idx_memo_chunks_meta_source ON memo_chunks_meta (source_id);
CREATE INDEX IF NOT EXISTS idx_memo_chunks_meta_user   ON memo_chunks_meta (user_id);

-- 7. memo_fts FTS5 index (mirrors kb_fts for the memo half).
CREATE VIRTUAL TABLE IF NOT EXISTS memo_fts USING fts5(
  chunk_text,
  content='',
  contentless_delete=1,
  tokenize='unicode61 remove_diacritics 2'
);

-- Re-populate memo_fts from the migrated memo_chunks_meta rows. kb_fts
-- has memo rows mixed in from the pre-split era; the simplest cleanup
-- is to wipe both FTS indexes and re-index from the split tables.
DELETE FROM kb_fts;
INSERT INTO kb_fts(rowid, chunk_text)
  SELECT id, chunk_text FROM kb_chunks_meta;
INSERT INTO memo_fts(rowid, chunk_text)
  SELECT id, chunk_text FROM memo_chunks_meta;

-- 8. audit_log table (Primitive 0.7 / cross-cutting).
CREATE TABLE IF NOT EXISTS audit_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id        TEXT NOT NULL,
  user_id       TEXT,
  action        TEXT NOT NULL,
  resource      TEXT NOT NULL,
  outcome       TEXT NOT NULL,
  reason        TEXT,
  created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_org_ts  ON audit_log (org_id, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_log_user_ts ON audit_log (user_id, created_at);

COMMIT;

-- Verification queries (run manually after COMMIT):
--   SELECT COUNT(*) FROM organizations;          -- expect ≥ 1
--   SELECT COUNT(*) FROM users WHERE org_id IS NULL;          -- expect 0
--   SELECT COUNT(*) FROM pools WHERE org_id IS NULL;          -- expect 0
--   SELECT COUNT(*) FROM kb_sources WHERE org_id IS NULL;     -- expect 0
--   SELECT COUNT(*) FROM memo_sources WHERE org_id IS NULL OR user_id IS NULL;  -- expect 0
