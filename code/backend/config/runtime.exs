import Config

# Allow overriding DB path at runtime via environment variable
db_path = System.get_env("DB_PATH", "/data/db/chat.db")

config :dmhai, Dmhai.Repo,
  database: db_path,
  pool_size: 5
