# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.BackgroundPipelines do
  @moduledoc """
  Refcounted per-session registry of active background pipelines.
  Currently used by the `/wiki <url>` crawl (see
  `DmhAi.Commands.Pipelines.URL`); other long-running side
  channels (folder walk, bulk seed run-all, …) can register here
  too.

  Reason it exists: the `/poll` handler's stale-pending sweeper
  (`SessionProgress.cleanup_stale_pending/2`) flips any pending
  tool row older than 30 s to done with a `[orphan-cleanup]`
  marker — assuming the chain that emitted it died. That's right
  for chain-emitted rows but wrong for our crawl pipelines, whose
  per-page progress rows can legitimately stay pending much
  longer (cloud embedder takes a while). The poll handler now
  skips cleanup when ANY background pipeline is registered for
  the session.

  Refcounted: a session can run multiple pipelines in parallel
  (URL + folder); cleanup resumes only after every pipeline
  unregisters. Storage is a public ETS table keyed by session_id
  with the active count as the value.
  """

  @table :dmh_ai_background_pipelines

  @doc """
  Boot the ETS table. Called from `DmhAi.Application.start/2`.
  Idempotent — re-entry on supervisor restart is safe.
  """
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Mark a background pipeline as active for the session. Bumps the refcount."
  @spec register(String.t()) :: :ok
  def register(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      []                  -> :ets.insert(@table, {session_id, 1})
      [{^session_id, n}]  -> :ets.insert(@table, {session_id, n + 1})
    end
    :ok
  end

  @doc """
  Decrement the session's pipeline refcount. When the count hits
  zero the row is removed entirely so `active?/1` flips to false.
  Safe to call when the row is already missing (no-op).
  """
  @spec unregister(String.t()) :: :ok
  def unregister(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, n}] when n <= 1 -> :ets.delete(@table, session_id)
      [{^session_id, n}]              -> :ets.insert(@table, {session_id, n - 1})
      _                               -> :ok
    end
    :ok
  end

  @doc "True iff at least one background pipeline is currently registered for the session."
  @spec active?(String.t()) :: boolean()
  def active?(session_id) when is_binary(session_id) do
    case :ets.info(@table) do
      :undefined -> false
      _ ->
        case :ets.lookup(@table, session_id) do
          [{^session_id, n}] when n > 0 -> true
          _                              -> false
        end
    end
  end
end
