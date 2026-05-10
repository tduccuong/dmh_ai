# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Constants do
  # Web search pipeline
  @search_page2_threshold 5
  @max_page_chars 6000
  @min_useful_page_chars 500
  @direct_fetch_size_bytes 120_000
  @jina_fetch_size_bytes 200_000

  # Network timeouts (milliseconds for Req)
  @ollama_api_timeout_ms 10_000
  @endpoint_test_timeout_ms 5_000
  @registry_timeout_ms 10_000
  @searxng_timeout_ms 20_000
  @direct_fetch_timeout_ms 6_000
  @jina_timeout_ms 7_000

  # Domain blocking
  @domain_timeout_block_threshold 3

  # Password hashing
  @password_hash_iterations 100_000

  # Paths. Resolved at call time via `Application.get_env(:dmh_ai,
  # :paths, %{})` with the production defaults below as fallback. The
  # sandbox-runtime test tier (`mix test.sandbox`) overrides these to
  # point at a throwaway tmp dir so each integration test gets an
  # isolated filesystem. Production runs never set the env var, so
  # `path/2` returns the literal default.
  @default_db_path        "/data/db/chat.db"
  @default_assets_dir     "/data/user_assets"
  # Per-user workspaces tree (model scratch). Sibling of user_assets,
  # split out as part of the per-user permission redesign — see
  # specs/permissions.md. user_assets is RO from the sandbox;
  # user_workspaces is the only writable bind mount.
  @default_workspaces_dir "/data/user_workspaces"
  @default_log_file       "/data/system_logs/system.log"

  defp path(key, default),
    do: Application.get_env(:dmh_ai, :paths, %{}) |> Map.get(key, default)

  def search_page2_threshold, do: @search_page2_threshold
  def max_page_chars, do: @max_page_chars
  def min_useful_page_chars, do: @min_useful_page_chars
  def direct_fetch_size_bytes, do: @direct_fetch_size_bytes
  def jina_fetch_size_bytes, do: @jina_fetch_size_bytes
  def ollama_api_timeout_ms, do: @ollama_api_timeout_ms
  def endpoint_test_timeout_ms, do: @endpoint_test_timeout_ms
  def registry_timeout_ms, do: @registry_timeout_ms
  def searxng_timeout_ms, do: @searxng_timeout_ms
  def direct_fetch_timeout_ms, do: @direct_fetch_timeout_ms
  def jina_timeout_ms, do: @jina_timeout_ms
  def domain_timeout_block_threshold, do: @domain_timeout_block_threshold
  def password_hash_iterations, do: @password_hash_iterations
  def db_path,        do: path(:db_path,        @default_db_path)
  def assets_dir,     do: path(:assets_dir,     @default_assets_dir)
  def workspaces_dir, do: path(:workspaces_dir, @default_workspaces_dir)
  def log_file,       do: path(:log_file,       @default_log_file)

  def image_exts, do: ~w(.png .jpg .jpeg .gif .webp .bmp)

  # ── Filesystem layout for user assets + workspaces ──────────────────────
  #
  #   /data/user_assets/<email>/                  (RO from sandbox)
  #     ├── _keystore/                            ← per-user secrets (sibling of sessions)
  #     └── <session_id>/
  #         └── data/                             ← user uploads
  #
  #   /data/user_workspaces/<email>/              (RW from sandbox)
  #     └── <session_id>/                         ← assistant task outputs
  #
  # Two trees; one bind-mount each into the sandbox. Per-session split as
  # before — data/ is uploads, workspace files live one tree over.
  # Confidant sessions don't write workspaces (Confidant is sync, no tasks).
  # Full design: specs/permissions.md.

  @doc """
  Make a filesystem-safe slug (alphanumerics, dash, underscore only).
  Used for session_id / task_id / any untrusted path segment.
  Emails are intentionally NOT sanitised via this — they're used as-is
  (preserves `@` and `.` so paths remain human-recognisable).
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(v) when is_binary(v), do: Regex.replace(~r/[^\w\-]/, v, "_")
  def sanitize(v), do: sanitize(to_string(v))

  @doc "Root directory for a user's session (all uploads + task workspaces live under this)."
  @spec session_root(String.t(), String.t()) :: String.t()
  def session_root(email, session_id) do
    Path.join([assets_dir(), to_string(email), sanitize(session_id)])
  end

  @doc "User-upload directory for a session."
  @spec session_data_dir(String.t(), String.t()) :: String.t()
  def session_data_dir(email, session_id) do
    Path.join(session_root(email, session_id), "data")
  end

  @doc """
  Workspace directory for a session — shared across all tasks in the
  session. Lives under `@workspaces_dir`, NOT under `@assets_dir`, so
  the sandbox can mount workspaces RW while keeping assets RO. See
  specs/permissions.md.
  """
  @spec session_workspace_dir(String.t(), String.t()) :: String.t()
  def session_workspace_dir(email, session_id) do
    Path.join([workspaces_dir(), to_string(email), sanitize(session_id)])
  end

  @doc """
  Per-user keystore directory — a sibling of the per-session roots, never
  inside any session. Long-lived material that must outlive session
  deletion (e.g., harness-generated SSH identities) lives here. The leading
  underscore signals "not a session" so listings are unambiguous.
  """
  @spec user_keystore_dir(String.t()) :: String.t()
  def user_keystore_dir(email) do
    Path.join([assets_dir(), to_string(email), "_keystore"])
  end
end
