import Config

config :logger, level: :debug

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 5]}

config :dmhai, Dmhai.Repo,
  database: "/data/db/chat.db",
  pool_size: 5

config :dmhai, ecto_repos: [Dmhai.Repo]

config :dmhai, :worker,
  # Inline-summarise tool results larger than this (chars) using the compactor model.
  summarize_threshold: 5_000,
  # Hard truncation cap applied when summarisation fails.
  max_tool_result_chars: 8_000

# Per-env overrides (test.exs sets an in-memory DB and silences the HTTP servers)
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
