# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.PendingPivots do
  @moduledoc """
  In-memory store for "pending pivots" — when the Oracle classifies a
  chain-start user message as `:unrelated` to the active anchor, the
  assistant is supposed to ask the user whether to pause / cancel /
  stop the anchor before switching. We stash the off-topic user
  message here so that, when the user later confirms (and the model
  emits `pause_task` or `cancel_task`), the runtime can synthesize a
  fresh `create_task` for that off-topic ask without making the user
  re-state it.

  Storage: ETS table `:dmhai_pending_pivots`, public, set-keyed by
  `session_id`. Volatile by design — a BE restart clears the table;
  any in-flight pivot is lost and the user simply re-states the new
  ask. Persisting through restarts is not worth the complexity for
  what is, by definition, a transient mid-conversation state.

  Entries TTL out at `@ttl_ms`. The cleanup happens lazily on `get/1`
  rather than via a sweeper — old entries that are never touched do
  occupy a few bytes each, which is fine for a per-session store.
  """

  @table :dmhai_pending_pivots
  @ttl_ms 30 * 60 * 1000  # 30 minutes — pivot survives a coffee break

  @doc """
  Boot the ETS table. Called from `Dmhai.Application.start/2` before
  any chain runs. Idempotent: an already-existing table is left in
  place (useful for `iex -S mix` reloads).
  """
  @spec init() :: :ok
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Record that the most recent chain-start user message in this
  session is off-topic to the anchor. `entry` carries the message
  text + the anchor's task_num; the auto-create-task hook reads
  these when it fires.
  """
  @spec put(String.t(), %{user_msg: String.t(), anchor_task_num: integer() | nil}) :: :ok
  def put(session_id, %{user_msg: user_msg, anchor_task_num: anchor_task_num} = entry)
      when is_binary(session_id) and is_binary(user_msg) do
    init()
    row = entry
          |> Map.put(:user_msg, user_msg)
          |> Map.put(:anchor_task_num, anchor_task_num)
          |> Map.put(:ts, System.os_time(:millisecond))

    :ets.insert(@table, {session_id, row})
    :ok
  end

  @doc """
  Read (without removing) the pending pivot for this session, or
  `nil` when no pivot is staged or the staged entry has expired.
  """
  @spec get(String.t()) :: map() | nil
  def get(session_id) when is_binary(session_id) do
    init()

    case :ets.lookup(@table, session_id) do
      [{^session_id, %{ts: ts} = entry}] ->
        if fresh?(ts) do
          entry
        else
          :ets.delete(@table, session_id)
          nil
        end

      _ ->
        nil
    end
  end

  @doc "Remove the pending pivot for this session, if any."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    init()
    :ets.delete(@table, session_id)
    :ok
  end

  defp fresh?(ts) when is_integer(ts) do
    now = System.os_time(:millisecond)
    now - ts <= @ttl_ms
  end
  defp fresh?(_), do: false
end
