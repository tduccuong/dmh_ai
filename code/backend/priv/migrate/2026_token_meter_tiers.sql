-- One-off DB migration: extend session_token_stats with per-tier
-- token counters (swift / oracle / vision / embedding) so every LLM
-- call site can be metered, not just the master chain. Run ONCE
-- against the live DB after deploying the new code.
--
-- The ADD COLUMN statements are NOT idempotent — re-running this
-- script will fail once the columns are already present. The
-- migration is one-shot.

ALTER TABLE session_token_stats ADD COLUMN swift_rx_tokens     INTEGER DEFAULT 0;
ALTER TABLE session_token_stats ADD COLUMN swift_tx_tokens     INTEGER DEFAULT 0;
ALTER TABLE session_token_stats ADD COLUMN oracle_rx_tokens    INTEGER DEFAULT 0;
ALTER TABLE session_token_stats ADD COLUMN oracle_tx_tokens    INTEGER DEFAULT 0;
ALTER TABLE session_token_stats ADD COLUMN vision_rx_tokens    INTEGER DEFAULT 0;
ALTER TABLE session_token_stats ADD COLUMN vision_tx_tokens    INTEGER DEFAULT 0;
ALTER TABLE session_token_stats ADD COLUMN embedding_rx_tokens INTEGER DEFAULT 0;
ALTER TABLE session_token_stats ADD COLUMN embedding_tx_tokens INTEGER DEFAULT 0;
