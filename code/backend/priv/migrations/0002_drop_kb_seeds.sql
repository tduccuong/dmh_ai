-- Migration 0002 — drop kb_seeds + index_seeds Index-Seeds feature.
--
-- The "Index Seeds" admin feature (curated list of URLs an admin
-- could one-click-/index) was removed in favour of treating
-- deployment seeding as an out-of-band operator concern (scripts in
-- the repo's `demo/` directory, not a primitive in the main
-- codebase). The kb_seeds table no longer has any reader in the BE
-- code.
--
-- Operators upgrading past this commit should run this script once
-- against their stage / production database to drop the table and
-- its index. Fresh installs after this commit will not create
-- kb_seeds at all (the CREATE TABLE statement has been removed from
-- db/init.ex), so this migration is a no-op for them.
--
-- Run from a host shell:
--   docker exec -i dmh_ai-master sqlite3 /data/db/chat.db < 0002_drop_kb_seeds.sql

DROP INDEX IF EXISTS idx_kb_seeds_org;
DROP TABLE  IF EXISTS kb_seeds;
