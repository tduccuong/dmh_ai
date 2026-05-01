import Config

# Use a per-run temp DB so tests are isolated from production data.
# Pass DB_PATH=~/.dmh_ai/db/chat.db to use the live production DB, which is
# required for real-LLM integration tests that need credential access.
db_path = System.get_env("DB_PATH", "/tmp/dmh_ai_test_#{:os.getpid()}.db")

config :dmh_ai, DmhAi.Repo,
  database: db_path,
  pool_size: 1

# Write test syslogs to a temp file instead of the production path.
config :dmh_ai, :syslog_path, "/tmp/dmh_ai_test_syslog.log"

# Silence most log noise during test runs.
config :logger, level: :warning

# Signal to the application supervisor that HTTPS should not be started
# (no SSL cert exists in the test environment).
config :dmh_ai, :start_https, false
config :dmh_ai, :start_http,  false
config :dmh_ai, :enable_task_rehydrate, false
config :dmh_ai, :run_startup_check,   false
