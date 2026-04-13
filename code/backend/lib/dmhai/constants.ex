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
end
