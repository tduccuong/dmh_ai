# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ChainInFlight do
  @moduledoc """
  Per-session flag indicating whether `UserAgent.session_chain_loop` is
  iterating for that session. Read by the `/poll` handler and exposed
  to the FE so `pollTurnToCompletion` can tell *"intermediate text turn
  just landed, chain still going"* apart from *"chain ended"*.

  Without this signal, the FE's exit check
  (`sawAssistantMessage && !stream_buffer`) trips on the first
  intermediate assistant text in a multi-turn chain — tearing down
  the streaming placeholder before the chain actually finishes.
  Trailing progress rows from later turns then have nowhere to nest
  (the new in-flight nesting code expects a placeholder), and the
  in-flight UI breaks. See architecture.md §Polling-based delivery.

  Storage: ETS table `:dmhai_chain_in_flight`, public, set-keyed by
  `session_id`. Empty value (no row) = chain not in flight.
  Inserted by `UserAgent` on chain enter, deleted on chain exit. The
  `/poll` handler reads with `in_flight?/1`.
  """

  @table :dmhai_chain_in_flight

  @doc """
  Boot the ETS table. Called from `Dmhai.Application.start/2` before
  any UserAgent process can write. Idempotent — re-init on supervisor
  restart is safe.
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

  @doc "Mark the session's chain as in-flight."
  @spec set(String.t()) :: :ok
  def set(session_id) when is_binary(session_id) do
    :ets.insert(@table, {session_id, true})
    :ok
  end

  @doc "Clear the in-flight flag (chain exited)."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  @doc "True iff a chain is currently iterating for this session."
  @spec in_flight?(String.t()) :: boolean()
  def in_flight?(session_id) when is_binary(session_id) do
    case :ets.info(@table) do
      :undefined -> false
      _ -> :ets.member(@table, session_id)
    end
  end
end
