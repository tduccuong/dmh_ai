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

# HTTP/HTTPS bind interface — defaults to loopback so a fresh install
# behind nginx (or just `localhost` on a personal machine) is private
# by default. Set `DMHAI_BIND_HOST=0.0.0.0` to expose on every NIC —
# required for the README's "phone on same Wi-Fi" LAN-access feature.
# Any other valid IP literal (`192.168.1.42`, `::1`) also works.
config :dmh_ai, bind_host: System.get_env("DMHAI_BIND_HOST", "127.0.0.1")
