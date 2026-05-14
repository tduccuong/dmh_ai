-- 0002_ingest_pipeline.sql — Primitive 0.2 schema migration.
--
-- One-off operator-run migration. Apply via:
--
--     sqlite3 /data/db/chat.db < 0002_ingest_pipeline.sql
--
-- Idempotent: every statement is either `IF NOT EXISTS`, a guarded
-- table-copy, or uses `OR IGNORE`. Re-runs are no-ops.

BEGIN TRANSACTION;

-- Copy kb_sources into the new shape:
--   * source_ref → source_id (already the natural key; same value)
--   * adds content_sha256, extracted_text_sha256, chunker_config_version,
--     embedder_model, parent_source_id, last_seen_at, last_indexed_at,
--     last_check_at, last_check_failed_at, last_check_error,
--     created_by_user_id, ingest_status
--   * UNIQUE moves from (org_id, source_ref) to (org_id, source_id)
--   * last_indexed_at backfilled from existing indexed_at; last_seen_at
--     same. content_sha256 stays NULL on backfilled rows — the next
--     re-ingest will fill it. (No way to recompute without re-fetching
--     the upstream bytes, which migration doesn't do.)
CREATE TABLE kb_sources_new (
  id                     INTEGER PRIMARY KEY,
  org_id                 TEXT NOT NULL,
  source_id              TEXT NOT NULL,
  source_kind            TEXT NOT NULL,
  title                  TEXT,
  raw_text               TEXT,
  centroid               BLOB,
  tags                   TEXT,
  content_sha256         TEXT,
  extracted_text_sha256  TEXT,
  chunker_config_version TEXT,
  embedder_model         TEXT,
  parent_source_id       TEXT,
  last_seen_at           INTEGER,
  last_indexed_at        INTEGER,
  last_check_at          INTEGER,
  last_check_failed_at   INTEGER,
  last_check_error       TEXT,
  created_by_user_id     TEXT,
  ingest_status          TEXT NOT NULL DEFAULT 'indexed',
  indexed_at             INTEGER NOT NULL,
  UNIQUE(org_id, source_id)
);

INSERT INTO kb_sources_new (id, org_id, source_id, source_kind,
                            title, raw_text, centroid, tags,
                            last_seen_at, last_indexed_at,
                            ingest_status, indexed_at)
  SELECT id, org_id, source_ref, source_kind,
         title, raw_text, centroid, tags,
         indexed_at, indexed_at,
         'indexed', indexed_at
  FROM kb_sources;

DROP TABLE kb_sources;
ALTER TABLE kb_sources_new RENAME TO kb_sources;
CREATE INDEX IF NOT EXISTS idx_kb_sources_org    ON kb_sources (org_id);
CREATE INDEX IF NOT EXISTS idx_kb_sources_parent ON kb_sources (parent_source_id);

CREATE TABLE IF NOT EXISTS kb_source_history (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id              TEXT NOT NULL,
  source_id           TEXT NOT NULL,
  source_kind         TEXT NOT NULL,
  removed_by_user_id  TEXT,
  reason              TEXT,
  removed_at          INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_kb_source_history_org ON kb_source_history (org_id, removed_at);

-- Rename memo_sources.source_ref → source_id for symmetry with the
-- KB side. Memo's natural key is sha256(text); same shape, different
-- column name.
CREATE TABLE memo_sources_new (
  id           INTEGER PRIMARY KEY,
  org_id       TEXT NOT NULL,
  user_id      TEXT NOT NULL,
  source_kind  TEXT NOT NULL,
  source_id    TEXT NOT NULL,
  title        TEXT,
  raw_text     TEXT,
  centroid     BLOB,
  tags         TEXT,
  indexed_at   INTEGER NOT NULL,
  UNIQUE(user_id, source_id)
);
INSERT INTO memo_sources_new (id, org_id, user_id, source_kind,
                              source_id, title, raw_text, centroid, tags, indexed_at)
  SELECT id, org_id, user_id, source_kind,
         source_ref, title, raw_text, centroid, tags, indexed_at
  FROM memo_sources;
DROP TABLE memo_sources;
ALTER TABLE memo_sources_new RENAME TO memo_sources;
CREATE INDEX IF NOT EXISTS idx_memo_sources_user ON memo_sources (user_id);
CREATE INDEX IF NOT EXISTS idx_memo_sources_org  ON memo_sources (org_id);

COMMIT;

-- Verification:
--   PRAGMA table_info(kb_sources);    -- new columns present
--   SELECT COUNT(*) FROM kb_sources WHERE source_id IS NULL OR source_id = '';   -- expect 0
