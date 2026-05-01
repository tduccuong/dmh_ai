import Config

# Allow overriding DB path at runtime via environment variable.
# In test mode the path is already set by config/test.exs — skip the override.
if config_env() != :test do
  db_path = System.get_env("DB_PATH", "/data/db/chat.db")

  config :dmh_ai, DmhAi.Repo,
    database: db_path,
    pool_size: 5,
    load_extensions: [SqliteVec.path()]
else
  # Tests still need the extension loaded so vec0 virtual tables work.
  config :dmh_ai, DmhAi.Repo, load_extensions: [SqliteVec.path()]
end
