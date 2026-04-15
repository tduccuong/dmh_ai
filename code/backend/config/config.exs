import Config

config :logger, level: :debug

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 5]}

config :dmhai, Dmhai.Repo,
  database: "/data/db/chat.db",
  pool_size: 5

config :dmhai, ecto_repos: [Dmhai.Repo]
