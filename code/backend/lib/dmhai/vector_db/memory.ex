# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.VectorDB.Memory do
  @moduledoc """
  In-process backend used by tests so the suite doesn't depend on
  sqlite-vec being loaded at runtime. ETS-backed; resets via
  `reset/0`.

  Implements `Dmhai.VectorDB.Backend`. Production-grade scale is NOT
  a goal here.
  """

  @behaviour Dmhai.VectorDB.Backend

  @table :dmhai_vector_db_memory

  @doc "Idempotent table init."
  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:public, :named_table, :bag])
      _ -> :ok
    end
    :ok
  end

  @doc "Wipe all rows. Test fixture aid."
  def reset do
    init()
    :ets.delete_all_objects(@table)
    :ok
  end

  # Each ETS row is {{scope, user_id}, chunk_row + decorated source attrs}.
  # The source attrs (kind/ref/title/tags) are decorated by the pipeline
  # before calling add/1 — Memory backend doesn't touch a real
  # kb_sources table. See Pipeline for how it stuffs decoration.

  @impl true
  def add(rows) when is_list(rows) do
    init()

    Enum.each(rows, fn row ->
      :ets.insert(@table, {{row.scope, row.user_id}, row})
    end)

    :ok
  end

  @impl true
  def search(scope, query_vec, k, filter) when is_list(query_vec) and is_integer(k) and k > 0 do
    init()

    rows = match_rows(scope, filter)
    q_norm = norm(query_vec)

    hits =
      rows
      |> Stream.map(fn r ->
        score = cosine(query_vec, r.embedding, q_norm)
        %{
          chunk_text: r.chunk_text,
          source_id: r.source_id,
          source_kind: Map.get(r, :_source_kind, "?"),
          source_ref: Map.get(r, :_source_ref, ""),
          title: Map.get(r, :_title),
          tags: Map.get(r, :_tags, []),
          score: score
        }
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(k)

    {:ok, hits}
  end

  @impl true
  # Memory backend has no FTS5 — hybrid path silently degrades to
  # vector-only when this backend is in use (test environments).
  def bm25_search(_scope, _query_text, _k, _filter), do: {:ok, []}

  @impl true
  def delete_by_source(scope, source_id) when is_integer(source_id) do
    init()

    :ets.match_object(@table, {{scope, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.source_id == source_id))
    |> Enum.each(fn r ->
      :ets.delete_object(@table, {{r.scope, r.user_id}, r})
    end)

    :ok
  end

  @impl true
  def count(scope, user_id) do
    init()

    n =
      case user_id do
        nil ->
          :ets.match_object(@table, {{scope, :"$1"}, :_})
          |> Enum.count(fn {{_, uid}, _} -> is_nil(uid) end)

        uid ->
          :ets.match_object(@table, {{scope, uid}, :_}) |> length()
      end

    {:ok, n}
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp match_rows(scope, :none) do
    :ets.match_object(@table, {{scope, :_}, :_}) |> Enum.map(&elem(&1, 1))
  end

  defp match_rows(scope, {:user, user_id}) do
    :ets.match_object(@table, {{scope, user_id}, :_}) |> Enum.map(&elem(&1, 1))
  end

  defp match_rows(scope, {:source_id, source_id}) do
    :ets.match_object(@table, {{scope, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.source_id == source_id))
  end

  defp cosine(a, b, a_norm) do
    {dot, b_sq} = dot_and_b(a, b, 0.0, 0.0)
    b_norm = :math.sqrt(b_sq)
    if a_norm == 0.0 or b_norm == 0.0, do: 0.0, else: dot / (a_norm * b_norm)
  end

  defp dot_and_b([], _, dot, b), do: {dot, b}
  defp dot_and_b(_, [], dot, b), do: {dot, b}
  defp dot_and_b([x | xs], [y | ys], d, b), do: dot_and_b(xs, ys, d + x * y, b + y * y)

  defp norm(list), do: list |> Enum.reduce(0.0, fn x, acc -> acc + x * x end) |> :math.sqrt()
end
