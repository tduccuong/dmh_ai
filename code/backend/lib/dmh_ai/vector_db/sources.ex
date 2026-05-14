# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.Sources do
  @moduledoc """
  CRUD over the two parallel source registries per Primitive 0.1:

    * `kb_sources` — org-scoped (KB; every employee in the org reads
      the same corpus). Functions: `upsert_kb/2`, `list_kb/1`,
      `get_kb/1`, `nearest_centroid_kb/3`.

    * `memo_sources` — per-user (encrypted scratchpad; carries
      `org_id` as audit context but is read only by the owner).
      Functions: `upsert_memo/2`, `list_memo/1`, `get_memo/1`,
      `nearest_centroid_memo/3`.

  See specs/vector_kb.md and arch_wiki/dmh_ai/sme/layer-0.md §0.1.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # ─── KB (org-scoped) ──────────────────────────────────────────────────────

  @doc """
  Insert a KB source row. `attrs` keys (Primitive 0.2 shape):
  `:org_id`, `:source_kind`, `:source_id` (normalised stable key),
  `:title`, `:tags`, `:centroid`, `:content_sha256`,
  `:extracted_text_sha256`, `:created_by_user_id`, `:last_seen_at`,
  `:last_indexed_at`. The caller (typically `DmhAi.Ingest`) is
  responsible for the idempotence / freshness gate; this function
  just persists the row.
  """
  @spec upsert_kb(map(), String.t()) :: {:ok, integer()}
  def upsert_kb(attrs, body) when is_binary(body) do
    now = System.os_time(:millisecond)
    centroid_blob = encode_centroid(attrs[:centroid])
    tags_json = Jason.encode!(attrs[:tags] || [])
    org_id = require_field!(attrs, :org_id)
    source_id = require_field!(attrs, :source_id)

    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO kb_sources
        (org_id, source_id, source_kind, title,
         raw_text, centroid, tags,
         content_sha256, extracted_text_sha256,
         created_by_user_id, parent_source_id,
         last_seen_at, last_indexed_at,
         ingest_status, indexed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'indexed', ?)
      RETURNING id
      """, [
        org_id,
        source_id,
        attrs.source_kind,
        attrs[:title],
        body,
        centroid_blob,
        tags_json,
        attrs[:content_sha256],
        attrs[:extracted_text_sha256],
        attrs[:created_by_user_id],
        attrs[:parent_source_id],
        attrs[:last_seen_at] || now,
        attrs[:last_indexed_at] || now,
        now
      ])

    {:ok, id}
  end

  @doc """
  Fetch nearest KB source by centroid cosine within `org_id`, returning
  `{:ok, source_map}` or `:no_match` when below `threshold` or empty.
  Used by inline-text `/index` to merge near-duplicates.
  """
  @spec nearest_centroid_kb(String.t(), [float()], float()) ::
          {:ok, map()} | :no_match
  def nearest_centroid_kb(org_id, centroid, threshold)
      when is_binary(org_id) and is_list(centroid) do
    rows =
      query!(Repo, """
      SELECT id, source_id, centroid, tags, title FROM kb_sources
      WHERE org_id=? AND source_kind='text' AND centroid IS NOT NULL
      """, [org_id]).rows

    nearest_from_rows(rows, centroid, threshold)
  end

  @doc "Fetch a KB source by id."
  @spec get_kb(integer()) :: {:ok, map()} | :not_found
  def get_kb(id) when is_integer(id) do
    case query!(Repo, """
    SELECT id, org_id, source_kind, source_id, title, raw_text, centroid, tags, indexed_at
    FROM kb_sources WHERE id=?
    """, [id]).rows do
      [row] -> {:ok, kb_row_to_map(row)}
      _     -> :not_found
    end
  end

  @doc "Fetch every KB source for an org; raw_text included for relearn flows."
  @spec list_kb(String.t()) :: [map()]
  def list_kb(org_id) when is_binary(org_id) do
    query!(Repo, """
    SELECT id, org_id, source_kind, source_id, title, raw_text, centroid, tags, indexed_at
    FROM kb_sources WHERE org_id=? ORDER BY id ASC
    """, [org_id]).rows
    |> Enum.map(&kb_row_to_map/1)
  end

  # ─── Memo (per-user, org_id is audit context) ─────────────────────────────

  @doc """
  Insert or replace a memo source row. `attrs` keys: `:org_id`,
  `:user_id`, `:source_kind`, `:source_id`, `:title`, `:tags`,
  `:centroid`. `body` is the raw (encrypted) memo text. Returns
  `{:ok, source_id}`.
  """
  @spec upsert_memo(map(), String.t()) :: {:ok, integer()}
  def upsert_memo(attrs, body) when is_binary(body) do
    now = System.os_time(:millisecond)
    centroid_blob = encode_centroid(attrs[:centroid])
    tags_json = Jason.encode!(attrs[:tags] || [])
    org_id    = require_field!(attrs, :org_id)
    user_id   = require_field!(attrs, :user_id)
    source_id = require_field!(attrs, :source_id)

    query!(Repo, """
    DELETE FROM memo_sources WHERE user_id=? AND source_id=?
    """, [user_id, source_id])

    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO memo_sources (org_id, user_id, source_kind, source_id, title,
                                raw_text, centroid, tags, indexed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      RETURNING id
      """, [
        org_id,
        user_id,
        attrs.source_kind,
        source_id,
        attrs[:title],
        body,
        centroid_blob,
        tags_json,
        now
      ])

    {:ok, id}
  end

  @doc """
  Fetch nearest memo source for `user_id` by centroid cosine. Returns
  `{:ok, source_map}` or `:no_match`. Memos are per-user, so org
  scoping is implicit via the user.
  """
  @spec nearest_centroid_memo(String.t(), [float()], float()) ::
          {:ok, map()} | :no_match
  def nearest_centroid_memo(user_id, centroid, threshold)
      when is_binary(user_id) and is_list(centroid) do
    rows =
      query!(Repo, """
      SELECT id, source_id, centroid, tags, title FROM memo_sources
      WHERE user_id=? AND source_kind='text' AND centroid IS NOT NULL
      """, [user_id]).rows

    nearest_from_rows(rows, centroid, threshold)
  end

  @doc "Fetch a memo source by id."
  @spec get_memo(integer()) :: {:ok, map()} | :not_found
  def get_memo(id) when is_integer(id) do
    case query!(Repo, """
    SELECT id, org_id, user_id, source_kind, source_id, title, raw_text, centroid, tags, indexed_at
    FROM memo_sources WHERE id=?
    """, [id]).rows do
      [row] -> {:ok, memo_row_to_map(row)}
      _     -> :not_found
    end
  end

  @doc "Fetch every memo source for a user; raw_text included for export flows."
  @spec list_memo(String.t()) :: [map()]
  def list_memo(user_id) when is_binary(user_id) do
    query!(Repo, """
    SELECT id, org_id, user_id, source_kind, source_id, title, raw_text, centroid, tags, indexed_at
    FROM memo_sources WHERE user_id=? ORDER BY id ASC
    """, [user_id]).rows
    |> Enum.map(&memo_row_to_map/1)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp require_field!(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and v != "" -> v
      _ -> raise ArgumentError, "Sources upsert requires #{inspect(key)}"
    end
  end

  defp nearest_from_rows(rows, centroid, threshold) do
    q_norm = norm(centroid)

    rows
    |> Enum.map(fn [id, source_id, blob, tags_json, title] ->
      vec = decode_centroid(blob)
      score = cosine(centroid, vec, q_norm)
      %{id: id, source_id: source_id, score: score, tags: decode_tags(tags_json), title: title}
    end)
    |> Enum.filter(&(&1.score >= threshold))
    |> Enum.sort_by(& &1.score, :desc)
    |> List.first()
    |> case do
      nil  -> :no_match
      best -> {:ok, best}
    end
  end

  defp encode_centroid(nil), do: nil
  defp encode_centroid(list) when is_list(list) do
    list
    |> Enum.map(fn f -> <<to_float(f)::float-32-little>> end)
    |> IO.iodata_to_binary()
  end

  defp decode_centroid(nil), do: []
  defp decode_centroid(blob) when is_binary(blob) do
    for <<x::float-32-little <- blob>>, do: x
  end

  defp decode_tags(nil), do: []
  defp decode_tags(""),  do: []
  defp decode_tags(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp to_float(f) when is_float(f), do: f
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp norm(list), do: list |> Enum.reduce(0.0, fn x, acc -> acc + x * x end) |> :math.sqrt()

  defp cosine(a, b, a_norm) do
    {dot, b_sq} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0}, fn {x, y}, {d, bs} -> {d + x * y, bs + y * y} end)

    b_norm = :math.sqrt(b_sq)
    if a_norm == 0.0 or b_norm == 0.0, do: 0.0, else: dot / (a_norm * b_norm)
  end

  defp kb_row_to_map([id, org_id, source_kind, source_id, title, raw_text, centroid_blob, tags_json, indexed_at]) do
    %{
      id: id,
      org_id: org_id,
      source_kind: source_kind,
      source_id: source_id,
      title: title,
      raw_text: raw_text,
      centroid: decode_centroid(centroid_blob),
      tags: decode_tags(tags_json),
      indexed_at: indexed_at
    }
  end

  defp memo_row_to_map([id, org_id, user_id, source_kind, source_id, title, raw_text, centroid_blob, tags_json, indexed_at]) do
    %{
      id: id,
      org_id: org_id,
      user_id: user_id,
      source_kind: source_kind,
      source_id: source_id,
      title: title,
      raw_text: raw_text,
      centroid: decode_centroid(centroid_blob),
      tags: decode_tags(tags_json),
      indexed_at: indexed_at
    }
  end
end
