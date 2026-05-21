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

  # Optional retrieval-time scope predicate. All keys are optional;
  # only stated constraints apply. See arch_wiki/dmh_ai/knowledge.md
  # §Source scope.
  #
  #   platforms_in     — whitelist: only hits whose source's platform
  #                       is in this list AND/OR untagged (see
  #                       `include_untagged`) pass.
  #   platforms_not_in — blacklist: hits whose platform is in this list
  #                       are excluded; untagged still pass (subject to
  #                       `include_untagged`).
  #   categories_in    — whitelist on category.
  #   include_untagged — default true. When false, only tagged sources
  #                       with explicit non-NULL `source_scope` qualify.
  @type scope_predicate :: %{
          optional(:platforms_in)     => [String.t() | nil],
          optional(:platforms_not_in) => [String.t()],
          optional(:categories_in)    => [String.t()],
          optional(:include_untagged) => boolean()
        }

  @type filter :: :none
                | {:org, String.t()}
                | {:org, String.t(), scope_predicate()}
                | {:user, String.t()}
                | {:source_id, integer()}

  # Chunk row shape per scope:
  #   :knowledge — org_id required; no user_id.
  #   :memo      — both org_id (audit context) and user_id (owner) required.
  @type chunk_row :: %{
          required(:scope) => scope(),
          required(:org_id) => String.t(),
          optional(:user_id) => String.t(),
          required(:source_id) => integer(),
          required(:chunk_idx) => non_neg_integer(),
          required(:chunk_text) => String.t(),
          required(:embedding) => embedding(),
          required(:indexed_at) => non_neg_integer()
        }

  @type hit :: %{
          required(:chunk_text) => String.t(),
          required(:internal_id) => integer(),
          required(:source_kind) => String.t(),
          required(:source_id) => String.t(),
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

  # `scope_arg` is `org_id` (binary) for `:knowledge` and `user_id`
  # (binary) for `:memo`. Both are required (NOT NULL per Primitive 0.1).
  @callback count(scope :: scope(), scope_arg :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
