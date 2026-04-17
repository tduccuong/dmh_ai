# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.UserAgentMessages do
  @moduledoc """
  Shared helper for appending an assistant/user message to a session's
  `messages` JSON column. Extracted so background processes (JobRuntime,
  periodic completion flows) can write session messages without going
  through the per-user GenServer.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  def append(session_id, user_id, message) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                      [session_id, user_id])

      case result.rows do
        [[msgs_json]] ->
          msgs = Jason.decode!(msgs_json || "[]")
          updated = Jason.encode!(msgs ++ [message])
          now = System.os_time(:millisecond)
          query!(Repo, "UPDATE sessions SET messages=?, updated_at=? WHERE id=?",
                 [updated, now, session_id])
          :ok

        _ ->
          Logger.warning("[UserAgentMessages] session not found id=#{session_id}")
          :ok
      end
    rescue
      e ->
        Logger.error("[UserAgentMessages] append failed: #{Exception.message(e)}")
        :ok
    end
  end
end
