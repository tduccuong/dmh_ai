# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.UserAgentMessages do
  @moduledoc """
  Shared helper for appending an assistant/user message to a session's
  `messages` JSON column. Extracted so background processes (TaskRuntime,
  periodic completion flows) can write session messages without going
  through the per-user GenServer.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Append a message to the session's `messages` JSON column and stamp its
  `ts` from the BE clock (overwriting any incoming value) per CLAUDE.md
  rule #9. Returns `{:ok, ts_ms}` on success so callers can plumb the
  canonical timestamp back through their response (e.g. /agent/chat's
  final SSE `{done, user_ts, assistant_ts}` frame).
  """
  def append(session_id, user_id, message) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                      [session_id, user_id])

      case result.rows do
        [[msgs_json]] ->
          msgs = Jason.decode!(msgs_json || "[]")
          now  = System.os_time(:millisecond)
          stamped = Map.put(message, :ts, now)
          updated = Jason.encode!(msgs ++ [stamped])
          query!(Repo, "UPDATE sessions SET messages=?, updated_at=? WHERE id=?",
                 [updated, now, session_id])
          {:ok, now}

        _ ->
          Logger.warning("[UserAgentMessages] session not found id=#{session_id}")
          {:error, :session_not_found}
      end
    rescue
      e ->
        Logger.error("[UserAgentMessages] append failed: #{Exception.message(e)}")
        {:error, :exception}
    end
  end

end
