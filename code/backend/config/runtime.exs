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

# Vendor MCP mocks (Primitive 0.3 stage demos / UAT). Two flags:
#
#   * `:enable_vendor_mocks` — gates `Mock.VendorMCPServer.start_link/1`
#     itself. Tests set this true in `config/test.exs` so per-test
#     `T.start_mock_vendor/2` works.
#   * `:auto_start_vendor_mocks` — additionally tells the application
#     boot to bring up a mock vendor server per connector that
#     exposes `mock_descriptor/0`. Stage demos set this true via
#     `DMH_AI_ENABLE_VENDOR_MOCKS=true`; tests leave it false so
#     each test owns its random-port mock.
#
# Production installs leave both off. The test env handles its own
# setting in `config/test.exs`; runtime.exs only writes for non-test
# envs so the env-var default doesn't clobber the test config.
if config_env() != :test do
  config :dmh_ai, enable_vendor_mocks:
    System.get_env("DMH_AI_ENABLE_VENDOR_MOCKS", "false") == "true"

  config :dmh_ai, auto_start_vendor_mocks:
    System.get_env("DMH_AI_ENABLE_VENDOR_MOCKS", "false") == "true"

  # Real in-process MCPServer that translates MCP `tools/call` into
  # vendor REST API calls. Off by default — admins opt in by
  # exporting DMH_AI_ENABLE_REAL_MCP=true before install. Port is
  # configurable via DMH_AI_REAL_MCP_PORT (default 8087).
  config :dmh_ai, enable_real_mcp:
    System.get_env("DMH_AI_ENABLE_REAL_MCP", "false") == "true"

  config :dmh_ai, real_mcp_port:
    System.get_env("DMH_AI_REAL_MCP_PORT", "8087") |> String.to_integer()
end
