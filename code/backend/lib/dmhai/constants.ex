# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Constants do
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

  # Paths
  @db_path "/data/db/chat.db"
  @assets_dir "/data/user_assets"
  @log_file "/data/system_logs/system.log"

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
  def db_path, do: @db_path
  def assets_dir, do: @assets_dir
  def log_file, do: @log_file

  def image_exts, do: ~w(.png .jpg .jpeg .gif .webp .bmp)

  # ── Filesystem layout for user assets ────────────────────────────────────
  #
  #   /data/user_assets/<email>/<session_id>/
  #     ├── data/                           ← user uploads
  #     ├── assistant/tasks/<task_id>/      ← worker/resolver scratch (assistant-origin)
  #     └── confidant/tasks/<task_id>/      ← confidant-origin scratch
  #
  # `origin` reflects the session's mode; `pipeline` reflects the execution
  # path (assistant=worker, confidant=resolver). Filesystem is keyed by
  # `origin`, not `pipeline`.

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
    Path.join([@assets_dir, to_string(email), sanitize(session_id)])
  end

  @doc "User-upload directory for a session."
  @spec session_data_dir(String.t(), String.t()) :: String.t()
  def session_data_dir(email, session_id) do
    Path.join(session_root(email, session_id), "data")
  end

  @doc "Root directory for all tasks belonging to a given origin within a session."
  @spec session_origin_root(String.t(), String.t(), String.t()) :: String.t()
  def session_origin_root(email, session_id, origin)
      when origin in ["assistant", "confidant"] do
    Path.join([session_root(email, session_id), origin, "tasks"])
  end

  @doc "Workspace directory for a specific task (worker scratch: web fetches, temp files, etc.)."
  @spec task_workspace_dir(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def task_workspace_dir(email, session_id, origin, task_id)
      when origin in ["assistant", "confidant"] do
    Path.join(session_origin_root(email, session_id, origin), sanitize(task_id))
  end
end
