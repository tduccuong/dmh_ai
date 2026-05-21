# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.EphemeralCache do
  @moduledoc """
  In-memory cache for transient streaming state.

  Owns one ETS table at app boot. Keyed by `{session_id, kind}`
  where `kind ∈ #{Kernel.inspect(:stream)} | #{Kernel.inspect(:thinking)}`.
  Values are `{text :: binary, ts :: integer_ms}` tuples.

  ## Why ETS, not the DB

  Streaming tokens flush ~4 writes per second per active chain. In
  SQLite WAL mode the writer slot is single. Per-token DB writes
  monopolise that slot, starve other writers (TokenTracker,
  SessionProgress, BgRefresh), and induce `SQLITE_BUSY` cascades
  that kill the agent's inline task.

  The streaming buffer has zero durability requirement — the
  canonical assistant message lands in `sessions.messages` at chain
  end. Storing it in ETS makes writes nanosecond-scale, lock-free,
  and invisible to the SQLite writer slot.

  See `arch_wiki/dmh_ai/architecture.md` §Streaming state lives in
  ETS, not the DB.

  ## Interface (callers only)

      DmhAi.Agent.StreamBuffer.maybe_flush/1   ──┐
      DmhAi.Agent.StreamBuffer.flush/1         ──┤  These are the
      DmhAi.Agent.StreamBuffer.read/2          ──┤  ONLY entry points
      DmhAi.Agent.StreamBuffer.clear/2         ──┤  that touch the
      DmhAi.Agent.ThinkingBuffer.{flush,...}   ──┘  ETS table.

  Direct `:ets.lookup/2` from outside those modules is a contract
  violation; pin via grep on review.
  """

  use GenServer

  @table :dmh_ai_ephemeral_buffers

  # ── boot ────────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # `:public` so any process may read/write without going through
    # this GenServer — that's the whole point: the cache must not
    # become its own contention bottleneck. The GenServer exists only
    # to own the table's lifetime so it survives any single client
    # crash but dies cleanly on application stop.
    :ets.new(@table, [
      :set, :public, :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  # ── primitives (called from StreamBuffer / ThinkingBuffer) ──────────

  @doc "Insert / overwrite the value for `{session_id, kind}`."
  @spec put(String.t(), atom(), binary(), integer()) :: :ok
  def put(session_id, kind, text, ts)
      when is_binary(session_id) and is_atom(kind) and is_binary(text) and is_integer(ts) do
    :ets.insert(@table, {{session_id, kind}, {text, ts}})
    :ok
  end

  @doc """
  Read the cached value. Returns `{text, ts}` on hit, `nil` on miss.
  Atomic — a concurrent `put/4` overwrites cleanly thanks to ETS's
  per-key write linearisation.
  """
  @spec get(String.t(), atom()) :: {binary(), integer()} | nil
  def get(session_id, kind) when is_binary(session_id) and is_atom(kind) do
    case :ets.lookup(@table, {session_id, kind}) do
      [{_, value}] -> value
      _ -> nil
    end
  end

  @doc "Drop the cached value for `{session_id, kind}`. Idempotent."
  @spec delete(String.t(), atom()) :: :ok
  def delete(session_id, kind) when is_binary(session_id) and is_atom(kind) do
    :ets.delete(@table, {session_id, kind})
    :ok
  end

  @doc """
  Diagnostic — count live entries. Used by tests and ops; not by
  runtime code.
  """
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size) || 0
end
