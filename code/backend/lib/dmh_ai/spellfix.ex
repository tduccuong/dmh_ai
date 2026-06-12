# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.SpellFix do
  @moduledoc """
  The compiled `spellfix1` SQLite extension (typo-tolerant matching) plus
  per-store typo-repair helpers. The `.so` is built in the Docker builder
  (musl) by the Makefile and bundled into the release; `path/0` resolves it
  for `load_extensions`. Each KB store (facts/memos) owns a `<prefix>_spellfix`
  vocab table rebuilt lazily from `<prefix>_fts_vocab`.
  """
  require Logger

  @spec path() :: String.t()
  def path, do: Application.app_dir(:dmh_ai, "priv/spellfix1.so")

  @doc "Rebuild a store's spellfix vocabulary from its FTS term list."
  @spec rebuild(module(), String.t()) :: :ok | :error
  def rebuild(repo, prefix) do
    repo.query!("DELETE FROM #{prefix}_spellfix", [])
    repo.query!(
      "INSERT INTO #{prefix}_spellfix(word) SELECT DISTINCT term FROM #{prefix}_fts_vocab",
      []
    )
    :ok
  rescue
    e ->
      Logger.warning("[SpellFix] rebuild #{prefix} failed: #{Exception.message(e)}")
      :error
  end

  @doc """
  Repair a free-text query token-by-token against a store's spellfix vocab.
  Returns the (possibly corrected) query, or the original on any error.
  """
  @spec repair_query(module(), String.t(), String.t()) :: String.t()
  def repair_query(repo, prefix, query_text) when is_binary(query_text) do
    ensure_vocab(repo, prefix)
    max = DmhAi.Agent.AgentSettings.kb_spellfix_max_distance()

    {tokens, changed?} =
      query_text
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.map_reduce(false, fn tok, acc ->
        case repair_term(repo, prefix, tok, max) do
          nil -> {tok, acc}
          word -> {word, acc or word != tok}
        end
      end)

    if changed?, do: Enum.join(tokens, " "), else: query_text
  rescue
    _ -> query_text
  end

  defp ensure_vocab(repo, prefix) do
    case repo.query!("SELECT 1 FROM #{prefix}_spellfix LIMIT 1", []).rows do
      [] -> rebuild(repo, prefix)
      _ -> :ok
    end
  rescue
    _ -> :error
  end

  defp repair_term(repo, prefix, term, max) do
    case repo.query!(
           "SELECT word, distance FROM #{prefix}_spellfix WHERE word MATCH ? AND top=1",
           [term]
         ).rows do
      [[word, dist]] when is_integer(dist) and dist <= max -> word
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
