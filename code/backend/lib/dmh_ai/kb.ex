# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Kb do
  @moduledoc """
  Repo-parameterised hybrid retrieval over a single user-memory store
  (facts.db or memos.db). One row = one atomic unit (a fact or a memo),
  stored as PLAINTEXT so the lexical legs work.

  `index/5` writes the row + mirrors it into FTS5 (`<prefix>_fts`), trigram
  (`<prefix>_fts_tri`) and vec0 (`<prefix>_vec`), deduped by `(user_id, sha)`.

  `query/6` runs three lexical legs (bm25 + trigram + spellfix-repaired bm25)
  plus a vector leg, fuses them by Reciprocal Rank Fusion, and returns the
  top-k texts scoped to one user. (No MMR — units are short single facts, so
  RRF dedup is enough.) Mirrors the boxed_flows FTS5+trigram+spellfix+vec0+RRF
  stack. See arch_wiki/dmh_ai/facts_memos.md.
  """

  alias DmhAi.Kb.Embedder
  alias DmhAi.SpellFix
  require Logger

  @rrf_k 60

  # ── Indexing ──────────────────────────────────────────────────────────

  @doc "Index one atomic unit (plaintext). Returns :ok | :dup | :error."
  @spec index(module(), String.t(), String.t(), String.t(), String.t()) :: :ok | :dup | :error
  def index(repo, prefix, user_id, text, source) do
    text = String.trim(text || "")

    cond do
      text == "" ->
        :error

      true ->
        sha = :crypto.hash(:sha256, normalize(text)) |> Base.encode16(case: :lower)
        now = System.os_time(:millisecond)

        case repo.query!(
               "INSERT INTO #{prefix}_sources (user_id, text, text_sha, source, created_at) " <>
                 "VALUES (?,?,?,?,?) ON CONFLICT(user_id, text_sha) DO NOTHING RETURNING id",
               [user_id, text, sha, source, now]
             ).rows do
          [[id]] ->
            repo.query!("INSERT INTO #{prefix}_fts(rowid, text) VALUES (?, ?)", [id, text])
            repo.query!("INSERT INTO #{prefix}_fts_tri(rowid, text) VALUES (?, ?)", [id, text])

            case Embedder.embed(text) do
              {:ok, vec} ->
                repo.query!(
                  "INSERT INTO #{prefix}_vec(rowid, embedding) VALUES (?, CAST(? AS BLOB))",
                  [id, encode_vector(vec)]
                )

              _ ->
                # Vector leg is optional — lexical retrieval still works.
                :ok
            end

            :ok

          _ ->
            :dup
        end
    end
  rescue
    e ->
      Logger.warning("[Kb] index #{prefix} failed: #{Exception.message(e)}")
      :error
  end

  # ── Retrieval ─────────────────────────────────────────────────────────

  @doc """
  Hybrid query scoped to `user_id`. `q_vec` is the precomputed query embedding
  (or nil to skip the vector leg). Returns `[%{id, text, score}]`, top-k.
  """
  @spec query(module(), String.t(), String.t(), String.t(), [float()] | nil, pos_integer()) ::
          [%{id: integer(), text: String.t(), score: float()}]
  def query(repo, prefix, user_id, q, q_vec, k) do
    q = String.trim(q || "")

    if q == "" do
      []
    else
      legs = [
        fts_leg(repo, prefix, "#{prefix}_fts", build_fts_query(q), user_id, k),
        fts_leg(repo, prefix, "#{prefix}_fts_tri", build_trigram_query(q), user_id, k),
        spellfix_leg(repo, prefix, q, user_id, k),
        vector_leg(repo, prefix, q_vec, user_id, k)
      ]

      rrf_merge(legs, k)
    end
  end

  # ── Legs ──────────────────────────────────────────────────────────────

  defp fts_leg(_repo, _prefix, _table, "", _user_id, _k), do: []

  defp fts_leg(repo, prefix, table, match_q, user_id, k) do
    sql = """
    SELECT s.id, s.text
    FROM   #{table}
    JOIN   #{prefix}_sources s ON s.id = #{table}.rowid
    WHERE  #{table} MATCH ? AND s.user_id = ?
    ORDER BY bm25(#{table}) ASC
    LIMIT ?
    """

    repo.query!(sql, [match_q, user_id, k]).rows
    |> Enum.map(fn [id, text] -> %{id: id, text: text} end)
  rescue
    _ -> []
  end

  defp spellfix_leg(repo, prefix, q, user_id, k) do
    case SpellFix.repair_query(repo, prefix, q) do
      ^q -> []
      repaired -> fts_leg(repo, prefix, "#{prefix}_fts", build_fts_query(repaired), user_id, k)
    end
  rescue
    _ -> []
  end

  defp vector_leg(_repo, _prefix, nil, _user_id, _k), do: []

  defp vector_leg(repo, prefix, q_vec, user_id, k) when is_list(q_vec) do
    # KNN returns the globally-nearest rows; over-fetch then filter to the
    # user so a multi-user store still yields k of the user's own units.
    pool = max(k * 5, 50)

    sql = """
    SELECT s.id, s.text
    FROM   #{prefix}_vec v
    JOIN   #{prefix}_sources s ON s.id = v.rowid
    WHERE  v.embedding MATCH CAST(? AS BLOB) AND k = ? AND s.user_id = ?
    ORDER BY v.distance
    LIMIT ?
    """

    repo.query!(sql, [encode_vector(q_vec), pool, user_id, k]).rows
    |> Enum.map(fn [id, text] -> %{id: id, text: text} end)
  rescue
    _ -> []
  end

  # ── Fusion ────────────────────────────────────────────────────────────

  # Reciprocal Rank Fusion: each leg contributes 1/(k + rank) per hit;
  # hits in multiple legs sum. Dedup by source id; take top-k by score.
  defp rrf_merge(legs, k) do
    legs
    |> Enum.flat_map(fn hits ->
      hits |> Enum.with_index(1) |> Enum.map(fn {h, rank} -> {h, 1.0 / (@rrf_k + rank)} end)
    end)
    |> Enum.reduce(%{}, fn {h, rrf}, acc ->
      Map.update(acc, h.id, %{id: h.id, text: h.text, score: rrf}, fn cur ->
        %{cur | score: cur.score + rrf}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(k)
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp normalize(text), do: text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp encode_vector(list) when is_list(list) do
    list |> Enum.map(fn f -> <<to_float(f)::float-32-little>> end) |> IO.iodata_to_binary()
  end

  defp to_float(f) when is_float(f), do: f
  defp to_float(i) when is_integer(i), do: i * 1.0

  # Tokens OR'd as quoted terms for the unicode61 FTS index.
  defp build_fts_query(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(fn tok ->
      cleaned = String.replace(tok, ~r/[^[:alnum:]_-]/u, "")
      if cleaned == "", do: nil, else: ~s("#{cleaned}")
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" OR ")
  end

  # Trigram index matches on substrings; feed the cleaned phrase (≥3 chars).
  defp build_trigram_query(text) do
    cleaned = text |> String.replace(~r/[^[:alnum:][:space:]_-]/u, "") |> String.trim()
    if String.length(cleaned) >= 3, do: ~s("#{cleaned}"), else: ""
  end
end
