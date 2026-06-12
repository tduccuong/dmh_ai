# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Kb.Schema do
  @moduledoc """
  Creates one user-memory store's tables in its own SQLite DB: a plaintext
  `<prefix>_sources` row table (one atomic fact / one memo per row), the FTS5
  lexical + trigram indices, the spellfix1 vocab, and the vec0 embedding table.
  rowids in `<prefix>_fts*` / `<prefix>_vec` mirror `<prefix>_sources.id`.
  `prefix` is a fixed internal label ("facts" / "memos"), never user input.
  See arch_wiki/dmh_ai/facts_memos.md.
  """

  @embed_dim 1024

  @spec create_all(module(), String.t()) :: :ok
  def create_all(repo, prefix) do
    exec(repo, """
    CREATE TABLE IF NOT EXISTS #{prefix}_sources (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id    TEXT NOT NULL,
      text       TEXT NOT NULL,
      text_sha   TEXT NOT NULL,
      source     TEXT,
      created_at INTEGER NOT NULL,
      UNIQUE(user_id, text_sha)
    )
    """)

    exec(repo, "CREATE INDEX IF NOT EXISTS idx_#{prefix}_sources_user ON #{prefix}_sources(user_id)")

    exec(repo, """
    CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}_fts USING fts5(
      text, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2')
    """)

    exec(repo, """
    CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}_fts_tri USING fts5(
      text, content='', contentless_delete=1, tokenize='trigram')
    """)

    exec(repo, "CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}_fts_vocab USING fts5vocab('#{prefix}_fts', 'row')")
    exec(repo, "CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}_spellfix USING spellfix1")

    exec(repo, """
    CREATE VIRTUAL TABLE IF NOT EXISTS #{prefix}_vec USING vec0(
      embedding float[#{@embed_dim}] distance_metric=cosine)
    """)

    :ok
  end

  defp exec(repo, sql), do: repo.query!(sql, [])
end
