# One-off DB migration scripts

These scripts are NOT run automatically. The application never auto-
migrates the schema on boot — operators apply each script manually
against the live SQLite database after deploying the new code.

## Usage

```bash
sqlite3 /data/db/chat.db < priv/migrate/<script>.sql
```

Apply scripts in chronological order (the filename prefix is the
target year). Every script is written to be idempotent so re-running
is safe.

## Inventory

- `2026_drop_task_tables.sql` — demolishes the task subsystem
  (`tasks`, `task_chain_archive`, `worker_token_stats`,
  `task_services` → `session_services`), strips `anchor_task_id` from
  `pending_oauth_states`, drops `task_id` from `session_progress`, and
  adds `sessions.cancelled_at` + `sessions.compaction_summary`.
