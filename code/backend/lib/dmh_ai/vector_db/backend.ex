# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.Backend do
  @moduledoc """
  Storage abstraction for the vector knowledge base. The pipeline
  layer (`DmhAi.VectorDB.Pipeline`) and the fetch tools never call the
  backend directly — they go through `DmhAi.VectorDB`, which picks an
  implementation per `:dmh_ai, :vector_db_backend` config.

  Production: `DmhAi.VectorDB.SqliteVec` (sqlite-vec virtual tables in
  the existing SQLite DB). Tests: `DmhAi.VectorDB.Memory` (ETS-backed,
  no DB).

  The four-method behaviour deliberately operates on **pre-built
  rows** — chunking, embedding, tagging, merge logic all live in the
  pipeline, not the backend. Keeps the swap surface minimal.
  """

  @type scope :: :knowledge | :memo
  @type embedding :: [float()]
  @type filter :: :none | {:user, String.t()} | {:source_id, integer()}

  @type chunk_row :: %{
          required(:scope) => scope(),
          required(:user_id) => String.t() | nil,
          required(:source_id) => integer(),
          required(:chunk_idx) => non_neg_integer(),
          required(:chunk_text) => String.t(),
          required(:embedding) => embedding(),
          required(:indexed_at) => non_neg_integer()
        }

  @type hit :: %{
          required(:chunk_text) => String.t(),
          required(:source_id) => integer(),
          required(:source_kind) => String.t(),
          required(:source_ref) => String.t(),
          required(:title) => String.t() | nil,
          required(:tags) => [String.t()],
          required(:score) => float()
        }

  @callback add(rows :: [chunk_row()]) :: :ok | {:error, term()}

  @callback search(scope :: scope(), query :: embedding(), k :: pos_integer(),
                   filter :: filter()) :: {:ok, [hit()]} | {:error, term()}

  @doc """
  BM25 search over chunk_text via FTS5. Optional companion to vector
  search — fuses with `search/4`'s result via RRF in `DmhAi.VectorDB`
  (#182). Backends that don't have a full-text index return
  `{:ok, []}` so the hybrid path silently degrades to vector-only.
  """
  @callback bm25_search(scope :: scope(), query_text :: String.t(),
                        k :: pos_integer(), filter :: filter()) ::
              {:ok, [hit()]} | {:error, term()}

  @callback delete_by_source(scope :: scope(), source_id :: integer()) ::
              :ok | {:error, term()}

  @callback count(scope :: scope(), user_id :: String.t() | nil) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
