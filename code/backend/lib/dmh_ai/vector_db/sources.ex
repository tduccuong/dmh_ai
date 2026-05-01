# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.Sources do
  @moduledoc """
  CRUD over `kb_sources` — the registry of every ingest. Keeps the
  raw text, centroid embedding (for inline-text semantic merge), and
  free-form tags. See specs/vector_kb.md.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Insert or replace a source registry row. `attrs` keys: `:scope`,
  `:user_id` (nil for `:knowledge`), `:source_kind`, `:source_ref`,
  `:title`, `:tags` (list of strings), `:centroid` (list of floats or
  nil). `body` is the raw text. Returns `{:ok, source_id}`.
  """
  @spec upsert(map(), String.t()) :: {:ok, integer()}
  def upsert(attrs, body) when is_binary(body) do
    now = System.os_time(:millisecond)
    scope_str = scope_to_string(attrs.scope)
    centroid_blob = encode_centroid(attrs[:centroid])
    tags_json = Jason.encode!(attrs[:tags] || [])

    case attrs[:user_id] do
      nil ->
        query!(Repo, """
        DELETE FROM kb_sources WHERE scope=? AND user_id IS NULL AND source_ref=?
        """, [scope_str, attrs.source_ref])

      uid ->
        query!(Repo, """
        DELETE FROM kb_sources WHERE scope=? AND user_id=? AND source_ref=?
        """, [scope_str, uid, attrs.source_ref])
    end

    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO kb_sources (scope, user_id, source_kind, source_ref, title,
                              raw_text, centroid, tags, indexed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      RETURNING id
      """, [
        scope_str,
        attrs[:user_id],
        attrs.source_kind,
        attrs.source_ref,
        attrs[:title],
        body,
        centroid_blob,
        tags_json,
        now
      ])

    {:ok, id}
  end

  @doc """
  Fetch nearest source by centroid cosine within (scope, user_id),
  excluding sources of the given `source_ref` (so a refresh on the
  same ref doesn't match itself). Returns `{:ok, source_map}` or
  `:no_match` when below `threshold` or empty.

  Used by inline-text `/wiki` to merge near-duplicates into a single
  `source_ref` instead of fragmenting.
  """
  @spec nearest_centroid(:knowledge | :memo, String.t() | nil, [float()], float()) ::
          {:ok, map()} | :no_match
  def nearest_centroid(scope, user_id, centroid, threshold) when is_list(centroid) do
    {sql, args} =
      case user_id do
        nil ->
          {"""
           SELECT id, source_ref, centroid, tags, title FROM kb_sources
           WHERE scope=? AND user_id IS NULL AND source_kind='text' AND centroid IS NOT NULL
           """, [scope_to_string(scope)]}

        uid ->
          {"""
           SELECT id, source_ref, centroid, tags, title FROM kb_sources
           WHERE scope=? AND user_id=? AND source_kind='text' AND centroid IS NOT NULL
           """, [scope_to_string(scope), uid]}
      end

    rows = query!(Repo, sql, args).rows
    q_norm = norm(centroid)

    rows
    |> Enum.map(fn [id, source_ref, blob, tags_json, title] ->
      vec = decode_centroid(blob)
      score = cosine(centroid, vec, q_norm)
      %{id: id, source_ref: source_ref, score: score, tags: decode_tags(tags_json), title: title}
    end)
    |> Enum.filter(&(&1.score >= threshold))
    |> Enum.sort_by(& &1.score, :desc)
    |> List.first()
    |> case do
      nil -> :no_match
      best -> {:ok, best}
    end
  end

  @doc "Fetch by id."
  @spec get(integer()) :: {:ok, map()} | :not_found
  def get(id) when is_integer(id) do
    case query!(Repo, """
    SELECT id, scope, user_id, source_kind, source_ref, title, raw_text, centroid, tags, indexed_at
    FROM kb_sources WHERE id=?
    """, [id]).rows do
      [row] -> {:ok, row_to_map(row)}
      _     -> :not_found
    end
  end

  @doc "Fetch every source for a scope; raw_text included for relearn flows."
  @spec list(:knowledge | :memo, String.t() | nil) :: [map()]
  def list(scope, user_id \\ nil) do
    {sql, args} =
      case {scope, user_id} do
        {:knowledge, _} ->
          {"SELECT id, scope, user_id, source_kind, source_ref, title, raw_text, centroid, tags, indexed_at FROM kb_sources WHERE scope='knowledge' ORDER BY id ASC",
           []}

        {:memo, nil} ->
          {"SELECT id, scope, user_id, source_kind, source_ref, title, raw_text, centroid, tags, indexed_at FROM kb_sources WHERE scope='memo' ORDER BY id ASC",
           []}

        {:memo, uid} ->
          {"SELECT id, scope, user_id, source_kind, source_ref, title, raw_text, centroid, tags, indexed_at FROM kb_sources WHERE scope='memo' AND user_id=? ORDER BY id ASC",
           [uid]}
      end

    query!(Repo, sql, args).rows |> Enum.map(&row_to_map/1)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp scope_to_string(:knowledge), do: "knowledge"
  defp scope_to_string(:memo),      do: "memo"

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

  defp row_to_map([id, scope, user_id, source_kind, source_ref, title, raw_text, centroid_blob, tags_json, indexed_at]) do
    %{
      id: id,
      scope: String.to_existing_atom(scope),
      user_id: user_id,
      source_kind: source_kind,
      source_ref: source_ref,
      title: title,
      raw_text: raw_text,
      centroid: decode_centroid(centroid_blob),
      tags: decode_tags(tags_json),
      indexed_at: indexed_at
    }
  end
end
