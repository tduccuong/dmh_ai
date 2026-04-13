import Config

config :dmhai, Dmhai.Repo,
  database: "/data/db/chat.db",
  pool_size: 5

config :dmhai, ecto_repos: [Dmhai.Repo]
