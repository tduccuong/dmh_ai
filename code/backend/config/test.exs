import Config

# Use a per-run temp DB so tests are isolated from production data.
# Pass DB_PATH=~/.dmhai/db/chat.db to use the live production DB, which is
# required for real-LLM integration tests that need credential access.
db_path = System.get_env("DB_PATH", "/tmp/dmhai_test_#{:os.getpid()}.db")

config :dmhai, Dmhai.Repo,
  database: db_path,
  pool_size: 1

# Write test syslogs to a temp file instead of the production path.
config :dmhai, :syslog_path, "/tmp/dmhai_test_syslog.log"

# Silence most log noise during test runs.
config :logger, level: :warning

# Signal to the application supervisor that HTTPS should not be started
# (no SSL cert exists in the test environment).
config :dmhai, :start_https, false
config :dmhai, :start_http,  false
config :dmhai, :enable_task_rehydrate, false
config :dmhai, :run_startup_check,   false
# Tight poll cadence so TaskRuntime tests finish in seconds rather than tens of seconds.
config :dmhai, :task_poll_override_ms, 100
