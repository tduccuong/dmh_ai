import Config

config :logger, level: :debug

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 5]}

config :dmh_ai, DmhAi.Repo,
  database: "/data/db/chat.db",
  pool_size: 5,
  # Standard SQLite hygiene for multi-writer apps: when the writer
  # slot is briefly held by another process, wait up to 5 s instead
  # of raising SQLITE_BUSY immediately. ecto_sqlite3 documents a
  # 2000ms default but the actual connection pragma was 0 — set
  # explicitly. See arch_wiki/dmh_ai/architecture.md §DB-write
  # hygiene for the SQLite writer slot.
  busy_timeout: 5000

# load_extensions for sqlite-vec is set in runtime.exs because
# `SqliteVec.path/0` isn't loaded until deps are compiled.

config :dmh_ai, ecto_repos: [DmhAi.Repo]

config :dmh_ai, :worker,
  # Inline-summarise tool results larger than this (chars) using the compactor model.
  summarize_threshold: 5_000,
  # Hard truncation cap applied when summarisation fails.
  max_tool_result_chars: 8_000

# Per-env overrides (test.exs sets an in-memory DB and silences the HTTP servers)
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
